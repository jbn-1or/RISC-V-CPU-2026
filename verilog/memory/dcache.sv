// Data cache (design.md §7.3): direct-mapped, DC_LINES x LINE_BYTES lines,
// write-through and no-write-allocate, byte-write masks, MSHR_N outstanding
// line fills with keyword-first completion, and a kill bit that drops a
// flushed waiter's response. One 1RW SRAM port per line word (LINE_BYTES/4
// banks) is time-shared between lookups, store hit-updates and refill writes
// in this priority order: refill write (must never be lost) > load lookup >
// store hit-update.
//
// Response merge: lookup results and MSHR keyword completions can occur in the
// same cycle (max 1 each), so both are pushed into an 8-deep response FIFO that
// lsu_a drains unconditionally. Tokens (rob numbers) identify the waiter.
//
// Same-set rule: two MSHRs may never target the same set (their refill writes
// would shred each other's banks); a miss with a busy set responds "replay" and
// the requester retries later. On MSHR allocation the set's valid bit is
// cleared immediately so no lookup can hit half-refilled banks.
module dcache (
    input  wire        clock,
    input  wire        reset,

    // load lookup (from lsu_a); token pairs the response back to the load
    input  wire        lk_valid,
    input  wire [31:0] lk_addr,
    input  wire [RB-1:0] lk_token,
    output wire        lk_ready,

    // load response: data ready (hit or keyword) or a retry request
    output wire        rsp_valid,
    output wire [RB-1:0] rsp_token,
    output wire [31:0] rsp_data,
    output wire        rsp_replay,
    input  wire        rsp_ready,

    // store hit-update, single cycle; a miss is a no-op (no allocate)
    input  wire        su_valid,
    input  wire [31:0] su_addr,
    input  wire [31:0] su_data,
    input  wire [3:0]  su_strb,
    output wire        su_ready,
    output wire        su_hit,

    // store-completion line invalidate (stale-fill cleanup, see lsu_a)
    input  wire        inv_valid,
    input  wire [31:0] inv_addr,

    // flush: mark MSHR waiters younger than the flush point as dead
    input  wire        flush_valid,
    input  wire [RB-1:0] flush_rob,
    input  wire [RB:0] flush_dtail,

    // AXI read push/response (src = MRF_DC set by top; idx = {slot, word})
    output wire        rd_push_valid,
    output wire [31:0] rd_push_addr,
    output wire [4:0]  rd_push_idx,
    input  wire        rd_push_ready,
    input  wire        rd_rsp_valid,
    input  wire [4:0]  rd_rsp_idx,
    input  wire [31:0] rd_rsp_data,
    output wire        rd_rsp_ready,
);
    localparam int SETB = $clog2(cpu_pkg::DC_LINES);    // 8
    localparam int OFFB = $clog2(cpu_pkg::LINE_BYTES);  // 4/5
    localparam int NW   = cpu_pkg::LINE_BYTES / 4;      // words per line 4/8
    localparam int WB   = $clog2(NW);                   // word index bits 2/3
    localparam int TAGB = 32 - SETB - OFFB;             // 20/19
    localparam int PWB  = $clog2(NW + 1);               // push-counter bits 3/4
    localparam int MN   = cpu_pkg::MSHR_N;
    localparam int RB   = $clog2(cpu_pkg::ROB_DEPTH);
    localparam logic [1:0] MN_LAST = (MN == 4) ? 2'd3 : (MN == 2) ? 2'd1 : 2'd0;
    localparam logic [PWB-1:0] CAP_ONE  = 1;
    localparam logic [PWB-1:0] CAP_FULL = NW[PWB-1:0];
    localparam logic [NW-1:0]  ONE_HOT  = 1;
    localparam logic [NW-1:0]  ALL_DONE = {NW{1'b1}};
`ifndef SYNTHESIS
    // MSHR_N is a real knob (1/2/4); LINE_BYTES is parameterized over 16/32
    // (4 or 8 words per line, word field {slot[1:0], word[2:0]} on the AXI tag).
    // MN_LAST has no encoding for 3, so reject it loudly instead of silently
    // dropping slot 1/2 completions (set would never complete).
    initial if ((MN != 1) && (MN != 2) && (MN != 4))
        $fatal(1, "dcache: MSHR_N must be 1, 2 or 4 for this implementation");
    initial if ((cpu_pkg::LINE_BYTES != 16) && (cpu_pkg::LINE_BYTES != 32))
        $fatal(1, "dcache: LINE_BYTES must be 16 or 32 for this implementation");
`endif

    // ---------------- tag / valid arrays ----------------
    logic [cpu_pkg::DC_LINES-1:0] v_q;
    logic [TAGB-1:0] tag_q [0:cpu_pkg::DC_LINES-1];

    // ---------------- lookup pipeline (1-cycle SRAM read) ----------------
    logic            pend_q;
    logic [RB-1:0]   pend_tok_q;
    logic [TAGB-1:0] pend_tag_q;
    logic [SETB-1:0] pend_set_q;
    logic [2:0]      pend_word_q;
    logic            pend_unc_q;

    // ---------------- MSHR (MSHR_N entries) ----------------
    logic            m_valid  [0:MN-1];
    logic            m_bypass [0:MN-1];
    logic [TAGB-1:0] m_tag    [0:MN-1];
    logic [SETB-1:0] m_set    [0:MN-1];
    logic [2:0]      m_trig   [0:MN-1];
    logic [NW-1:0]   m_done   [0:MN-1];
    logic            m_killed [0:MN-1];
    logic [RB-1:0]   m_token  [0:MN-1];
    logic [PWB-1:0]  m_pushcnt[0:MN-1];

    // ---------------- response FIFO (8 deep, up to 2 enqueues/cycle) --------
    logic [RB-1:0] f_tok [0:7];
    logic [31:0] f_dat [0:7];
    logic        f_rep [0:7];
    logic [2:0]  f_head, f_tail;
    logic [3:0]  f_lvl;
    assign rsp_valid  = (f_lvl != 4'd0);
    assign rsp_token  = f_tok[f_head];
    assign rsp_data   = f_dat[f_head];
    assign rsp_replay = f_rep[f_head];
    wire   rsp_deq    = (f_lvl != 4'd0) && rsp_ready;

    // ---------------- port owner arbitration ----------------
    wire [1:0]  rslot = rd_rsp_idx[4:3];
    wire [2:0]  rword = rd_rsp_idx[2:0];
    wire        wref  = rd_rsp_valid && (rslot <= MN_LAST) && m_valid[rslot];  // valid refill write
    // A request killed by the flush must not enter the miss path at all: its
    // latched lookup would allocate an MSHR one cycle later, when flush_valid
    // has already dropped (pend_kill below would miss it) and its stale
    // completion could later alias a reused rob number.
    wire lk_kill = flush_valid && cpu_pkg::flush_younger(lk_token, flush_rob, flush_dtail);
    wire lk_acc = !wref && !lk_kill && lk_valid && (f_lvl <= 4'd4);
    wire su_acc = !wref && !lk_acc && su_valid;
    assign lk_ready = lk_acc;
    assign su_ready = su_acc;
    assign rd_rsp_ready = 1'b1;

    // ---------------- refill pushes (one per cycle, lowest slot first) ------
    logic [1:0] push_slot;
    logic       push_en;
    always_comb begin
        push_slot = 2'd0;
        push_en   = 1'b0;
        for (int s = MN-1; s >= 0; s = s - 1)
            if (m_valid[s] && (m_pushcnt[s] < (m_bypass[s] ? CAP_ONE : CAP_FULL))) begin
                push_slot = s[1:0];
                push_en   = 1'b1;
            end
    end
    wire [2:0] push_word = m_bypass[push_slot] ? m_trig[push_slot] : m_pushcnt[push_slot][2:0];
    wire [31:0] push_addr_s = {m_tag[push_slot], m_set[push_slot], push_word[WB-1:0], 2'b00};
    assign rd_push_valid = push_en;
    assign rd_push_addr  = push_addr_s;
    assign rd_push_idx   = {push_slot, push_word};    // {slot[1:0], word[2:0]}

    // ---------------- SRAM bank controls (one bank per line word) ----------
    wire [2:0]  acc_word = lk_acc ? lk_addr[OFFB-1:2] : su_acc ? su_addr[OFFB-1:2] : rword;
    wire [SETB-1:0] acc_set = lk_acc ? lk_addr[SETB+OFFB-1:OFFB] :
                              su_acc ? su_addr[SETB+OFFB-1:OFFB] : m_set[rslot];
    wire        acc_we   = su_acc || (wref && !m_bypass[rslot]);
    wire [31:0] acc_wdata = su_acc ? su_data : rd_rsp_data;
    wire [3:0]  acc_wmask = su_acc ? su_strb : 4'hf;

    // store update only writes on a hit
    wire su_hit_c = v_q[su_addr[SETB+OFFB-1:OFFB]] &&
                    (tag_q[su_addr[SETB+OFFB-1:OFFB]] == su_addr[31:SETB+OFFB]);
    assign su_hit = su_hit_c;

    // only the bank owning the accessed word is enabled
    wire acc_en = lk_acc || (su_acc && su_hit_c) || (wref && !m_bypass[rslot]);
    logic [NW-1:0] bank_en;
    always_comb begin
        bank_en = '0;
        for (int w = 0; w < NW; w = w + 1)
            bank_en[w] = acc_en && (acc_word == w[2:0]);
    end

    wire [31:0] bank_rdata [0:NW-1];
    generate
        for (genvar g = 0; g < NW; g = g + 1) begin : g_dbank
            sram_fakeram #(.DEPTH(cpu_pkg::DC_LINES), .WIDTH(32), .WRITE_GRANULARITY(8)) u_bank (
                .clk(clock), .en(bank_en[g]), .we(acc_we), .wmask(acc_wmask),
                .addr(acc_set), .wdata(acc_wdata), .rdata(bank_rdata[g]));
        end
    endgenerate

    logic [31:0] bank_data;
    always_comb begin
        bank_data = '0;
        for (int w = 0; w < NW; w = w + 1)
            if (pend_word_q[WB-1:0] == w[WB-1:0]) bank_data = bank_rdata[w];
    end

    // ---------------- lookup result ----------------
    wire pend_hit  = pend_q && v_q[pend_set_q] && (tag_q[pend_set_q] == pend_tag_q);
    wire pend_miss = pend_q && !pend_hit;
    wire pend_unc  = pend_unc_q;                      // addr[31:28] != 0 -> uncached

    // MSHR allocation on a miss: never two fills for the same set.
    // A request that is younger than the flush point must not allocate in the
    // same cycle the flush arrives (the kill scan below only sees already-set
    // m_valid), otherwise its stale completion could later alias a reused rob number.
    wire pend_kill = flush_valid && cpu_pkg::flush_younger(pend_tok_q, flush_rob, flush_dtail);
    logic [1:0] alloc_slot;
    logic       alloc_free;
    logic       set_busy;
    always_comb begin
        alloc_slot = 2'd0;
        alloc_free = 1'b0;
        set_busy   = 1'b0;
        for (int s = MN-1; s >= 0; s = s - 1) begin
            if (!m_valid[s]) begin alloc_slot = s[1:0]; alloc_free = 1'b1; end
            if (m_valid[s] && !m_bypass[s] && (m_set[s] == pend_set_q)) set_busy = 1'b1;
        end
    end
    wire alloc_en = pend_miss && !pend_kill && alloc_free && (pend_unc || !set_busy);

    // keyword completion (trigger word arrived, waiter still alive)
    wire kw_ev = wref && m_valid[rslot] && (rword == m_trig[rslot]) && !m_killed[rslot];

    // response FIFO events: A = keyword, B = lookup (hit / replay)
    wire ev_a = kw_ev;
    wire [RB-1:0] eva_tok = m_token[rslot];
    wire [31:0] eva_dat = rd_rsp_data;
    wire ev_b = pend_hit || (pend_miss && !alloc_en);
    wire [RB-1:0] evb_tok = pend_tok_q;
    wire [31:0] evb_dat = pend_hit ? bank_data : 32'b0;
    wire evb_rep = !pend_hit;

    // ---------------- state ----------------
    always_ff @(posedge clock) begin
        if (reset) begin
            v_q <= '0;
            pend_q <= 1'b0;
            pend_unc_q <= 1'b0;
            for (int s = 0; s < MN; s = s + 1) begin
                m_valid[s]   <= 1'b0;
                m_killed[s]  <= 1'b0;
                m_pushcnt[s] <= '0;
                m_done[s]    <= '0;
            end
            f_head <= '0; f_tail <= '0; f_lvl <= '0;
        end else begin
            // ---- lookup pipeline ----
            pend_q <= lk_acc;
            if (lk_acc) begin
                pend_tok_q  <= lk_token;
                pend_tag_q  <= lk_addr[31:SETB+OFFB];
                pend_set_q  <= lk_addr[SETB+OFFB-1:OFFB];
                pend_word_q <= lk_addr[OFFB-1:2];
                pend_unc_q  <= cpu_pkg::is_uncached(lk_addr);
            end

            // ---- MSHR kill (flush younger than the flush point) ----
            for (int s = 0; s < MN; s = s + 1) begin
                if (flush_valid && m_valid[s] &&
                    cpu_pkg::flush_younger(m_token[s], flush_rob, flush_dtail))
                    m_killed[s] <= 1'b1;
            end

            // ---- refill write processing ----
            if (wref) begin
                if (m_bypass[rslot]) begin
                    m_valid[rslot] <= 1'b0;
                end else begin
                    logic [NW-1:0] dne;
                    dne = m_done[rslot] | (ONE_HOT << rword);
                    m_done[rslot] <= dne;
                    if (dne == ALL_DONE) begin
                        v_q[m_set[rslot]]   <= 1'b1;
                        tag_q[m_set[rslot]] <= m_tag[rslot];
                        m_valid[rslot]      <= 1'b0;
                    end
                end
            end

            // ---- store-completion invalidate (line may hold a stale fill) ----
            if (inv_valid && v_q[inv_addr[SETB+OFFB-1:OFFB]] &&
                (tag_q[inv_addr[SETB+OFFB-1:OFFB]] == inv_addr[31:SETB+OFFB]))
                v_q[inv_addr[SETB+OFFB-1:OFFB]] <= 1'b0;

            // ---- MSHR allocation (invalidates the set before any fill) ----
            if (alloc_en) begin
                m_valid[alloc_slot]  <= 1'b1;
                m_bypass[alloc_slot] <= pend_unc;
                m_tag[alloc_slot]    <= pend_tag_q;
                m_set[alloc_slot]    <= pend_set_q;
                m_trig[alloc_slot]   <= pend_word_q;
                m_done[alloc_slot]   <= '0;
                m_killed[alloc_slot] <= 1'b0;
                m_token[alloc_slot]  <= pend_tok_q;
                m_pushcnt[alloc_slot] <= '0;
                if (!pend_unc) v_q[pend_set_q] <= 1'b0;
            end

            // ---- refill push counters ----
            if (rd_push_valid && rd_push_ready)
                m_pushcnt[push_slot] <= m_pushcnt[push_slot] + 1'b1;

            // ---- response FIFO ----
            if (ev_a) begin
                f_tok[f_tail] <= eva_tok;
                f_dat[f_tail] <= eva_dat;
                f_rep[f_tail] <= 1'b0;
            end
            if (ev_b) begin
                logic [2:0] wa;
                wa = f_tail + {2'b0, ev_a};
                f_tok[wa] <= evb_tok;
                f_dat[wa] <= evb_dat;
                f_rep[wa] <= evb_rep;
            end
            if (ev_a || ev_b) f_tail <= f_tail + {2'b0, ev_a} + {2'b0, ev_b};
            if (rsp_deq) f_head <= f_head + 3'd1;
            f_lvl <= f_lvl + {3'b0, ev_a} + {3'b0, ev_b} - {3'b0, rsp_deq};
        end
    end

endmodule
