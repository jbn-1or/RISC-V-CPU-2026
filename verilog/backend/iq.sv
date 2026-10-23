// Unified issue queue (design.md §6.3): 16 entries with CAM wakeup on the two
// qualified writeback buses, rotating selection of up to 2 ready entries per
// cycle, flush killing by ROB ring distance, and function-unit availability
// gating. Entries live in fixed slots; freed slots are reused via a free-slot
// finder (order is carried by the rob tag, not the slot index).
module iq (
    input  wire        clock,
    input  wire        reset,

    // dispatch (rename, program order)
    input  wire [1:0]  disp_valid,
    input  cpu_pkg::renamed_t d0,
    input  cpu_pkg::renamed_t d1,
    output wire [$clog2(cpu_pkg::IQ_DEPTH+1)-1:0] space,

    // wakeup (qualified writebacks)
    input  cpu_pkg::writeback_t wb_a,
    input  cpu_pkg::writeback_t wb_b,

    // commit head (age reference for in-order LSU issue)
    input  wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] rob_head,

    // flush
    input  wire        flush_valid,
    input  wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] flush_rob,
    input  wire [$clog2(cpu_pkg::ROB_DEPTH):0] flush_dtail,

    // function-unit availability
    input  wire        alu0_free,
    input  wire        alu1_free,
    input  wire        bru_free,
    input  wire        mul_free,
    input  wire        div_free,
    input  wire        lsu_free_ld,     // LDQ room (load candidate readiness)
    input  wire        lsu_free_st,     // STQ room (store candidate readiness)


    // issue
    output wire [1:0]         iss_valid,
    output cpu_pkg::issue_t   iss0,
    output cpu_pkg::issue_t   iss1,
    output logic [2:0]        port0,
    output logic [2:0]        port1,
    // issued rob numbers (ROB marks these entries 'issued' for reclaim)
    output logic              iss0_v,
    output logic [$clog2(cpu_pkg::ROB_DEPTH)-1:0]     iss0_rob,
    output logic              iss1_v,
    output logic [$clog2(cpu_pkg::ROB_DEPTH)-1:0]     iss1_rob,
);
    localparam int D = cpu_pkg::IQ_DEPTH;
    localparam int SB = (D > 1) ? $clog2(D) : 1;   // slot index bits
    localparam int SPW = $clog2(D + 1);            // occupancy width (holds D)
    localparam logic [D-1:0] ONE = 1;
    localparam logic [SPW-1:0] DCAP = D[SPW-1:0];

    localparam int PB = $clog2(cpu_pkg::PRF_NUM);
    localparam int RB = $clog2(cpu_pkg::ROB_DEPTH);
    logic [D-1:0] v_q, r1_q, r2_q;
    logic [PB-1:0] ps1_q [0:D-1];
    logic [PB-1:0] ps2_q [0:D-1];
    logic [PB-1:0] pdst_q[0:D-1];
    logic [RB-1:0] rob_q [0:D-1];
    logic [5:0]   bsf_q [0:D-1];
    logic [$clog2(cpu_pkg::BHT_ENTRIES)-1:0] bix_q [0:D-1];
    logic [2:0]   fu_q  [0:D-1];
    logic         pt_q  [0:D-1];
    logic [31:0]  ptg_q [0:D-1];
    cpu_pkg::decoded_t insn_q [0:D-1];
    logic [SB-1:0] rot_q;

    // ---------------- free-slot allocation ----------------
    function automatic logic [SB-1:0] lowest(input logic [D-1:0] f);
        lowest = '0;
        for (int i = D-1; i >= 0; i = i - 1)
            if (f[i]) lowest = i[SB-1:0];
    endfunction
    logic s0v, s1v;
    logic [SB-1:0] s0, s1;
    wire [D-1:0] issued_mask = (s0v ? (ONE << s0) : '0) |
                                 (s1v ? (ONE << s1) : '0);
    // Entries read by issue leave at this edge, so dispatch can reuse their
    // slots without enlarging the wakeup/selection window.
    wire [D-1:0] freeslot = ~v_q | issued_mask;
    wire [SB-1:0] pos0 = lowest(freeslot);
    logic [D-1:0] st_ent_q;   // per-entry "is store" bit (packed: Yosys-safe)
    wire [SB-1:0] pos1 = lowest(freeslot & ~(ONE << pos0));

    logic [SPW-1:0] used_cnt;
    always_comb begin
        used_cnt = '0;
        for (int i = 0; i < D; i = i + 1)
            used_cnt = used_cnt + {{(SPW-1){1'b0}}, v_q[i]};
    end
    assign space = DCAP - used_cnt + SPW'(s0v) + SPW'(s1v);

    // ---------------- flush kill set ----------------
    logic [D-1:0] kill;
    always_comb begin
        for (int i = 0; i < D; i = i + 1)
            kill[i] = flush_valid && v_q[i] &&
                      cpu_pkg::flush_younger(rob_q[i], flush_rob, flush_dtail);
    end

    // ---------------- wakeup hits ----------------
    logic [D-1:0] r1_set, r2_set;
    always_comb begin
        for (int i = 0; i < D; i = i + 1) begin
            r1_set[i] = v_q[i] &&
                ((wb_a.valid && (ps1_q[i] == wb_a.prf_tag)) ||
                 (wb_b.valid && (ps1_q[i] == wb_b.prf_tag)));
            r2_set[i] = v_q[i] &&
                ((wb_a.valid && (ps2_q[i] == wb_a.prf_tag)) ||
                 (wb_b.valid && (ps2_q[i] == wb_b.prf_tag)));
        end
    end

    // ---------------- LSU issue gating (M8: store address-only issue) ------------
    // A memory op reaches the STQ/LDQ only at its own issue. Therefore:
    //   * A store may issue only when it is the oldest pending store in the IQ
    //     (an entry leaves the IQ exactly when it issues, so every store still
    //     resident is unissued). Stores thus issue strictly in program order, so
    //     STQ allocation order equals program order and STQ FIFO drain stays
    //     correct. M8 relaxation: a store issues as soon as its *address*
    //     operand (rs1) is ready; its data (rs2) may still be pending and is
    //     filled into the STQ later via the writeback-bus CAM (lsu_b). The
    //     address is fully known the moment the store enters the STQ.
    //   * A load may issue only while it precedes that oldest pending store (or
    //     when no store is pending). It may therefore never bypass an older store
    //     that has not yet reached the STQ.
    // Ordering proof (rewritten for M8): when a load L issues, every store
    // program-older than L is also older than the oldest pending store, hence has
    // already issued and sits in the STQ *with its address known* (the M8 rule
    // still requires address readiness to issue). lsu_b's overlap detection is a
    // pure function of the stored addresses (§7.2, program-order key), so L sees
    // the complete set of older stores and never reads a location an older store
    // will overwrite. Data readiness changes only *which* source L forwards from:
    // if the newest older overlapping store's data is still in flight
    // (data_valid=0), L cannot forward early and blocks under §7.2 rule 2 exactly
    // as it would for a store that has not completed — correctness is unaffected.
    // Loads issuing out of order are otherwise harmless: they never write memory,
    // and a younger store cannot have dirtied the location before L reads it,
    // because stores drain only after retirement and retirement is in program
    // order (L retires before any younger store, so it also executes first).
    // flush: killed entries are excluded from the head search here and are still
    // gated by kill[i] at issue.
    // Selection priority: among the ready, eligible LSU ops the oldest is chosen
    // (lsu_sel), so the in-order oldest keeps issuing first and only steps aside
    // while it is not operand-ready or its queue has no room. This avoids letting
    // round-robin hand the single LSU port to a younger op while the older one is
    // ready, which measurably delayed the critical in-order memory op.
    // UNOPTFLAT safety: these predicates depend only on registered state, the
    // writeback bus, rob_head and the LSU readiness inputs, never on the selected
    // op (§5A-20).
    logic [D-1:0] lsu_v, lsu_st_v, lsu_elig, lsu_sel;
    // Frequency-first: issue selection must not depend on the combinational
    // flush kill mask.  On a flush cycle the whole issue port is suppressed
    // for one cycle (issue_en), which is enough to keep LSU allocations out of
    // the flush window; older entries simply issue after the flush cycle.
    wire          issue_en = !flush_valid;
    always_comb begin
        logic found;
        logic [RB-1:0] best;
        logic [SB-1:0] bi;
        logic f2;
        logic [RB-1:0] b2;
        logic [SB-1:0] i2;
        lsu_v = '0; lsu_st_v = '0; lsu_elig = '0; lsu_sel = '0;
        found = 1'b0; best = '0; bi = '0;
        for (int i = 0; i < D; i = i + 1) begin
            lsu_v[i]    = v_q[i] && (fu_q[i] == cpu_pkg::FU_LSU);
            lsu_st_v[i] = lsu_v[i] && st_ent_q[i];
            if (lsu_st_v[i] && (!found || ((rob_q[i] - rob_head) < best))) begin
                best = rob_q[i] - rob_head;
                bi   = i[SB-1:0];
                found = 1'b1;
            end
        end
        for (int i = 0; i < D; i = i + 1) begin
            if (st_ent_q[i])
                // store: only the head of the pending stores may issue
                lsu_elig[i] = lsu_v[i] && found && (i[SB-1:0] == bi);
            else
                // load: only if it precedes the oldest pending store (or none)
                lsu_elig[i] = lsu_v[i] &&
                              (!found || ((rob_q[i] - rob_head) < best));
        end
        f2 = 1'b0; b2 = '0; i2 = '0;
        for (int i = 0; i < D; i = i + 1) begin
            logic rdy;
            // M8 (§16.4): a store needs only its address operand (rs1) to
            // issue; its data (rs2) is filled into the STQ later via the
            // writeback-bus CAM. A load still needs both operands ready.
            rdy = (r1_q[i] || ((cpu_pkg::WB_BYPASS != 0) && r1_set[i])) &&
                  (st_ent_q[i] || (r2_q[i] || ((cpu_pkg::WB_BYPASS != 0) && r2_set[i])));
            if (lsu_elig[i] && rdy && (st_ent_q[i] ? lsu_free_st : lsu_free_ld)) begin
                if (!f2 || ((rob_q[i] - rob_head) < b2)) begin
                    b2 = rob_q[i] - rob_head;
                    i2 = i[SB-1:0];
                    f2 = 1'b1;
                end
            end
        end
        if (f2) lsu_sel[i2] = 1'b1;
    end

    // ---------------- issue selection ----------------
    always_comb begin
        logic a0, a1, bru, mul, div, lsu_ld, lsu_st;
        logic [SB-1:0] i;
        logic ok;
        cpu_pkg::iup_e port;
        s0v = 1'b0; s1v = 1'b0; s0 = '0; s1 = '0;
        port0 = cpu_pkg::IUP_ALU0; port1 = cpu_pkg::IUP_ALU0;        a0 = alu0_free; a1 = alu1_free;
        bru = bru_free; mul = mul_free; div = div_free;
        lsu_ld = lsu_free_ld; lsu_st = lsu_free_st;
        for (int n = 0; n < D; n = n + 1) begin
            i = rot_q + n[SB-1:0];
            // WB bypass: an operand wired to this cycle's qualified writeback is
            // usable immediately (the value is taken from the bus in core_ooo).
            // M8 (§16.4): stores issue on address (rs1) readiness alone.
            ok = v_q[i] && issue_en &&
                 (r1_q[i] || ((cpu_pkg::WB_BYPASS != 0) && r1_set[i])) &&
                 (st_ent_q[i] || r2_q[i] || ((cpu_pkg::WB_BYPASS != 0) && r2_set[i]));
            port = cpu_pkg::IUP_ALU0;
            if (ok) begin
                case (fu_q[i])
                    cpu_pkg::FU_ALU: begin
                        if (a0) begin port = cpu_pkg::IUP_ALU0; a0 = 1'b0; end
                        else if (a1) begin port = cpu_pkg::IUP_ALU1; a1 = 1'b0; end
                        else ok = 1'b0;
                    end
                    cpu_pkg::FU_BR: begin
                        if (bru) bru = 1'b0; else ok = 1'b0;
                        port = cpu_pkg::IUP_BRU;
                    end
                    cpu_pkg::FU_MUL: begin
                        if (mul) mul = 1'b0; else ok = 1'b0;
                        port = cpu_pkg::IUP_MUL;
                    end
                    cpu_pkg::FU_DIV: begin
                        if (div) div = 1'b0; else ok = 1'b0;
                        port = cpu_pkg::IUP_DIV;
                    end
                    cpu_pkg::FU_LSU: begin
                        // relaxed in-order gate (see lsu_elig above): oldest
                        // pending store, or a load older than it; readiness is
                        // per op kind (registered bit, no comb loop, no indexed
                        // struct-field access for Yosys)
                        if ((st_ent_q[i] ? lsu_st : lsu_ld) &&
                            lsu_sel[i]) begin
                            lsu_ld = 1'b0; lsu_st = 1'b0;
                        end else ok = 1'b0;
                        port = cpu_pkg::IUP_LSU;
                    end
                    default: ok = 1'b0;
                endcase
            end
            if (ok && !s0v) begin s0v = 1'b1; s0 = i; port0 = port; end
            else if (ok && !s1v) begin s1v = 1'b1; s1 = i; port1 = port; end
        end
    end
    assign iss_valid = {s1v, s0v};
    assign iss0_v = s0v;  assign iss0_rob = rob_q[s0];
    assign iss1_v = s1v;  assign iss1_rob = rob_q[s1];

    always_comb begin
        iss0 = '0;
        iss0.insn        = insn_q[s0];
        iss0.ps1         = ps1_q[s0];
        iss0.ps2         = ps2_q[s0];
        iss0.pdst        = pdst_q[s0];
        iss0.rob         = rob_q[s0];
        iss0.bsf         = bsf_q[s0];
        iss0.pred_taken  = pt_q[s0];
        iss0.pred_target = ptg_q[s0];
        iss0.bix         = bix_q[s0];
        iss0.rs2_ready   = r2_q[s0] || ((cpu_pkg::WB_BYPASS != 0) && r2_set[s0]);

        iss1 = '0;
        iss1.insn        = insn_q[s1];
        iss1.ps1         = ps1_q[s1];
        iss1.ps2         = ps2_q[s1];
        iss1.pdst        = pdst_q[s1];
        iss1.rob         = rob_q[s1];
        iss1.bsf         = bsf_q[s1];
        iss1.pred_taken  = pt_q[s1];
        iss1.pred_target = ptg_q[s1];
        iss1.bix         = bix_q[s1];
        iss1.rs2_ready   = r2_q[s1] || ((cpu_pkg::WB_BYPASS != 0) && r2_set[s1]);
    end

    // dispatch wakeup bypass
    wire d0w1a = wb_a.valid && (d0.ps1 == wb_a.prf_tag);
    wire d0w1b = wb_b.valid && (d0.ps1 == wb_b.prf_tag);
    wire d0w2a = wb_a.valid && (d0.ps2 == wb_a.prf_tag);
    wire d0w2b = wb_b.valid && (d0.ps2 == wb_b.prf_tag);
    wire d1w1a = wb_a.valid && (d1.ps1 == wb_a.prf_tag);
    wire d1w1b = wb_b.valid && (d1.ps1 == wb_b.prf_tag);
    wire d1w2a = wb_a.valid && (d1.ps2 == wb_a.prf_tag);
    wire d1w2b = wb_b.valid && (d1.ps2 == wb_b.prf_tag);

    // ---------------- state ----------------
    always_ff @(posedge clock) begin
        if (reset) begin
            v_q <= '0; r1_q <= '0; r2_q <= '0; rot_q <= '0;
        end else begin
            // clear issued and killed
            for (int i = 0; i < D; i = i + 1)
                if (v_q[i] && ((s0v && (s0 == i[SB-1:0])) || (s1v && (s1 == i[SB-1:0])) ||
                               kill[i]))
                    v_q[i] <= 1'b0;
            // dispatch
            if (disp_valid[0] && !kill[pos0]) begin
                v_q[pos0]   <= 1'b1;
                r1_q[pos0]  <= d0.rs1_ready || d0w1a || d0w1b;
                r2_q[pos0]  <= d0.rs2_ready || d0w2a || d0w2b;
                ps1_q[pos0] <= d0.ps1;   ps2_q[pos0] <= d0.ps2;
                pdst_q[pos0]<= d0.pdst;  rob_q[pos0] <= d0.rob;
                bsf_q[pos0] <= d0.bsf;   fu_q[pos0]  <= d0.insn.fu;
                pt_q[pos0]  <= d0.pred_taken; ptg_q[pos0] <= d0.pred_target;
                bix_q[pos0] <= d0.bix;
                insn_q[pos0]<= d0.insn;
                st_ent_q[pos0] <= (d0.insn.op == cpu_pkg::OP_STORE);
            end
            if (disp_valid[1]) begin
                v_q[pos1]   <= 1'b1;
                r1_q[pos1]  <= d1.rs1_ready || d1w1a || d1w1b;
                r2_q[pos1]  <= d1.rs2_ready || d1w2a || d1w2b;
                ps1_q[pos1] <= d1.ps1;   ps2_q[pos1] <= d1.ps2;
                pdst_q[pos1]<= d1.pdst;  rob_q[pos1] <= d1.rob;
                bsf_q[pos1] <= d1.bsf;   fu_q[pos1]  <= d1.insn.fu;
                pt_q[pos1]  <= d1.pred_taken; ptg_q[pos1] <= d1.pred_target;
                bix_q[pos1] <= d1.bix;
                insn_q[pos1]<= d1.insn;
                st_ent_q[pos1] <= (d1.insn.op == cpu_pkg::OP_STORE);
            end
            // wakeup
            for (int i = 0; i < D; i = i + 1) begin
                if (v_q[i] && !(disp_valid[0] && pos0 == i[SB-1:0]) &&
                              !(disp_valid[1] && pos1 == i[SB-1:0])) begin
                    if (r1_set[i]) r1_q[i] <= 1'b1;
                    if (r2_set[i]) r2_q[i] <= 1'b1;
                end
            end
            // rotation
            if (s1v)      rot_q <= s1 + 1'b1;
            else if (s0v) rot_q <= s0 + 1'b1;
            else          rot_q <= rot_q + 1'b1;
        end
    end

endmodule
