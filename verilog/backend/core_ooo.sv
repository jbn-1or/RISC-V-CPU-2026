// Out-of-order core integration (design.md §3/§4/§6). Wires rename/rob/iq/prf
// with the execution units, the two result buses BA/BB and their fixed-
// priority arbiters, the flush broadcast, and the M2 blocking LSU.
// This is the M3 swap target for the discarded core_seq.
module core_ooo (
    input  wire        clock,
    input  wire        reset,

    // ---- frontend stream (IFB output) ----
    input  wire [1:0]  fe_valid,
    input  cpu_pkg::fe2rn_t fe0,
    input  cpu_pkg::fe2rn_t fe1,
    output wire [1:0]  fe_take,

    // ---- flush broadcast (to frontend / A-side kill) ----
    output cpu_pkg::flush_t flush_out,
    output wire [$clog2(cpu_pkg::ROB_DEPTH):0] flush_dtail_out,

    // ---- M8b: combinational early redirect to the frontend ----
    // Asserted in the BRU resolve cycle (one cycle before flush_out.valid),
    // so the fetch unit can restart at the correct target a cycle earlier. The
    // registered flush_out still drives the ROB/IQ/LSU kill unchanged.
    output logic        redir_valid,
    output logic [31:0] redir_pc,
    output logic [5:0]  redir_bsf,

    // ---- branch resolution feedback (BHT training) ----
    output logic        br_upd_valid,
    output logic [31:0] br_upd_pc,
    output logic        br_upd_taken,
    output logic [$clog2(cpu_pkg::BHT_ENTRIES)-1:0] br_upd_ix,  // fetch-time gshare index (carried)
    output logic        br_upd_mispred,

    // ---- branch resolution feedback (BTB training) ----
    output logic        btb_upd_valid,
    output logic [31:0] btb_upd_pc,
    output logic [31:0] btb_upd_target,

    // ---- memory channels to lsu_a (A side) ----
    output wire        ld_valid,
    output cpu_pkg::mem_req_t ld_req,
    input  wire        ld_ready,
    output wire        st_valid,
    output cpu_pkg::mem_req_t st_req,
    input  wire        st_ready,
    input  wire        resp_valid,
    input  cpu_pkg::mem_resp_t resp,
    input  wire        resp_replay,

    // ---- M9c: D$ tag probe for the same-line guard relaxation ----
    output wire [31:0] probe_addr,
    input  wire        probe_hit,
);
    localparam int PB_C = $clog2(cpu_pkg::PRF_NUM);   // physical tag bits
    localparam int RB_C = $clog2(cpu_pkg::ROB_DEPTH); // rob index bits
    localparam logic [cpu_pkg::PRF_NUM-1:0] ONE_C = 1;
    // ================= rename / rob / iq / prf =================
    wire [1:0]  rob_valid, iq_valid;
    wire [4:0]  rob_rd0, rob_rd1;
    wire [PB_C-1:0] rob_pdst0, rob_pdst1, rob_old0, rob_old1;
    wire        rob_load0, rob_load1, rob_store0, rob_store1;
    cpu_pkg::renamed_t iq_d0, iq_d1;

    wire [RB_C:0] rob_space;
    wire [RB_C-1:0] rob_alloc_ptr;
    wire [RB_C-1:0] rob_head;
    wire [cpu_pkg::PRF_NUM-1:0] cmt_free_mask, flush_free_mask, flush_pend_mask;
    wire [31:0] restore_valid;
    wire [32*PB_C-1:0] restore_pdst;
    wire [RB_C:0] rob_flush_dtail;

    cpu_pkg::writeback_t ba, bb, ba_ok, bb_ok;
    wire        rec_a_valid, rec_b_valid;
    wire [PB_C-1:0] rec_a_tag, rec_b_tag;
    wire [cpu_pkg::PRF_NUM-1:0] wb_clr_mask, reclaim_mask;

    cpu_pkg::flush_t flush_r;
    wire rob_flush_valid = flush_r.valid;
    wire [RB_C-1:0] rob_flush_rob = flush_r.rob;

    assign flush_out = flush_r;
    assign flush_dtail_out = rob_flush_dtail;

    // BHT training: pulse when a conditional branch resolves (comb, issue cycle)
    assign br_upd_valid = b_i && (b_insn.op == cpu_pkg::OP_BR);
    assign br_upd_pc    = b_insn.pc;
    assign br_upd_taken = b_taken;
    assign br_upd_ix    = b_bix;
    assign br_upd_mispred = b_i && b_mispred;

    // BTB training: taken resolutions only (a not-taken branch needs no target):
    // taken conditional branch, or non-return JALR (returns are RAS-predicted).
    wire b_is_ret = b_insn.is_ret;
    assign btb_upd_valid  = b_i && (((b_insn.op == cpu_pkg::OP_BR) && b_taken) ||
                                    ((b_insn.op == cpu_pkg::OP_JALR) && !b_is_ret));
    assign btb_upd_pc     = b_insn.pc;
    assign btb_upd_target = b_tgt;

    wire [5:0]  iq_space;
    wire [1:0]  iss_valid;
    cpu_pkg::issue_t iss0, iss1;
    cpu_pkg::iup_e   port0, port1;
    wire iq_iss0_v, iq_iss1_v;
    wire [RB_C-1:0] iq_iss0_rob, iq_iss1_rob;

    // FU availability / grants (declared ahead of use by IQ)
    wire alu0_accept, alu1_accept, bru_accept, mul_free, div_free;
    wire lsu_free_ld, lsu_free_st;
    wire alu0_grant, alu1_grant, bru_grant, div_grant, mul_grant;

    rename u_rn (
        .clock, .reset,
        .in_valid(fe_valid), .in0(fe0), .in1(fe1), .in_take(fe_take),
        .rob_space(rob_space), .iq_space(iq_space), .rob_alloc_ptr(rob_alloc_ptr),
        .wb_clr_mask(wb_clr_mask), .reclaim_mask(reclaim_mask),
        .cmt_free_mask(cmt_free_mask),
        .flush_free_mask(flush_free_mask), .flush_pend_mask(flush_pend_mask),
        .flush_valid(rob_flush_valid), .restore_valid(restore_valid),
        .restore_pdst(restore_pdst),
        .rob_valid(rob_valid), .rob_rd0(rob_rd0), .rob_rd1(rob_rd1),
        .rob_pdst0(rob_pdst0), .rob_pdst1(rob_pdst1),
        .rob_old0(rob_old0), .rob_old1(rob_old1),
        .rob_load0(rob_load0), .rob_load1(rob_load1),
        .rob_store0(rob_store0), .rob_store1(rob_store1),
        .iq_valid(iq_valid), .iq_d0(iq_d0), .iq_d1(iq_d1)
    );

    wire cst0_valid, cst1_valid;
    wire [RB_C-1:0] cst0_rob, cst1_rob;

    rob u_rob (
        .clock, .reset,
        .disp_valid(rob_valid), .disp_rd0(rob_rd0), .disp_rd1(rob_rd1),
        .disp_pdst0(rob_pdst0), .disp_pdst1(rob_pdst1),
        .disp_old0(rob_old0), .disp_old1(rob_old1),
        .disp_load0(rob_load0), .disp_load1(rob_load1),
        .disp_store0(rob_store0), .disp_store1(rob_store1),
        .cst0_valid(cst0_valid), .cst0_rob(cst0_rob),
        .cst1_valid(cst1_valid), .cst1_rob(cst1_rob),
        .mk0_valid(iq_iss0_v), .mk0_rob(iq_iss0_rob),
        .mk1_valid(iq_iss1_v), .mk1_rob(iq_iss1_rob),
        .alloc_ptr(rob_alloc_ptr), .head_ptr(rob_head), .alloc_space(rob_space),
        .wb_a(ba), .wb_b(bb), .wb_a_ok(ba_ok), .wb_b_ok(bb_ok),
        .rec_a_valid(rec_a_valid), .rec_a_tag(rec_a_tag),
        .rec_b_valid(rec_b_valid), .rec_b_tag(rec_b_tag),
        .ndone_valid(lsu_ndone_valid), .ndone_rob(lsu_ndone_rob),
        .cmt_free_mask(cmt_free_mask),
        .flush_valid(rob_flush_valid), .flush_rob(rob_flush_rob),
        .flush_dtail(rob_flush_dtail),
        .flush_free_mask(flush_free_mask), .flush_pend_mask(flush_pend_mask),
        .restore_valid(restore_valid), .restore_pdst(restore_pdst)
    );

    iq u_iq (
        .clock, .reset,
        .disp_valid(iq_valid), .d0(iq_d0), .d1(iq_d1), .space(iq_space),
        .rob_head(rob_head),
        .wb_a(ba_ok), .wb_b(bb_ok),
        .flush_valid(rob_flush_valid), .flush_rob(rob_flush_rob),
        .flush_dtail(rob_flush_dtail),
        .alu0_free(alu0_accept), .alu1_free(alu1_accept), .bru_free(bru_accept),
        .mul_free(mul_free), .div_free(div_free),
        .lsu_free_ld(lsu_free_ld), .lsu_free_st(lsu_free_st),
        .iss_valid(iss_valid), .iss0(iss0), .iss1(iss1),
        .port0(port0), .port1(port1),
        .iss0_v(iq_iss0_v), .iss0_rob(iq_iss0_rob),
        .iss1_v(iq_iss1_v), .iss1_rob(iq_iss1_rob)
    );

    wire [31:0] prf_r0, prf_r1, prf_r2, prf_r3;
    prf u_prf (
        .clock, .reset,
        .raddr0(iss0.ps1), .raddr1(iss0.ps2),
        .raddr2(iss1.ps1), .raddr3(iss1.ps2),
        .rdata0(prf_r0), .rdata1(prf_r1), .rdata2(prf_r2), .rdata3(prf_r3),
        .wr_valid({bb_ok.valid, ba_ok.valid}),
        .waddr0(ba_ok.prf_tag), .waddr1(bb_ok.prf_tag),
        .wdata0(ba_ok.result),  .wdata1(bb_ok.result)
    );

    // operand selection (B = imm for uses_imm ops, else rs2 value).
    // WB_BYPASS: an operand tag matching this cycle's qualified writeback is
    // taken directly from the result bus (the PRF write lands only at the edge,
    // so a same-cycle PRF read would return the stale value). ps==0 (x0 / no
    // operand) is never bypassed — PRF[0] is the constant 0.
    wire        byp_en   = (cpu_pkg::WB_BYPASS != 0);
    wire        ba_byp_v = byp_en && ba_ok.valid && (ba_ok.prf_tag != 6'd0);
    wire        bb_byp_v = byp_en && bb_ok.valid && (bb_ok.prf_tag != 6'd0);
    wire [31:0] opa0 = (ba_byp_v && (iss0.ps1 == ba_ok.prf_tag)) ? ba_ok.result :
                       (bb_byp_v && (iss0.ps1 == bb_ok.prf_tag)) ? bb_ok.result : prf_r0;
    wire [31:0] opb0 = iss0.insn.uses_imm ? iss0.insn.imm :
                       (ba_byp_v && (iss0.ps2 == ba_ok.prf_tag)) ? ba_ok.result :
                       (bb_byp_v && (iss0.ps2 == bb_ok.prf_tag)) ? bb_ok.result : prf_r1;
    wire [31:0] opa1 = (ba_byp_v && (iss1.ps1 == ba_ok.prf_tag)) ? ba_ok.result :
                       (bb_byp_v && (iss1.ps1 == bb_ok.prf_tag)) ? bb_ok.result : prf_r2;
    wire [31:0] opb1 = iss1.insn.uses_imm ? iss1.insn.imm :
                       (ba_byp_v && (iss1.ps2 == ba_ok.prf_tag)) ? ba_ok.result :
                       (bb_byp_v && (iss1.ps2 == bb_ok.prf_tag)) ? bb_ok.result : prf_r3;

    // ================= ALU0 =================
    wire a0_i0 = iss_valid[0] && (port0 == cpu_pkg::IUP_ALU0);
    wire a0_i1 = iss_valid[1] && (port1 == cpu_pkg::IUP_ALU0);
    wire a0_i  = a0_i0 || a0_i1;
    wire cpu_pkg::decoded_t a0_insn = a0_i0 ? iss0.insn : iss1.insn;
    wire [31:0] a0_a = a0_i0 ? opa0 : opa1;
    wire [31:0] a0_b = a0_i0 ? opb0 : opb1;
    wire [PB_C-1:0] a0_pdst = a0_i0 ? iss0.pdst : iss1.pdst;
    wire [RB_C-1:0] a0_rob  = a0_i0 ? iss0.rob  : iss1.rob;
    wire [31:0] a0_res;
    alu u_alu0 (.in_valid(a0_i), .in_op(a0_insn.op), .in_funct3(a0_insn.funct3),
        .in_funct7(a0_insn.funct7), .in_uses_imm(a0_insn.uses_imm),
        .in_a(a0_a), .in_b(a0_b), .in_pc(a0_insn.pc), .in_imm(a0_insn.imm),
        .out_res(a0_res));

    logic a0_hv; cpu_pkg::writeback_t a0_h;
    assign alu0_grant  = a0_hv;
    assign alu0_accept = !a0_hv || alu0_grant;
    wire a0_go = a0_i && alu0_accept;
    always_ff @(posedge clock) begin
        if (reset) a0_hv <= 1'b0;
        else if (alu0_grant) begin
            if (a0_go) begin a0_h <= {1'b1, a0_pdst, a0_rob, a0_res}; a0_hv <= 1'b1; end
            else a0_hv <= 1'b0;
        end else if (a0_go) begin
            a0_h <= {1'b1, a0_pdst, a0_rob, a0_res}; a0_hv <= 1'b1;
        end else if (rob_flush_valid && a0_hv && (a0_h.prf_tag == 6'd0) &&
                     cpu_pkg::flush_younger(a0_h.rob, rob_flush_rob, rob_flush_dtail)) a0_hv <= 1'b0;
    end

    // ================= ALU1 =================
    wire a1_i0 = iss_valid[0] && (port0 == cpu_pkg::IUP_ALU1);
    wire a1_i1 = iss_valid[1] && (port1 == cpu_pkg::IUP_ALU1);
    wire a1_i  = a1_i0 || a1_i1;
    wire cpu_pkg::decoded_t a1_insn = a1_i0 ? iss0.insn : iss1.insn;
    wire [31:0] a1_a = a1_i0 ? opa0 : opa1;
    wire [31:0] a1_b = a1_i0 ? opb0 : opb1;
    wire [PB_C-1:0] a1_pdst = a1_i0 ? iss0.pdst : iss1.pdst;
    wire [RB_C-1:0] a1_rob  = a1_i0 ? iss0.rob  : iss1.rob;
    wire [31:0] a1_res;
    alu u_alu1 (.in_valid(a1_i), .in_op(a1_insn.op), .in_funct3(a1_insn.funct3),
        .in_funct7(a1_insn.funct7), .in_uses_imm(a1_insn.uses_imm),
        .in_a(a1_a), .in_b(a1_b), .in_pc(a1_insn.pc), .in_imm(a1_insn.imm),
        .out_res(a1_res));

    logic a1_hv; cpu_pkg::writeback_t a1_h;
    assign alu1_grant  = !lsu_wb_valid && !mul_skid_out.valid && a1_hv;
    assign alu1_accept = !a1_hv || alu1_grant;
    wire a1_go = a1_i && alu1_accept;
    always_ff @(posedge clock) begin
        if (reset) a1_hv <= 1'b0;
        else if (alu1_grant) begin
            if (a1_go) begin a1_h <= {1'b1, a1_pdst, a1_rob, a1_res}; a1_hv <= 1'b1; end
            else a1_hv <= 1'b0;
        end else if (a1_go) begin
            a1_h <= {1'b1, a1_pdst, a1_rob, a1_res}; a1_hv <= 1'b1;
        end else if (rob_flush_valid && a1_hv && (a1_h.prf_tag == 6'd0) &&
                     cpu_pkg::flush_younger(a1_h.rob, rob_flush_rob, rob_flush_dtail)) a1_hv <= 1'b0;
    end

    // ================= BRU =================
    wire b_i0 = iss_valid[0] && (port0 == cpu_pkg::IUP_BRU);
    wire b_i1 = iss_valid[1] && (port1 == cpu_pkg::IUP_BRU);
    wire b_i  = b_i0 || b_i1;
    wire cpu_pkg::decoded_t b_insn = b_i0 ? iss0.insn : iss1.insn;
    wire [$clog2(cpu_pkg::BHT_ENTRIES)-1:0] b_bix = b_i0 ? iss0.bix : iss1.bix;
    wire [31:0] b_a = b_i0 ? opa0 : opa1;
    wire [31:0] b_b = b_i0 ? opb0 : opb1;
    wire [PB_C-1:0] b_pdst = b_i0 ? iss0.pdst : iss1.pdst;
    wire [RB_C-1:0] b_rob  = b_i0 ? iss0.rob  : iss1.rob;
    wire [5:0]  b_bsf  = b_i0 ? iss0.bsf  : iss1.bsf;
    wire        b_pt   = b_i0 ? iss0.pred_taken  : iss1.pred_taken;
    wire [31:0] b_ptg  = b_i0 ? iss0.pred_target : iss1.pred_target;
    wire [31:0] b_link, b_tgt;
    wire        b_taken, b_mispred;
    bru u_bru (.in_valid(b_i), .in_op(b_insn.op), .in_funct3(b_insn.funct3),
        .in_a(b_a), .in_b(b_b), .in_pc(b_insn.pc), .in_imm(b_insn.imm),
        .in_pred_taken(b_pt), .in_pred_target(b_ptg),
        .out_link(b_link), .out_taken(b_taken), .out_target(b_tgt),
        .out_mispred(b_mispred));

    logic b_hv; cpu_pkg::writeback_t b_h;
    assign bru_grant  = !a0_hv && b_hv;
    assign bru_accept = !b_hv || bru_grant;
    wire b_go = b_i && bru_accept;
    always_ff @(posedge clock) begin
        if (reset) b_hv <= 1'b0;
        else if (bru_grant) begin
            if (b_go) begin b_h <= {1'b1, b_pdst, b_rob, b_link}; b_hv <= 1'b1; end
            else b_hv <= 1'b0;
        end else if (b_go) begin
            b_h <= {1'b1, b_pdst, b_rob, b_link}; b_hv <= 1'b1;
        end else if (rob_flush_valid && b_hv && (b_h.prf_tag == 6'd0) &&
                     cpu_pkg::flush_younger(b_h.rob, rob_flush_rob, rob_flush_dtail)) b_hv <= 1'b0;
    end

    // flush broadcast: registered one cycle after the branch resolves
    always_ff @(posedge clock) begin
        if (reset) begin
            flush_r <= '0;
        end else if (b_i && b_mispred) begin
            flush_r.valid <= 1'b1;
            flush_r.pc    <= b_taken ? b_tgt : (b_insn.pc + 32'd4);
            flush_r.rob   <= b_rob;
            flush_r.bsf   <= b_bsf;
        end else begin
            flush_r.valid <= 1'b0;
        end
    end

    // M8b: early redirect presented combinationally in the resolve cycle (the
    // registered flush_r above broadcasts the kill one cycle later).
    assign redir_valid = b_i && b_mispred;
    assign redir_pc    = b_taken ? b_tgt : (b_insn.pc + 32'd4);
    assign redir_bsf   = b_bsf;

    // ================= MUL =================
    wire m_i0 = iss_valid[0] && (port0 == cpu_pkg::IUP_MUL);
    wire m_i1 = iss_valid[1] && (port1 == cpu_pkg::IUP_MUL);
    wire m_i  = m_i0 || m_i1;
    wire cpu_pkg::decoded_t m_insn = m_i0 ? iss0.insn : iss1.insn;
    wire [31:0] m_a = m_i0 ? opa0 : opa1;
    wire [31:0] m_b = m_i0 ? opb0 : opb1;
    wire [PB_C-1:0] m_pdst = m_i0 ? iss0.pdst : iss1.pdst;
    wire [RB_C-1:0] m_rob  = m_i0 ? iss0.rob  : iss1.rob;
    wire        mul_req_ready, mul_wb_valid;
    wire [PB_C-1:0] mul_wb_tag;
    wire [RB_C-1:0] mul_wb_rob;
    wire [31:0] mul_wb_data;
    logic [2:0] mul_occ;
    mul u_mul (.clock, .reset,
        .req_valid(m_i), .req_a(m_a), .req_b(m_b), .req_funct3(m_insn.funct3),
        .req_tag(m_pdst), .req_rob(m_rob), .req_ready(mul_req_ready),
        .wb_valid(mul_wb_valid), .wb_tag(mul_wb_tag), .wb_rob(mul_wb_rob),
        .wb_data(mul_wb_data));

    cpu_pkg::writeback_t mul_skid_out;
    wire mul_skid_in_ready, mul_skid_accept;
    wire [2:0] mul_skid_level;
    wb_skid u_mul_skid (.clock, .reset,
        .in({mul_wb_valid, mul_wb_tag, mul_wb_rob, mul_wb_data}),
        .in_ready(mul_skid_in_ready), .out(mul_skid_out), .out_accept(mul_skid_accept),
        .level(mul_skid_level));

    always_ff @(posedge clock) begin
        if (reset) mul_occ <= 3'd0;
        else mul_occ <= mul_occ + {2'b0, (m_i && mul_req_ready)} -
                                 {2'b0, mul_wb_valid};
    end
    // Capacity invariant: (skid level) + (in-flight beats) <= DEPTH, so a beat
    // arriving from the fixed-latency MUL pipeline always finds room; without
    // the level term a full skid would silently drop the beat (the unit has no
    // backpressure) and the ROB entry would never complete.
    assign mul_free = ({1'b0, mul_occ} + {1'b0, mul_skid_level} < 4'd4) &&
                      mul_skid_in_ready;

    // ================= DIV =================
    wire d_i0 = iss_valid[0] && (port0 == cpu_pkg::IUP_DIV);
    wire d_i1 = iss_valid[1] && (port1 == cpu_pkg::IUP_DIV);
    wire d_i  = d_i0 || d_i1;
    wire cpu_pkg::decoded_t d_insn = d_i0 ? iss0.insn : iss1.insn;
    wire [31:0] d_a = d_i0 ? opa0 : opa1;
    wire [31:0] d_b = d_i0 ? opb0 : opb1;
    wire [PB_C-1:0] d_pdst = d_i0 ? iss0.pdst : iss1.pdst;
    wire [RB_C-1:0] d_rob  = d_i0 ? iss0.rob  : iss1.rob;
    wire        div_req_ready, div_wb_valid;
    wire [PB_C-1:0] div_wb_tag;
    wire [RB_C-1:0] div_wb_rob;
    wire [31:0] div_wb_data;
    div u_div (.clock, .reset,
        .req_valid(d_i), .req_a(d_a), .req_b(d_b),
        // Fused DIV/REM pair beat (design §6.4.3) is kept in the unit;
        // wiring `is_fuse` through rename/IQ is deferred (single-beat path used).
        .req_f3a(d_insn.funct3), .req_f3b(3'b0), .req_fused(1'b0),
        .req_tag_a(d_pdst), .req_rob_a(d_rob),
        .req_tag_b(6'b0), .req_rob_b(5'b0),
        .req_ready(div_req_ready),
        .wb_valid(div_wb_valid), .wb_tag(div_wb_tag), .wb_rob(div_wb_rob),
        .wb_data(div_wb_data));

    cpu_pkg::writeback_t div_skid_out;
    wire div_skid_in_ready, div_skid_accept;
    wire [2:0] div_skid_level;
    wb_skid u_div_skid (.clock, .reset,
        .in({div_wb_valid, div_wb_tag, div_wb_rob, div_wb_data}),
        .in_ready(div_skid_in_ready), .out(div_skid_out), .out_accept(div_skid_accept),
        .level(div_skid_level));
    // One DIV op emits at most two beats and the unit is single-op, so keeping
    // two slots free guarantees its beats are accepted.
    assign div_free = div_req_ready && ({1'b0, div_skid_level} <= 3'd2) &&
                      div_skid_in_ready;


    // ================= LSU (M3: lsu_b + lsu_a/dcache crossing the top) ======
    wire l_i0 = iss_valid[0] && (port0 == cpu_pkg::IUP_LSU);
    wire l_i1 = iss_valid[1] && (port1 == cpu_pkg::IUP_LSU);
    wire l_i  = l_i0 || l_i1;
    wire cpu_pkg::issue_t l_iss = l_i0 ? iss0 : iss1;
    wire [31:0] l_base = l_i0 ? opa0 : opa1;
    wire [31:0] l_data = l_i0 ? opb0 : opb1;

    wire        lsu_ld_ok, lsu_st_ok, lsu_wb_valid, lsu_ndone_valid;
    wire [PB_C-1:0] lsu_wb_tag;
    wire [RB_C-1:0] lsu_wb_rob, lsu_ndone_rob;
    wire [31:0] lsu_wb_data;
    wire        lsu_wb_ready = lsu_wb_valid;   // BB priority 0
    lsu_b u_lsu (.clock, .reset,
        .in_valid(l_i),
        .in_op(l_iss.insn.op),
        .in_funct3(l_iss.insn.funct3),
        .in_base(l_base),
        .in_imm(l_iss.insn.imm),
        .in_store_data(l_data),
        .in_pdst(l_iss.pdst), .in_rob(l_iss.rob),
        // M8 (§16.4): store data may still be in flight; hand ps2 + readiness
        // to the STQ, which fills the value later from the writeback bus.
        .in_ps2(l_iss.ps2), .in_rs2_ready(l_iss.rs2_ready),
        .wb_a(ba_ok), .wb_b(bb_ok),
        .ld_alloc_ok(lsu_ld_ok), .st_alloc_ok(lsu_st_ok),
        .wb_valid(lsu_wb_valid), .wb_tag(lsu_wb_tag), .wb_rob(lsu_wb_rob),
        .wb_data(lsu_wb_data), .wb_ready(lsu_wb_ready),
        .ndone_valid(lsu_ndone_valid), .ndone_rob(lsu_ndone_rob),
        .rob_head(rob_head),
        .cmt_valid({cst1_valid, cst0_valid}),
        .cmt_rob0(cst0_rob), .cmt_rob1(cst1_rob),
        .flush_valid(rob_flush_valid), .flush_rob(rob_flush_rob),
        .flush_dtail(rob_flush_dtail),
        .ld_valid, .ld_req, .ld_ready,
        .st_valid, .st_req, .st_ready,
        .resp_valid, .resp, .resp_replay,
        .probe_addr(probe_addr), .probe_hit(probe_hit));
    assign lsu_free_ld = lsu_ld_ok;
    assign lsu_free_st = lsu_st_ok;

    // ================= result buses BA / BB =================
    // Fixed priority (design §4.4): BA ALU0 > BRU > DIV; BB LSU > MUL > ALU1.
    assign mul_grant = !lsu_wb_valid && mul_skid_out.valid;
    // alu1_grant / alu0_grant / bru_grant are assigned in their FU sections.
    assign div_grant = !a0_hv && !b_hv && div_skid_out.valid;

    assign div_skid_accept = div_grant;
    assign mul_skid_accept = mul_grant;

    always_comb begin
        ba = '0;
        if (a0_hv)                   ba = a0_h;
        else if (b_hv)               ba = b_h;
        else if (div_skid_out.valid) ba = div_skid_out;
    end

    always_comb begin
        bb = '0;
        if (lsu_wb_valid)          bb = {1'b1, lsu_wb_tag, lsu_wb_rob, lsu_wb_data};
        else if (mul_skid_out.valid) bb = mul_skid_out;
        else if (a1_hv)            bb = a1_h;
    end

    // ================= writeback filter / rename masks =================
    assign wb_clr_mask =
        (ba_ok.valid ? (ONE_C << ba_ok.prf_tag) : '0) |
        (bb_ok.valid ? (ONE_C << bb_ok.prf_tag) : '0);
    assign reclaim_mask =
        (rec_a_valid ? (ONE_C << rec_a_tag) : '0) |
        (rec_b_valid ? (ONE_C << rec_b_tag) : '0);

endmodule
