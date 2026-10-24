// Reorder buffer: 32-entry in-order commit window.
//   * dispatch: rename hands 1..2 entries per cycle, in program order.
//   * writeback filtering: BA/BB are matched by (rob#, pdst). A writeback that
//     matches a live entry is delivered (wb_*_ok) to PRF/IQ and marks done;
//     anything else is a stale result of a flushed instruction and is emitted
//     as a reclaim pulse (rename releases the tag from its pending table).
//   * flush (flush_valid/flush_rob): entries strictly younger than flush_rob
//     are killed; outputs tell rename which old physical tags to restore and
//     which physical destinations to free now / hold pending.
module rob (
    input  wire        clock,
    input  wire        reset,

    // ---- dispatch (from rename, program order) ----
    input  wire [1:0]  disp_valid,
    input  wire [4:0]  disp_rd0,
    input  wire [4:0]  disp_rd1,
    input  wire [$clog2(cpu_pkg::PRF_NUM)-1:0] disp_pdst0,
    input  wire [$clog2(cpu_pkg::PRF_NUM)-1:0] disp_pdst1,
    input  wire [$clog2(cpu_pkg::PRF_NUM)-1:0] disp_old0,
    input  wire [$clog2(cpu_pkg::PRF_NUM)-1:0] disp_old1,
    input  wire        disp_load0,
    input  wire        disp_load1,
    input  wire        disp_store0,
    input  wire        disp_store1,
    output wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] alloc_ptr,     // rob# for the next dispatched slot
    output wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] head_ptr,      // commit head (age reference for IQ)
    output wire [$clog2(cpu_pkg::ROB_DEPTH):0]   alloc_space,

    // ---- store retirement pulses (commit -> LSU drain gate) ----
    output logic        cst0_valid,
    output logic [$clog2(cpu_pkg::ROB_DEPTH)-1:0] cst0_rob,
    output logic        cst1_valid,
    output logic [$clog2(cpu_pkg::ROB_DEPTH)-1:0] cst1_rob,

    // ---- writeback (raw BA/BB) + filtered outputs ----
    input  cpu_pkg::writeback_t wb_a,
    input  cpu_pkg::writeback_t wb_b,
    output cpu_pkg::writeback_t wb_a_ok,
    output cpu_pkg::writeback_t wb_b_ok,
    // Early scheduling checks. Architectural writeback/reclaim retain the
    // complete kill filter; sched_b_candidate excludes the live LSU source.
    input  cpu_pkg::writeback_t sched_b_candidate,
    output wire        sched_a_match,
    output wire        sched_b_match,
    output wire        rec_a_valid,
    output wire [$clog2(cpu_pkg::PRF_NUM)-1:0] rec_a_tag,
    output wire        rec_b_valid,
    output wire [$clog2(cpu_pkg::PRF_NUM)-1:0] rec_b_tag,

    // ---- issue marking (for flush reclaim correctness) ----
    input  wire        mk0_valid,
    input  wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] mk0_rob,
    input  wire        mk1_valid,
    input  wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] mk1_rob,

    // ---- narrow completion: store drained / load rd=x0 ----
    input  wire        ndone_valid,
    input  wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] ndone_rob,

    // ---- commit ----
    output wire [cpu_pkg::PRF_NUM-1:0] cmt_free_mask,   // old_pdst of committing rd!=x0 entries

    // ---- flush ----
    input  wire        flush_valid,
    input  wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] flush_rob,
    output wire [$clog2(cpu_pkg::ROB_DEPTH):0]  flush_dtail,     // #entries after flush_rob (kill range)
    output logic [cpu_pkg::PRF_NUM-1:0] flush_free_mask, // killed+done pdst: free immediately
    output logic [cpu_pkg::PRF_NUM-1:0] flush_pend_mask, // killed+!done pdst: hold pending
    output logic [31:0] restore_valid,    // per arch reg: restore old mapping
    output logic [32*$clog2(cpu_pkg::PRF_NUM)-1:0] restore_pdst   // 32×tag bits
);
    logic [cpu_pkg::ROB_DEPTH-1:0] v_q, d_q;    // valid / done, one bit per entry
    logic [cpu_pkg::ROB_DEPTH-1:0] iss_q, ld_q; // issued / is-load, one bit per entry
    logic [cpu_pkg::ROB_DEPTH-1:0] st_q;        // is-store, one bit per entry
    localparam int PB = $clog2(cpu_pkg::PRF_NUM);
    localparam int RB = $clog2(cpu_pkg::ROB_DEPTH);
    localparam logic [cpu_pkg::PRF_NUM-1:0] ONE = 1;
    localparam logic [RB:0] DEPTH   = cpu_pkg::ROB_DEPTH;
    localparam logic [RB:0] DT_FULL = cpu_pkg::ROB_DEPTH;
    logic [4:0]  rd_q   [0:cpu_pkg::ROB_DEPTH-1];
    logic [PB-1:0] pdst_q [0:cpu_pkg::ROB_DEPTH-1];
    logic [PB-1:0] old_q  [0:cpu_pkg::ROB_DEPTH-1];
    logic [RB-1:0] head_q, tail_q;
    logic [RB:0]   cnt_q;                  // in-flight count, 0..ROB_DEPTH
    assign alloc_ptr    = tail_q;
    assign head_ptr     = head_q;
    assign alloc_space  = DEPTH - cnt_q;

    // ---------------- flush kill set ----------------
    // dtail is the ring distance from frob to the allocation pointer. When the
    // mispredicting branch is the head of a FULL ROB (tail == frob == head),
    // the ring distance is 0 but the kill set is the other 31 live entries;
    // encode that as 32 (the 6-bit domain) so flush_younger stays total.
    wire [RB:0] dtail = (tail_q == flush_rob) ? (v_q[flush_rob] ? DT_FULL : '0)
                                              : {1'b0, (tail_q - flush_rob)};
    assign flush_dtail = dtail;
    logic [cpu_pkg::ROB_DEPTH-1:0] kill_comb;
    always_comb begin
        kill_comb = '0;
        for (int i = 0; i < cpu_pkg::ROB_DEPTH; i = i + 1)
            kill_comb[i] = cpu_pkg::flush_younger(i[RB-1:0], flush_rob, dtail);
    end
    wire [cpu_pkg::ROB_DEPTH-1:0] kkill = flush_valid ? kill_comb : '0;

    // ---------------- writeback filter ----------------
    // A writeback may only complete the entry it belongs to: the entry must
    // be live, not being flushed, carry the matching physical tag, and have
    // been issued. The issued check rejects stale tag-0 writebacks (rd=x0
    // results carry pdst=0 just like stores / x0-destination ops, so a stale
    // result from a killed instruction could otherwise match a re-used slot).
    // Registered producers can be checked before the late LSU bus selection.
    // Scheduling ignores same-cycle kills; issue is disabled during recovery.
    assign sched_a_match = v_q[wb_a.rob] && iss_q[wb_a.rob] &&
                           (pdst_q[wb_a.rob] == wb_a.prf_tag);
    assign sched_b_match = v_q[sched_b_candidate.rob] && iss_q[sched_b_candidate.rob] &&
                           (pdst_q[sched_b_candidate.rob] == sched_b_candidate.prf_tag);
    wire a_ok = v_q[wb_a.rob] && !kkill[wb_a.rob] &&
                (pdst_q[wb_a.rob] == wb_a.prf_tag) && iss_q[wb_a.rob];
    wire b_ok = v_q[wb_b.rob] && !kkill[wb_b.rob] &&
                (pdst_q[wb_b.rob] == wb_b.prf_tag) && iss_q[wb_b.rob];

    always_comb begin
        wb_a_ok    = wb_a;
        wb_a_ok.valid = wb_a.valid && a_ok;
        wb_b_ok    = wb_b;
        wb_b_ok.valid = wb_b.valid && b_ok;
    end
    assign rec_a_valid = wb_a.valid && !a_ok && (wb_a.prf_tag != '0);
    assign rec_a_tag   = wb_a.prf_tag;
    assign rec_b_valid = wb_b.valid && !b_ok && (wb_b.prf_tag != '0);
    assign rec_b_tag   = wb_b.prf_tag;

    // ---------------- commit (in order, <=2/cycle) ----------------
    wire c0 = v_q[head_q] && d_q[head_q] && !flush_valid;
    wire [RB-1:0] h1 = head_q + 1'b1;
    wire c1 = (cpu_pkg::DECODE_WIDTH == 2) && c0 && v_q[h1] && d_q[h1];

    assign cmt_free_mask =
        (c0 && (rd_q[head_q] != 5'd0) ? (ONE << old_q[head_q]) : '0) |
        (c1 && (rd_q[h1]    != 5'd0) ? (ONE << old_q[h1])    : '0);

    // store retirement pulses for the LSU drain gate
    always_comb begin
        cst0_valid = c0 && st_q[head_q];
        cst0_rob   = head_q;
        cst1_valid = c1 && st_q[h1];
        cst1_rob   = h1;
    end

    // ---------------- flush recovery outputs ----------------
    always_comb begin
        flush_free_mask = '0;
        flush_pend_mask = '0;
        // Decode tags to constant bit positions. This avoids a bank of
        // variable shifts that makes resource-sharing SAT grow quadratically.
        for (int p = 1; p < cpu_pkg::PRF_NUM; p = p + 1) begin
            for (int i = 0; i < cpu_pkg::ROB_DEPTH; i = i + 1) begin
                if (kkill[i] && (rd_q[i] != 0) && (pdst_q[i] == p[PB-1:0])) begin
                    if (d_q[i] || !iss_q[i] || ld_q[i]) flush_free_mask[p] = 1'b1;
                    else flush_pend_mask[p] = 1'b1;
                end
            end
        end
    end

    // Restore the old mapping of the OLDEST killed writer to each register.
    // Scan physical slots in parallel, preferring slots above flush_rob before
    // wrapping to zero. A balanced left-first tree replaces the serial scan
    // of variable-indexed ROB reads and variable writes to the restore bus.
    // That scan created a ROB-tail -> rename-map path longer than 6 ns.
    wire [cpu_pkg::ROB_DEPTH-1:0] after_flush;
    assign restore_valid[0] = 1'b0;
    assign restore_pdst[0 +: PB] = '0;
    generate
        for (genvar i = 0; i < cpu_pkg::ROB_DEPTH; i = i+1) begin : g_after_flush
            assign after_flush[i] = RB'(i) > flush_rob;
        end
        for (genvar r = 1; r < 32; r = r+1) begin : g_restore
            wire [cpu_pkg::ROB_DEPTH-1:0] candidate, eligible;
            wire has_above = |(candidate & after_flush);
            wire [2*cpu_pkg::ROB_DEPTH-1:1] node_valid;
            wire [PB-1:0] node_data [1:2*cpu_pkg::ROB_DEPTH-1];
            assign eligible = candidate & (has_above ? after_flush : {cpu_pkg::ROB_DEPTH{1'b1}});
            for (genvar i = 0; i < cpu_pkg::ROB_DEPTH; i = i+1) begin : g_leaf
                assign candidate[i] = kkill[i] && v_q[i] && (rd_q[i] == 5'(r));
                assign node_valid[cpu_pkg::ROB_DEPTH+i] = eligible[i];
                assign node_data[cpu_pkg::ROB_DEPTH+i] = old_q[i];
            end
            for (genvar n = 1; n < cpu_pkg::ROB_DEPTH; n = n+1) begin : g_node
                assign node_valid[n] = node_valid[2*n] || node_valid[2*n+1];
                assign node_data[n] = node_valid[2*n] ? node_data[2*n] : node_data[2*n+1];
            end
            assign restore_valid[r] = node_valid[1];
            assign restore_pdst[r*PB +: PB] = node_valid[1] ? node_data[1] : '0;
        end
    endgenerate

    // ---------------- state ----------------
    wire [1:0] ndisp  = {1'b0, disp_valid[0]} + {1'b0, disp_valid[1]};
    wire [1:0] ncmt   = {1'b0, c0} + {1'b0, c1};
    wire [RB:0] killed = (dtail == '0) ? '0 : (dtail - 1'b1);

    always_ff @(posedge clock) begin
        if (reset) begin
            v_q <= '0; d_q <= '0; iss_q <= '0; ld_q <= '0; st_q <= '0;
            head_q <= '0; tail_q <= '0; cnt_q <= '0;
        end else begin
            // writeback completion must apply even on a flush cycle: an entry
            // may receive its (pdst-matching) writeback in the very cycle it is
            // flushed; a killed entry has a_ok=0 so no spurious mark happens.
            if (wb_a.valid && a_ok) d_q[wb_a.rob] <= 1'b1;
            if (wb_b.valid && b_ok) d_q[wb_b.rob] <= 1'b1;
            if (ndone_valid && v_q[ndone_rob]) d_q[ndone_rob] <= 1'b1;
            if (mk0_valid && v_q[mk0_rob]) iss_q[mk0_rob] <= 1'b1;
            if (mk1_valid && v_q[mk1_rob]) iss_q[mk1_rob] <= 1'b1;

            if (flush_valid) begin
                for (int i = 0; i < cpu_pkg::ROB_DEPTH; i = i + 1) begin
                    if (kkill[i]) begin v_q[i] <= 1'b0; d_q[i] <= 1'b0; st_q[i] <= 1'b0; end
                end
                if (dtail != '0) tail_q <= flush_rob + 1'b1;
                cnt_q  <= cnt_q - killed;
            end else begin
                if (disp_valid[0]) begin
                    v_q[tail_q]     <= 1'b1; d_q[tail_q]     <= 1'b0;
                    rd_q[tail_q]    <= disp_rd0;
                    pdst_q[tail_q]  <= disp_pdst0;
                    old_q[tail_q]   <= disp_old0;
                    iss_q[tail_q]   <= 1'b0;
                    ld_q[tail_q]    <= disp_load0;
                    st_q[tail_q]    <= disp_store0;
                end
                if (disp_valid[1]) begin
                    v_q[tail_q + 1'b1]    <= 1'b1; d_q[tail_q + 1'b1]    <= 1'b0;
                    rd_q[tail_q + 1'b1]   <= disp_rd1;
                    pdst_q[tail_q + 1'b1] <= disp_pdst1;
                    old_q[tail_q + 1'b1]  <= disp_old1;
                    iss_q[tail_q + 1'b1]  <= 1'b0;
                    ld_q[tail_q + 1'b1]   <= disp_load1;
                    st_q[tail_q + 1'b1]   <= disp_store1;
                end
                if (c0) begin v_q[head_q] <= 1'b0; d_q[head_q] <= 1'b0; end
                if (c1) begin v_q[h1]     <= 1'b0; d_q[h1]     <= 1'b0; end
                head_q <= head_q + {{(RB-2){1'b0}}, ncmt};
                tail_q <= tail_q + {{(RB-2){1'b0}}, ndisp};
                cnt_q  <= cnt_q + {{(RB-1){1'b0}}, ndisp} - {{(RB-1){1'b0}}, ncmt};
            end
        end
    end


endmodule
