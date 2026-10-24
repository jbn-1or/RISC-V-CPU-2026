// Frontend fetch unit: PC generation, icache request,
// instruction fetch buffer (IFB, 8 entries), JAL/RAS-return redirect and flush
// clearing.
//
// Request protocol (pipelined, miss-safe):
//   the icache is a 1-cycle SRAM read, so one 8B block is requested every
//   cycle. Each cycle the previous request's block (r_pc_q) is inspected: on a
//   hit it is decoded (external decode) and pushed into the IFB while the next
//   (fall-through) block is requested in the same cycle; on a miss the request
//   stalls until the refill releases busy, then the same pc is re-requested; a
//   redirect requests the target immediately when the cache can accept it.
//   A flush discards the in-flight response and drops IFB entries younger than the
//   flush point. A JAL/return redirect masks the same-block fall-through slot.
//   in_take is a two-bit prefix: {slot1_taken, slot0_taken}.
module fetch_unit (
    input  wire        clock,
    input  wire        reset,

    input  cpu_pkg::flush_t flush,
    input wire [31:0] flush_next_pc,

    // decode interface (combinational loop with the decode module)
    output wire [63:0] dec_pc_s,
    output wire [63:0] dec_raw_s,
    output wire [1:0]  dec_valid_s,
    input  wire [1:0]  dec_out_valid,
    input  cpu_pkg::decoded_t dec_d0,
    input  cpu_pkg::decoded_t dec_d1,

    // IFB output to the core (2-way stream)
    output wire [1:0]       fe_valid,
    output cpu_pkg::fe2rn_t fe0,
    output cpu_pkg::fe2rn_t fe1,
    input  wire [1:0]       fe_take,

    // BHT update (BRU resolve)
    input  wire        br_upd_valid,
    input  wire [31:0] br_upd_pc,
    input  wire        br_upd_taken,
    input  wire [$clog2(cpu_pkg::BHT_ENTRIES)-1:0] br_upd_ix,
    input  wire        br_upd_mispred,

    // BTB update (BRU resolve: taken cond branch / non-return JALR)
    input  wire        btb_upd_valid,
    input  wire [31:0] btb_upd_pc,
    input  wire [31:0] btb_upd_target,

    // AXI read push (src = MRF_IC, set by top)
    output wire        rd_push_valid,
    output wire [31:0] rd_push_addr,
    output wire [4:0]  rd_push_idx,
    input  wire        rd_push_ready,
    input  wire        rd_rsp_valid,
    input  wire [4:0]  rd_rsp_idx,
    input  wire [31:0] rd_rsp_data,
    output wire        rd_rsp_ready,
);
    logic [31:0] pc_r;
    logic        half_r;
    logic [5:0]  bsf_r;

    logic [31:0] r_pc_q;
    logic        r_half_q;
    logic        r_pend_q;

    wire        ic_busy, ic_rsp_valid;
    wire [31:0] ic_w0, ic_w1;

    wire [31:0] pc_q = pc_r;
    wire        issue_ok;
    wire [31:0] req_pc;   // request address (redirect target in a redirect cycle)
    wire        req_half; // half bit of req_pc

    icache u_ic (
        .clock, .reset,
        .req_valid(issue_ok), .req_addr(req_pc),
        .busy(ic_busy), .rsp_valid(ic_rsp_valid),
        .rsp_word0(ic_w0), .rsp_word1(ic_w1),
        .rd_push_valid, .rd_push_addr, .rd_push_idx, .rd_push_ready,
        .rd_rsp_valid, .rd_rsp_idx, .rd_rsp_data, .rd_rsp_ready);

    // ---------------- decode inputs ----------------
    assign dec_pc_s  = {r_pc_q + 32'd4, r_pc_q};
    assign dec_raw_s = {ic_w1, ic_w0};

    wire resp_ok  = ic_rsp_valid && r_pend_q && !flush.valid;
    // a requested block whose response did not arrive and did not (yet) raise
    // busy is a miss: the icache asserts busy on the next edge; re-request the
    // same pc once the refill completes.
    wire miss_det = r_pend_q && !ic_rsp_valid && !ic_busy && !flush.valid;
    wire slot0_ok = resp_ok && !r_half_q;
    wire slot1_ok = resp_ok;
    assign dec_valid_s = {slot1_ok, slot0_ok};

    // ---------------- decode classification ----------------
    wire d0_jal  = (dec_d0.op == cpu_pkg::OP_JAL);
    wire d0_jalr = (dec_d0.op == cpu_pkg::OP_JALR);
    wire d0_ret  = dec_d0.is_ret;
    wire d0_link = (d0_jal || d0_jalr) &&
                   ((dec_d0.rd == 5'd1) || (dec_d0.rd == 5'd5));

    wire d1_jal  = (dec_d1.op == cpu_pkg::OP_JAL);
    wire d1_jalr = (dec_d1.op == cpu_pkg::OP_JALR);
    wire d1_ret  = dec_d1.is_ret;
    wire d1_link = (d1_jal || d1_jalr) &&
                   ((dec_d1.rd == 5'd1) || (dec_d1.rd == 5'd5));

    // ---------------- effective slots ----------------
    wire eff0 = slot0_ok;
    wire first_is1 = !eff0;
    wire has_first  = slot0_ok || slot1_ok;

    wire cpu_pkg::decoded_t first_insn = first_is1 ? dec_d1 : dec_d0;
    wire first_ret  = first_is1 ? d1_ret  : d0_ret;
    wire first_link = first_is1 ? d1_link : d0_link;
    wire [5:0] first_bsf = bsf_r;

    wire        bp_s0_hit, bp_s1_hit;
    wire [31:0] bp_s0_top, bp_s1_top;
    wire        p0_dir, p0_hit, p1_dir, p1_hit;
    wire [31:0] p0_tgt, p1_tgt;

    // ---------------- prediction per effective instruction ----------------
    // Direction comes from the BHT (2-bit counter), the target from the BTB
    // (conditional branches need BHT=taken AND a BTB hit; indirect JALR needs
    // a BTB hit; returns use the RAS top). first_ret uses the RAS s0 port
    // because s0 carries the first effective instruction (incl. the upper-half
    // slot when a fetch block starts at pc[2]=1).
    wire first_cond = (first_insn.op == cpu_pkg::OP_BR);
    wire first_ind  = (first_insn.op == cpu_pkg::OP_JALR) && !first_ret;
    wire second_cond = (dec_d1.op == cpu_pkg::OP_BR);
    wire second_ind  = d1_jalr && !d1_ret;

    wire first_pred_taken = first_ret  ? bp_s0_hit :
                            first_cond ? (p0_dir && p0_hit) :
                            first_ind  ? p0_hit : 1'b0;
    wire [31:0] first_pred_target = first_ret ? bp_s0_top : p0_tgt;

    wire second_pred_taken = d1_ret     ? bp_s1_hit :
                             second_cond ? (p1_dir && p1_hit) :
                             second_ind  ? p1_hit : 1'b0;
    wire [31:0] second_pred_target = d1_ret ? bp_s1_top : p1_tgt;

    wire s0_special = (first_insn.op == cpu_pkg::OP_JAL) || first_pred_taken;
    wire eff1 = slot1_ok && !(eff0 && s0_special);
    wire has_second = eff0 && eff1;

    wire red_first_jal  = has_first && (first_insn.op == cpu_pkg::OP_JAL);
    wire red_first_pred = has_first && first_pred_taken;
    wire red_second_jal = has_second && d1_jal;
    wire red_second_pred = has_second && second_pred_taken;
    wire redirect = red_first_jal || red_first_pred || red_second_jal || red_second_pred;

    // instructions actually pushed into the IFB this cycle (drive the BP GHR)
    wire push0 = slot0_ok && dec_out_valid[0];
    wire push1 = slot1_ok && dec_out_valid[1] && !(slot0_ok && s0_special);

    wire [31:0] red_target =
        red_first_jal   ? (first_insn.pc + first_insn.imm) :
        red_first_pred  ? first_pred_target :
        red_second_jal  ? (dec_d1.pc + dec_d1.imm) :
        red_second_pred ? second_pred_target : (pc_r + 32'd8);

    wire f_pred_taken  = first_pred_taken;
    wire [31:0] f_pred_target = first_pred_taken ? first_pred_target : 32'b0;
    wire s_pred_taken  = second_pred_taken;
    wire [31:0] s_pred_target = second_pred_taken ? second_pred_target : 32'b0;

    // Fetch the redirect target in the same cycle it is detected instead
    // of suppressing the request for one cycle. `redirect` implies `resp_ok`
    // (hence !flush.valid && !miss_det), so it is mutually exclusive with the
    // flush and miss paths. This removes the per-taken-branch request bubble.
    // Likewise fetch the flush target (early branch redirect) in its own
    // cycle, removing the per-misprediction request bubble.
    assign req_pc   = flush.valid ? (flush.pc    & 32'hfffffff8) :
                      redirect    ? (red_target  & 32'hfffffff8) : pc_q;
    assign req_half = flush.valid ? flush.pc[2] :
                      redirect    ? red_target[2] : half_r;

    wire [$clog2(cpu_pkg::BHT_ENTRIES)-1:0] bp_lk0_ix, bp_lk1_ix;
    bp u_bp (
        .clock, .reset,
        .lk0_pc(first_insn.pc), .lk0_dir(p0_dir), .lk0_hit(p0_hit), .lk0_target(p0_tgt),
        .lk1_pc(dec_d1.pc),     .lk1_dir(p1_dir), .lk1_hit(p1_hit), .lk1_target(p1_tgt),
        .up_valid(br_upd_valid), .up_pc(br_upd_pc), .up_taken(br_upd_taken),
        .up_ix(br_upd_ix), .up_mispred(br_upd_mispred),
        .btb_upd_valid, .btb_upd_pc, .btb_upd_target,
        .s0_v(has_first), .s0_ret(first_ret), .s0_link(first_link), .s0_pc(first_insn.pc),
        .s1_v(has_second), .s1_ret(d1_ret), .s1_link(d1_link), .s1_pc(dec_d1.pc),
        // A is the pushed first instruction (dec_d0 if slot0, else the upper-half
        // dec_d1); B exists only when both slots are pushed.
        .s0_cond((push0 || push1) && first_cond), .s0_pt(f_pred_taken),
        .s1_cond((push0 && push1) && second_cond), .s1_pt(s_pred_taken),
        .lk0_ix(bp_lk0_ix), .lk1_ix(bp_lk1_ix),
        .s0_hit(bp_s0_hit), .s0_top(bp_s0_top),
        .s1_hit(bp_s1_hit), .s1_top(bp_s1_top));

    // ---------------- IFB ----------------
    // Plain packed words avoid Yosys' native frontend interpreting an
    // unpacked array of package structs as one struct with a bit index.
    logic [$bits(fe0)-1:0] ifb_mem [0:7];
    logic [2:0]  ifb_head, ifb_tail;
    logic [3:0]  ifb_cnt;

    wire A_valid = push0 || push1;
    wire B_valid = push0 && push1;
    wire [1:0] n_push = {1'b0, A_valid} + {1'b0, B_valid};
    wire [1:0] pop = fe_take;
    wire [1:0] n_pop = {1'b0, pop[0]} + {1'b0, pop[1]};

    assign fe_valid = { (ifb_cnt >= 4'd2), (ifb_cnt >= 4'd1) };
    assign fe0 = ifb_mem[ifb_head];
    assign fe1 = ifb_mem[ifb_head + 3'd1];

    wire ifb_ok = (ifb_cnt + {2'b0, n_push}) <= 4'd6;
    // Neither `redirect` nor `flush` suppresses the request; their
    // targets are requested in the same cycle via req_pc. A miss still stalls
    // (its block is re-requested after the refill), and a busy port or a full
    // IFB still suppresses.
    // On a flush cycle the pre-flush (wrong-path) request may be taking the I$
    // miss path: the icache would start its refill and drop the newly issued
    // target request, so the target block would be skipped. Suppress the
    // same-cycle flush request in that case (the fallback re-requests flush.pc
    // after the refill). `redirect` always implies a hit, so it is unaffected.
    wire pend_miss = r_pend_q && !ic_rsp_valid;
    assign issue_ok = !ic_busy && !miss_det && ifb_ok && !(flush.valid && pend_miss);

    wire cpu_pkg::decoded_t A_insn = push0 ? dec_d0 : dec_d1;
    // IFB entries (field-wise, Yosys has no '{} assignment pattern support)
    cpu_pkg::fe2rn_t eA, eB;
    always_comb begin
        eA = '0;
        eA.valid = 1'b1; eA.insn = A_insn; eA.bsf = first_bsf;
        eA.pred_taken = f_pred_taken; eA.pred_target = f_pred_target;
        eA.bix = bp_lk0_ix;
        eB = '0;
        eB.valid = 1'b1; eB.insn = dec_d1; eB.bsf = B_bsf;
        eB.pred_taken = s_pred_taken; eB.pred_target = s_pred_target;
        eB.bix = bp_lk1_ix;
    end
    wire [5:0] B_bsf = first_bsf + {5'b0, dec_d0.is_branch};

    always_ff @(posedge clock) begin
        if (reset) begin
            ifb_head <= 3'd0; ifb_tail <= 3'd0; ifb_cnt <= 4'd0;
            pc_r <= 32'd0; half_r <= 1'b0; bsf_r <= 6'd0;
            r_pend_q <= 1'b0; r_pc_q <= 32'd0; r_half_q <= 1'b0;
        end else begin
            r_pend_q <= issue_ok;
            if (issue_ok) begin
                r_pc_q   <= req_pc;
                r_half_q <= req_half;
            end

            // ---- PC / bsf update (pipelined: one request per cycle) ----
            if (flush.valid) begin
                // If the flush-target request was issued this cycle,
                // advance past it; otherwise restart at the target next cycle.
                if (issue_ok) begin
                    pc_r   <= flush_next_pc;
                    half_r <= 1'b0;
                end else begin
                    pc_r   <= flush.pc & 32'hfffffff8;
                    half_r <= flush.pc[2];
                end
                bsf_r  <= flush.bsf + 6'd1;
            end else if (miss_det) begin
                pc_r   <= r_pc_q;      // re-request the missed block after refill
                half_r <= r_half_q;
                // bsf_r held: the same block is re-fetched
            end else if (redirect) begin
                // The target request was issued this cycle (req_pc), so
                // advance past it; if the port was busy / IFB full, restart at
                // the target next cycle instead.
                if (issue_ok) begin
                    pc_r   <= (red_target & 32'hfffffff8) + 32'd8;
                    half_r <= 1'b0;
                end else begin
                    pc_r   <= red_target & 32'hfffffff8;
                    half_r <= red_target[2];
                end
                bsf_r  <= first_bsf + {5'b0, first_insn.is_branch} +
                          (has_second ? {5'b0, dec_d1.is_branch} : 6'd0);
            end else begin
                if (issue_ok) begin
                    pc_r   <= pc_r + 32'd8;
                    half_r <= 1'b0;
                end
                // bsf advances with the consumed (pushed) block, independent of
                // whether a new request is issued this cycle
                if (resp_ok)
                    bsf_r  <= bsf_r + {5'b0, (push0 && (first_is1 ? dec_d1.is_branch :
                                                                  dec_d0.is_branch))} +
                                     {5'b0, (push1 && dec_d1.is_branch)};
            end

            // ---- IFB update ----
            if (flush.valid) begin
                // Fetch/rename dispatch in order. A resolving branch has
                // already left the IFB, so every buffered instruction is
                // younger. Clear all entries without a half-ring age bound;
                // larger ROB windows can exceed that bound or wrap bsf.
                ifb_tail <= ifb_head;
                ifb_cnt <= '0;
            end else begin
                if (A_valid) ifb_mem[ifb_tail] <= eA;
                if (B_valid) ifb_mem[ifb_tail + 3'd1] <= eB;
                ifb_tail <= ifb_tail + n_push;
                ifb_head <= ifb_head + n_pop;
                ifb_cnt  <= ifb_cnt + {2'b0, n_push} - {2'b0, n_pop};
            end
        end
    end

endmodule
