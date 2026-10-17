// Data cache (design.md §7.3): direct-mapped, DC_LINES x LINE_BYTES lines,
// write-through and no-write-allocate, byte-write masks, MSHR_N outstanding
// line fills with keyword-first completion, and a kill bit that drops a
// flushed waiter's response. One 1RW SRAM port per line word (LINE_BYTES/4
// banks) is time-shared between lookups, store hit-updates and refill writes
// in this priority order: refill write (must never be lost) > load lookup >
// store hit-update.
//
// Response merge: lookup results, MSHR keyword completions and parked word
// waiters can occur in the same cycle (at most one of each kind, 3 total), so
// all are pushed into an FD-deep response FIFO that lsu_a drains when its
// output lane is free. Tokens (rob numbers) identify the waiter.
//
// Same-set rule: two MSHRs may never target the same set (their refill writes
// would shred each other's banks); a miss with a busy set responds "replay" and
// the requester retries later. On MSHR allocation the set's valid bit is
// cleared immediately so no lookup can hit half-refilled banks.
//
// Same-line merge (P0-mwaiter): a lookup that misses because its line is being
// filled (non-bypass MSHR with the same set+tag) no longer replays for the
// whole fill window:
//   * word already backfilled -> partial hit, served from the bank (pend_phit;
//     the bank read is clean because a lookup is never accepted in a cycle with
//     a refill write);
//   * word still in flight -> park one waiter token in that word's MSHR slot
//     (m_wv/m_wt) and answer it when the word lands (keyword style). Only when
//     the word's single waiter slot is already taken does the lookup replay.
// A parked waiter is killed by flush (m_wkill) exactly like the trigger
// waiter: its response is dropped, so a reused rob number can never be
// answered with stale data. Every non-killed parked waiter is guaranteed to
// complete at its word arrival, i.e. before the MSHR slot frees.
module dcache (
    input  wire        clock,
    input  wire        reset,

    // load lookup (from lsu_a); token pairs the response back to the load
    input  wire        lk_valid,
    input  wire [31:0] lk_addr,
    input  wire [RB-1:0] lk_token,
    output wire        lk_ready,

    // M9c: combinational tag probe used by lsu_b to relax the same-line guard
    // for loads that would HIT (a hit never allocates, so the stale-fill race
    // cannot occur). Purely a read of the tag/valid flop arrays.
    input  wire [31:0] probe_addr,
    output wire        probe_hit,

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
    localparam int FD   = 16;                           // response FIFO depth
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

    // M9c: combinationally probe whether probe_addr currently hits.
    assign probe_hit = v_q[probe_addr[SETB+OFFB-1:OFFB]] &&
                       (tag_q[probe_addr[SETB+OFFB-1:OFFB]] == probe_addr[31:SETB+OFFB]);

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
    // P0-mwaiter: one parked waiter slot per line word (m_wv valid, m_wt token,
    // m_wkill = flushed -> never respond). A slot holds at most one token, so a
    // word arrival adds at most one parked response per cycle.
    logic [NW-1:0]   m_wv     [0:MN-1];
    logic [RB-1:0]   m_wt     [0:MN-1][0:NW-1];
    logic [NW-1:0]   m_wkill  [0:MN-1];

    // Committed MSHR events (events that will definitely be enqueued later):
    // each live MSHR has one trigger waiter and each occupied word slot one
    // parked waiter. Conservative for a trigger that already fired (it stays
    // counted until its slot frees), which only tightens the gate below.
    logic [5:0] wcnt;
    always_comb begin
        wcnt = 6'd0;
        for (int s = 0; s < MN; s = s + 1) begin
            if (m_valid[s] && !m_killed[s]) wcnt = wcnt + 6'd1;
            for (int w = 0; w < NW; w = w + 1)
                if (m_wv[s][w] && !m_wkill[s][w]) wcnt = wcnt + 6'd1;
        end
    end

    // ---------------- response FIFO (FD deep, up to 3 enqueues/cycle) ------
    logic [RB-1:0] f_tok [0:FD-1];
    logic [31:0] f_dat [0:FD-1];
    logic        f_rep [0:FD-1];
    logic [3:0]  f_head, f_tail;
    logic [4:0]  f_lvl;
    assign rsp_valid  = (f_lvl != 5'd0);
    assign rsp_token  = f_tok[f_head];
    assign rsp_data   = f_dat[f_head];
    assign rsp_replay = f_rep[f_head];
    wire   rsp_deq    = (f_lvl != 5'd0) && rsp_ready;

    // ---------------- port owner arbitration ----------------
    wire [1:0]  rslot = rd_rsp_idx[4:3];
    wire [2:0]  rword = rd_rsp_idx[2:0];
    wire [WB-1:0] rwidx = rword[WB-1:0];
    wire        wref  = rd_rsp_valid && (rslot <= MN_LAST) && m_valid[rslot];  // valid refill write
    // A request killed by the flush must not enter the miss path at all: its
    // latched lookup would allocate an MSHR one cycle later, when flush_valid
    // has already dropped (pend_kill below would miss it) and its stale
    // completion could later alias a reused rob number.
    wire lk_kill = flush_valid && cpu_pkg::flush_younger(lk_token, flush_rob, flush_dtail);
    // FIFO admission: the accepted lookup will commit one more event (next
    // cycle, at the latest). Invariant (induction over the pend stage): every
    // accepted lookup either emits its event one cycle later or joins wcnt, and
    // every wcnt event fires without adding to it, so
    //   f_lvl + wcnt + pend_q <= FD   is preserved across cycles;
    // reserving one more entry for the new lookup keeps the FIFO from ever
    // needing more than FD slots.
    wire [6:0] fifo_used = {2'b0, f_lvl} + {1'b0, wcnt} + {6'b0, pend_q} + 7'd1;
    wire lk_acc = !wref && !lk_kill && lk_valid && (fifo_used <= 7'(FD));
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
    // P0 partial (same-line merge) hit: the line is being filled by an MSHR and
    // this lookup's specific word has already been written back, so the bank data
    // is valid even though v_q is still cleared (cleared at MSHR alloc). Without
    // this every same-line lookup replays for the whole fill window (streaming
    // loads: 1 miss + up to 7 replays per 8-word line). The bank read is clean
    // because a lookup is never accepted in a cycle with a refill write
    // (lk_acc requires !wref), so m_done and the bank contents agree.
    logic pend_phit_c;
    always_comb begin
        pend_phit_c = 1'b0;
        for (int s = 0; s < MN; s = s + 1)
            if (m_valid[s] && (m_set[s] == pend_set_q) && (m_tag[s] == pend_tag_q) &&
                m_done[s][pend_word_q[WB-1:0]])
                pend_phit_c = 1'b1;
    end
    wire pend_phit = pend_q && pend_phit_c;
    wire pend_pok  = pend_hit || pend_phit;       // lookup data available
    wire pend_miss = pend_q && !pend_pok;
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

    // ---------------- P0-mwaiter: same-line word waiters ----------------
    // A miss whose line is being filled by a non-bypass MSHR with the same
    // set+tag (and whose word has not landed; landed words are pend_phit) parks
    // a token in that word's waiter slot instead of replaying. The token is
    // answered at the word arrival, together with the trigger waiter.
    logic [1:0] mg_slot;
    logic       mg_en, mg_done;
    always_comb begin
        mg_slot = 2'd0;
        mg_en   = 1'b0;
        mg_done = 1'b0;
        for (int s = 0; s < MN; s = s + 1)
            if (m_valid[s] && !m_bypass[s] && (m_set[s] == pend_set_q) &&
                (m_tag[s] == pend_tag_q)) begin
                mg_slot = s[1:0];
                mg_en   = 1'b1;
                mg_done = m_done[s][pend_word_q[WB-1:0]];
            end
    end
    wire [WB-1:0] pend_widx = pend_word_q[WB-1:0];
    wire mg_cand = pend_miss && !pend_unc && mg_en && !mg_done && !pend_kill;
    // the word lands in this very cycle: answer now, a parked token would miss
    // the arrival event (registration is visible one cycle later).
    wire mg_now  = mg_cand && wref && (rslot == mg_slot) && (rwidx == pend_widx);
    // park only when this word's single waiter slot is free
    wire mg_reg  = mg_cand && !mg_now && !m_wv[mg_slot][pend_widx];

    // keyword completion (trigger word arrived, waiter still alive)
    wire kw_ev = wref && m_valid[rslot] && (rword == m_trig[rslot]) && !m_killed[rslot];
    // parked waiter served at its word arrival (m_wv is cleared the same cycle)
    wire park_ev = wref && m_valid[rslot] && m_wv[rslot][rwidx] && !m_wkill[rslot][rwidx];

    // response FIFO events: E0 = trigger word, E1 = parked word waiter,
    // E2 = pending lookup (hit / partial hit / merged word data / replay).
    wire ev0 = kw_ev;
    wire [RB-1:0] ev0_tok = m_token[rslot];
    wire [31:0]   ev0_dat = rd_rsp_data;
    wire ev1 = park_ev;
    wire [RB-1:0] ev1_tok = m_wt[rslot][rwidx];
    wire [31:0]   ev1_dat = rd_rsp_data;
    wire ev2 = pend_pok || mg_now || (pend_miss && !alloc_en && !mg_reg && !mg_now);
    wire [RB-1:0] ev2_tok = pend_tok_q;
    wire [31:0]   ev2_dat = pend_pok ? bank_data : (mg_now ? rd_rsp_data : 32'b0);
    wire          ev2_rep = !(pend_pok || mg_now);

    // ---------------- state ----------------
`ifndef SYNTHESIS
    // The fifo_used bound above is an invariant; catch any violation (a lost
    // or duplicated event) at the cycle it happens instead of corrupting data.
    always_ff @(posedge clock)
        if (!reset && (({1'b0, f_lvl} + ev0 + ev1 + ev2) > 6'(FD)))
            $fatal(1, "dcache: response FIFO overflow");
`endif
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
                m_wv[s]      <= '0;
                m_wkill[s]   <= '0;
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
                for (int w = 0; w < NW; w = w + 1)
                    if (flush_valid && m_valid[s] && m_wv[s][w] &&
                        cpu_pkg::flush_younger(m_wt[s][w], flush_rob, flush_dtail))
                        m_wkill[s][w] <= 1'b1;
            end

            // ---- refill write processing ----
            if (wref) begin
                if (m_bypass[rslot]) begin
                    m_valid[rslot] <= 1'b0;
                    m_wv[rslot]    <= '0;
                end else begin
                    logic [NW-1:0] dne;
                    dne = m_done[rslot] | (ONE_HOT << rword);
                    m_done[rslot] <= dne;
                    // this word's parked waiter is answered (or was killed) now
                    m_wv[rslot][rwidx] <= 1'b0;
                    if (dne == ALL_DONE) begin
                        v_q[m_set[rslot]]   <= 1'b1;
                        tag_q[m_set[rslot]] <= m_tag[rslot];
                        m_valid[rslot]      <= 1'b0;
                        m_wv[rslot]         <= '0;
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
                m_wv[alloc_slot]     <= '0;
                m_wkill[alloc_slot]  <= '0;
                if (!pend_unc) v_q[pend_set_q] <= 1'b0;
            end

            // ---- P0-mwaiter: park the pending lookup's token ----
            // Gated by pend_kill: a token flushed while registering would not be
            // seen by this cycle's kill scan and could alias a reused rob number.
            if (mg_reg) begin
                m_wv[mg_slot][pend_widx]    <= 1'b1;
                m_wt[mg_slot][pend_widx]    <= pend_tok_q;
                m_wkill[mg_slot][pend_widx] <= 1'b0;
            end

            // ---- refill push counters ----
            if (rd_push_valid && rd_push_ready)
                m_pushcnt[push_slot] <= m_pushcnt[push_slot] + 1'b1;

            // ---- response FIFO (up to 3 enqueues: trigger + parked + lookup) ----
            if (ev0) begin
                f_tok[f_tail] <= ev0_tok;
                f_dat[f_tail] <= ev0_dat;
                f_rep[f_tail] <= 1'b0;
            end
            if (ev1) begin
                f_tok[f_tail + {3'b0, ev0}] <= ev1_tok;
                f_dat[f_tail + {3'b0, ev0}] <= ev1_dat;
                f_rep[f_tail + {3'b0, ev0}] <= 1'b0;
            end
            if (ev2) begin
                f_tok[f_tail + {3'b0, ev0} + {3'b0, ev1}] <= ev2_tok;
                f_dat[f_tail + {3'b0, ev0} + {3'b0, ev1}] <= ev2_dat;
                f_rep[f_tail + {3'b0, ev0} + {3'b0, ev1}] <= ev2_rep;
            end
            if (ev0 || ev1 || ev2)
                f_tail <= f_tail + {2'b0, ev0} + {2'b0, ev1} + {2'b0, ev2};
            if (rsp_deq) f_head <= f_head + 4'd1;
            f_lvl <= f_lvl + {4'b0, ev0} + {4'b0, ev1} + {4'b0, ev2} - {4'b0, rsp_deq};
        end
    end

endmodule
