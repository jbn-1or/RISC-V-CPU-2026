// Unified issue queue: IQ_DEPTH entries with CAM wakeup on the two
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
    output logic [$clog2(cpu_pkg::ROB_DEPTH)-1:0]     iss1_rob
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
    logic [$clog2(cpu_pkg::BHT_ENTRIES)-1:0] bix_q [0:D-1];
    logic [2:0]   fu_q  [0:D-1];
    logic         pt_q  [0:D-1];
    logic [31:0]  ptg_q [0:D-1];
    logic [$bits(d0.insn)-1:0] insn_q [0:D-1];
    logic [SB-1:0] rot_q;
    wire [RB-1:0] age [0:D-1];
    generate for (genvar a = 0; a < D; a = a+1) begin : g_age
        assign age[a] = RB'(rob_q[a]-rob_head);
    end endgenerate

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

    // ---------------- memory ordering at issue ----------------
    // Stores issue in order as soon as rs1 is ready; rs2 may arrive later on
    // writeback. A load cannot pass the oldest unissued store. Thus every older
    // store address is already known to the LSQ when a load enters it, and the
    // forwarding/blocking checks see all potential dependencies.
    // Younger stores cannot change memory before that load executes, since
    // stores drain only after in-order retirement. Issue pauses on recovery;
    // the sequential kill clears younger entries before issue resumes.
    logic [D-1:0] lsu_v, lsu_st_v, lsu_elig, lsu_sel;
    // Frequency-first: issue selection must not depend on the combinational
    // flush kill mask.  On a flush cycle the whole issue port is suppressed
    // for one cycle (issue_en), which is enough to keep LSU allocations out of
    // the flush window; older entries simply issue after the flush cycle.
    wire          issue_en = !flush_valid;
    logic [D-1:0] lsu_ready;
    always_comb begin
        for (int i = 0; i < D; i = i + 1) begin
            lsu_v[i] = v_q[i] && (fu_q[i] == cpu_pkg::FU_LSU);
            lsu_st_v[i] = lsu_v[i] && st_ent_q[i];
        end
        for (int i = 0; i < D; i = i + 1) begin
            lsu_elig[i] = lsu_v[i];
            for (int j = 0; j < D; j = j + 1)
                if (lsu_st_v[j] && (age[j] < age[i]))
                    lsu_elig[i] = 1'b0;
            lsu_ready[i] = lsu_elig[i] &&
                (r1_q[i] || ((cpu_pkg::WB_BYPASS != 0) && r1_set[i])) &&
                (st_ent_q[i] || r2_q[i] || ((cpu_pkg::WB_BYPASS != 0) && r2_set[i])) &&
                (st_ent_q[i] ? lsu_free_st : lsu_free_ld);
        end
        for (int i = 0; i < D; i = i + 1) begin
            lsu_sel[i] = lsu_ready[i];
            for (int j = 0; j < D; j = j + 1)
                if (lsu_ready[j] && (age[j] < age[i]))
                    lsu_sel[i] = 1'b0;
        end
    end

    // Two parallel eligibility masks preserve the rotating priority policy.
    // No variable-index serial resource scan is needed to select two slots.
    function automatic logic [SB-1:0] rotated_first(input logic [D-1:0] mask);
        logic [D-1:0] suffix;
        for (int i = 0; i < D; i = i + 1) suffix[i] = mask[i] && (i[SB-1:0] >= rot_q);
        rotated_first = lowest((|suffix) ? suffix : mask);
    endfunction
    function automatic logic [2:0] select_port(input logic [2:0] fu, input logic second_alu);
        case (fu)
            cpu_pkg::FU_ALU: select_port = (alu0_free && !second_alu) ? cpu_pkg::IUP_ALU0 : cpu_pkg::IUP_ALU1;
            cpu_pkg::FU_BR: select_port = cpu_pkg::IUP_BRU;
            cpu_pkg::FU_MUL: select_port = cpu_pkg::IUP_MUL;
            cpu_pkg::FU_DIV: select_port = cpu_pkg::IUP_DIV;
            default: select_port = cpu_pkg::IUP_LSU;
        endcase
    endfunction
    logic [D-1:0] ready0, ready1;
    always_comb begin
        for (int i = 0; i < D; i = i + 1) begin
            ready0[i] = v_q[i] && issue_en &&
                (r1_q[i] || ((cpu_pkg::WB_BYPASS != 0) && r1_set[i])) &&
                (st_ent_q[i] || r2_q[i] || ((cpu_pkg::WB_BYPASS != 0) && r2_set[i]));
            case (fu_q[i])
                cpu_pkg::FU_ALU: ready0[i] = ready0[i] && (alu0_free || alu1_free);
                cpu_pkg::FU_BR: ready0[i] = ready0[i] && bru_free;
                cpu_pkg::FU_MUL: ready0[i] = ready0[i] && mul_free;
                cpu_pkg::FU_DIV: ready0[i] = ready0[i] && div_free;
                cpu_pkg::FU_LSU: ready0[i] = ready0[i] && lsu_sel[i];
                default: ready0[i] = 1'b0;
            endcase
        end
        s0v = |ready0;
        s0 = rotated_first(ready0);
        for (int i = 0; i < D; i = i + 1)
            ready1[i] = ready0[i] && (i[SB-1:0] != s0) &&
                ((fu_q[i] != fu_q[s0]) ||
                 ((fu_q[i] == cpu_pkg::FU_ALU) && alu0_free && alu1_free));
        s1v = (cpu_pkg::ISSUE_WIDTH == 2) && (|ready1);
        s1 = rotated_first(ready1);
        port0 = select_port(fu_q[s0], 1'b0);
        port1 = select_port(fu_q[s1], fu_q[s0] == cpu_pkg::FU_ALU && fu_q[s1] == cpu_pkg::FU_ALU);
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
        iss0.pred_taken  = pt_q[s0];
        iss0.pred_target = ptg_q[s0];
        iss0.bix         = bix_q[s0];
        // Store-data forwarding is independent of ALU wake/execute bypass:
        // a new STQ entry cannot wait for a writeback already passing now.
        iss0.rs2_ready   = r2_q[s0] || r2_set[s0];

        iss1 = '0;
        iss1.insn        = insn_q[s1];
        iss1.ps1         = ps1_q[s1];
        iss1.ps2         = ps2_q[s1];
        iss1.pdst        = pdst_q[s1];
        iss1.rob         = rob_q[s1];
        iss1.pred_taken  = pt_q[s1];
        iss1.pred_target = ptg_q[s1];
        iss1.bix         = bix_q[s1];
        iss1.rs2_ready   = r2_q[s1] || r2_set[s1];
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
                fu_q[pos0]  <= d0.insn.fu;
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
                fu_q[pos1]  <= d1.insn.fu;
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
