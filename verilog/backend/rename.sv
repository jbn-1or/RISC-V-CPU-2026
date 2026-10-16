// Register rename (design.md §6.1): map table + free/busy/pending bitmaps,
// chained intra-cycle renaming (slot1 sees slot0's mapping), prefix-sliced
// dispatch backpressure, and same-cycle flush recovery from the ROB snapshot.
//
// State is expressed as 64-bit tag bitmaps (PRF_NUM=64):
//   free_q : allocatable tags;  busy_q : allocated but not yet written back;
//   pend_q : physical destinations of killed instructions, held until their
//            (now suppressed) writeback actually arrives — this keeps a stale
//            writeback from matching a re-allocated tag (design §4.3 rule 2).
module rename (
    input  wire        clock,
    input  wire        reset,

    // ---- FE stream ----
    input  wire [1:0]  in_valid,
    input  cpu_pkg::fe2rn_t in0,
    input  cpu_pkg::fe2rn_t in1,
    output wire [1:0]  in_take,

    // ---- structural limits ----
    input  wire [$clog2(cpu_pkg::ROB_DEPTH):0] rob_space,
    input  wire [5:0]  iq_space,
    input  wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] rob_alloc_ptr,

    // ---- rel_msk / recovery inputs ----
    input  wire [cpu_pkg::PRF_NUM-1:0] wb_clr_mask,      // delivered WB tags -> clear busy
    input  wire [cpu_pkg::PRF_NUM-1:0] reclaim_mask,     // stale WB tags -> clear busy + free
    input  wire [cpu_pkg::PRF_NUM-1:0] cmt_free_mask,    // commit releases old_pdst
    input  wire [cpu_pkg::PRF_NUM-1:0] flush_free_mask,  // killed+done pdst -> free now
    input  wire [cpu_pkg::PRF_NUM-1:0] flush_pend_mask,  // killed+!done pdst -> hold pending
    input  wire        flush_valid,
    input  wire [31:0] restore_valid,
    input  wire [32*$clog2(cpu_pkg::PRF_NUM)-1:0] restore_pdst,

    // ---- dispatch out ----
    output wire [1:0]  rob_valid,
    output wire [4:0]  rob_rd0,
    output wire [4:0]  rob_rd1,
    output wire [$clog2(cpu_pkg::PRF_NUM)-1:0] rob_pdst0,
    output wire [$clog2(cpu_pkg::PRF_NUM)-1:0] rob_pdst1,
    output wire [$clog2(cpu_pkg::PRF_NUM)-1:0] rob_old0,
    output wire [$clog2(cpu_pkg::PRF_NUM)-1:0] rob_old1,
    output wire        rob_load0,
    output wire        rob_load1,
    output wire        rob_store0,
    output wire        rob_store1,
    output wire [1:0]  iq_valid,
    output cpu_pkg::renamed_t iq_d0,
    output cpu_pkg::renamed_t iq_d1
);
    localparam int PB = $clog2(cpu_pkg::PRF_NUM);          // physical tag bits
    localparam logic [cpu_pkg::PRF_NUM-1:0] ONE = 1;       // tag-0 one-hot
    logic [PB-1:0]  map_q [0:31];
    logic [cpu_pkg::PRF_NUM-1:0] free_q, busy_q, pend_q;
    // ---------------------------------------------------------------
    // tag allocator
    // ---------------------------------------------------------------
    function automatic logic [PB-1:0] lowest(input logic [cpu_pkg::PRF_NUM-1:0] v);
        lowest = '0;
        for (int i = cpu_pkg::PRF_NUM - 1; i >= 0; i = i - 1)
            if (v[i]) lowest = i[PB-1:0];
    endfunction

    wire [cpu_pkg::PRF_NUM-1:0] rel_msk = cmt_free_mask | rec_eff | flush_free_mask;
    // A stale (killed) writeback's reclaim may only free the tag if that tag
    // is still held pending from the kill: a killed load's tag is freed at the
    // flush (not pending), so a late beat for it must not touch a tag that has
    // already been re-allocated. Same-cycle flush+beat (the beat IS the
    // reclaiming event) stays covered via flush_pend_mask.
    wire [cpu_pkg::PRF_NUM-1:0] rec_eff = reclaim_mask & (pend_q | flush_pend_mask);
    wire [cpu_pkg::PRF_NUM-1:0] fe      = (free_q | rel_msk) & ~pend_q & ~ONE;   // p0 excluded
    wire [PB-1:0]  alc0    = lowest(fe);

    logic [PB:0] free_cnt;
    always_comb begin
        free_cnt = '0;
        for (int i = 0; i < cpu_pkg::PRF_NUM; i = i + 1)
            free_cnt = free_cnt + {{PB{1'b0}}, fe[i]};
    end

    // ---------------------------------------------------------------
    // operand / destination resolution
    // ---------------------------------------------------------------
    wire [4:0] a1_0 = in0.insn.rs1, a2_0 = in0.insn.rs2, ad_0 = in0.insn.rd;
    wire [4:0] a1_1 = in1.insn.rs1, a2_1 = in1.insn.rs2, ad_1 = in1.insn.rd;
    wire u1_0 = in0.insn.uses_rs1, u2_0 = in0.insn.uses_rs2;
    wire u1_1 = in1.insn.uses_rs1, u2_1 = in1.insn.uses_rs2;
    wire need0 = (in0.insn.rd != 5'd0);
    wire need1 = (in1.insn.rd != 5'd0);

    // second tag over tags still free after slot 0 (slot 0 only consumes alc0
    // when it has a destination); an empty fe1 means no valid second tag.
    wire [cpu_pkg::PRF_NUM-1:0] fe1  = fe & ~(need0 ? (ONE << alc0) : '0);
    wire [PB-1:0]  alc1 = lowest(fe1);

    logic [PB:0] need_all;
    always_comb need_all = {{PB{1'b0}}, need0} + {{PB{1'b0}}, need1};

    wire take0 = !flush_valid && in_valid[0] &&
                 (rob_space >= 6'd1) && (iq_space != 6'd0) &&
                 (need0 ? (free_cnt != 7'd0) : 1'b1);
    wire take1 = take0 && in_valid[1] &&
                 (rob_space >= 6'd2) && (iq_space >= 6'd2) &&
                 (need_all <= free_cnt) &&
                 (!need1 || (fe1 != '0));

    // slot 0
    wire [PB-1:0] s0_ps1 = u1_0 ? map_q[a1_0] : '0;
    wire [PB-1:0] s0_ps2 = u2_0 ? map_q[a2_0] : '0;
    wire       s0_r1  = !u1_0 || !busy_q[s0_ps1];
    wire       s0_r2  = !u2_0 || !busy_q[s0_ps2];
    wire [PB-1:0] s0_pdst = need0 ? alc0 : '0;
    wire [PB-1:0] s0_old  = need0 ? map_q[ad_0] : '0;

    // slot 1 (write-after-read forwarding from slot 0)
    wire h1_1 = take0 && need0 && u1_1 && (ad_0 == a1_1);
    wire h1_2 = take0 && need0 && u2_1 && (ad_0 == a2_1);
    wire [PB-1:0] s1_ps1 = u1_1 ? (h1_1 ? s0_pdst : map_q[a1_1]) : '0;
    wire [PB-1:0] s1_ps2 = u2_1 ? (h1_2 ? s0_pdst : map_q[a2_1]) : '0;
    wire s1_r1 = !u1_1 || (!h1_1 && !busy_q[s1_ps1]);
    wire s1_r2 = !u2_1 || (!h1_2 && !busy_q[s1_ps2]);
    wire h1_d = take0 && need0 && need1 && (ad_0 == ad_1);
    wire [PB-1:0] s1_old  = need1 ? (h1_d ? s0_pdst : map_q[ad_1]) : '0;
    wire [PB-1:0] s1_pdst = need1 ? alc1 : '0;

    // ---------------------------------------------------------------
    // dispatch outputs
    // ---------------------------------------------------------------
    assign in_take = {take1, take0};
    assign rob_valid = {take1, take0};
    assign iq_valid  = {take1, take0};
    assign rob_rd0 = ad_0;
    assign rob_rd1 = ad_1;
    assign rob_pdst0 = s0_pdst;
    assign rob_pdst1 = s1_pdst;
    assign rob_old0 = s0_old;
    assign rob_old1 = s1_old;
    assign rob_load0 = (in0.insn.op == cpu_pkg::OP_LOAD);
    assign rob_load1 = (in1.insn.op == cpu_pkg::OP_LOAD);
    assign rob_store0 = (in0.insn.op == cpu_pkg::OP_STORE);
    assign rob_store1 = (in1.insn.op == cpu_pkg::OP_STORE);

    always_comb begin
        iq_d0 = '0;
        iq_d0.insn       = in0.insn;
        iq_d0.ps1        = s0_ps1;
        iq_d0.ps2        = s0_ps2;
        iq_d0.rs1_ready  = s0_r1;
        iq_d0.rs2_ready  = s0_r2;
        iq_d0.pdst       = s0_pdst;
        iq_d0.old_pdst   = s0_old;
        iq_d0.rob        = rob_alloc_ptr;
        iq_d0.bsf        = in0.bsf;
        iq_d0.pred_taken = in0.pred_taken;
        iq_d0.pred_target= in0.pred_target;
        iq_d0.bix        = in0.bix;

        iq_d1 = '0;
        iq_d1.insn       = in1.insn;
        iq_d1.ps1        = s1_ps1;
        iq_d1.ps2        = s1_ps2;
        iq_d1.rs1_ready  = s1_r1;
        iq_d1.rs2_ready  = s1_r2;
        iq_d1.pdst       = s1_pdst;
        iq_d1.old_pdst   = s1_old;
        iq_d1.rob        = rob_alloc_ptr + 1'b1;
        iq_d1.bsf        = in1.bsf;
        iq_d1.pred_taken = in1.pred_taken;
        iq_d1.pred_target= in1.pred_target;
        iq_d1.bix        = in1.bix;
    end

    // ---------------------------------------------------------------
    // state
    // ---------------------------------------------------------------
    wire [cpu_pkg::PRF_NUM-1:0] alloc_mask =
        (( take0 && need0) ? (ONE << alc0) : '0) |
        (( take1 && need1) ? (ONE << alc1) : '0);

    always_ff @(posedge clock) begin
        if (reset) begin
            for (int i = 0; i < 32; i = i + 1)
                map_q[i] <= i[PB-1:0];
            free_q <= {{(cpu_pkg::PRF_NUM-32){1'b1}}, 32'b0};   // tags 32..PRF_NUM-1 free
            busy_q <= '0;
            pend_q <= '0;
        end else begin            if (flush_valid) begin
                for (int r = 0; r < 32; r = r + 1)
                    if (restore_valid[r])
                        map_q[r] <= restore_pdst[r*PB +: PB];
            end else begin
                if (take0 && need0) map_q[ad_0] <= alc0;
                if (take1 && need1) map_q[ad_1] <= alc1;
            end
            free_q <= (free_q | rel_msk) & ~alloc_mask;
            pend_q <= (pend_q | flush_pend_mask) & ~rec_eff;
            busy_q <= (busy_q | alloc_mask) &
                      ~(wb_clr_mask | rec_eff | flush_free_mask | flush_pend_mask);
        end
    end
endmodule
