// Data cache: direct-mapped, DC_LINES x LINE_BYTES lines,
// write-through and no-write-allocate, byte-write masks, MSHR_N outstanding
// line fills with keyword-first completion, and a kill bit that drops a
// flushed waiter's response. One 1RW SRAM port per line word (LINE_BYTES/4
// banks) is time-shared between lookups, store hit-updates and refill writes
// in this priority order: refill write (must never be lost) > load lookup >
// store hit-update.
//
// Response merge: lookup results, MSHR keyword completions and parked word
// waiters can occur in the same cycle (at most one of each kind, 3 total), so
// they merge into an FD-deep response FIFO that memory_subsystem drains when its
// output lane is free. One successful response may bypass an empty FIFO.
// Tokens (ROB numbers) identify waiters; killed responses are dropped.
//
// Same-set rule: two MSHRs may never target the same set (their refill writes
// would shred each other's banks); a miss with a busy set responds "replay" and
// the requester retries later. On MSHR allocation the set's valid bit is
// cleared immediately so no lookup can hit half-refilled banks.
//
// Same-line miss merging: a lookup that misses because its line is being
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

    // load lookup (from memory_subsystem); token pairs the response back to the load
    input  wire        lk_valid,
    input  wire [31:0] lk_addr,
    input  wire [RB-1:0] lk_token,
    output wire        lk_ready,

    // Set-valid probe used by load_store_queue to relax its same-line guard.
    // Conservative hit superset; the normal lookup still checks the full tag.
    input  wire [31:0] probe_addr,
    output wire        probe_set_valid,

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
    output wire        su_stall,     // set has an in-flight fill; store must wait

    // store-completion line invalidate (stale-fill cleanup, see memory_subsystem)
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
    localparam int SETB = $clog2(cpu_pkg::DC_LINES);    // set index bits (10 at DC_LINES=1024)
    localparam int OFFB = $clog2(cpu_pkg::LINE_BYTES);  // 4/5
    localparam int NW   = cpu_pkg::LINE_BYTES / 4;      // words per line 4/8
    localparam int WB   = $clog2(NW);                   // word index bits 2/3
    localparam int TAGB = 32 - SETB - OFFB;             // address tag bits (17 at 32-byte lines)
    // Cached lines always have addr[31:28] == 0 (is_uncached() is exactly
    // addr[31:28] != 0), so the top four tag bits are constant zero for every
    // valid tag entry. Store/compare only the low CTAGB bits.
    localparam int CTAGB = TAGB - 4;                    // stored tag bits (13 in the default configuration)
    localparam int PWB  = $clog2(NW + 1);               // push-counter bits 3/4
    localparam int MN   = cpu_pkg::MSHR_N;
    localparam int RB   = $clog2(cpu_pkg::ROB_DEPTH);
    localparam int FD   = 8;                            // response FIFO depth
    localparam int FW   = $clog2(FD);                   // FIFO pointer bits
    localparam int FL   = $clog2(FD + 1);               // FIFO level bits
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
    logic [CTAGB-1:0] tag_q [0:cpu_pkg::DC_LINES-1];

    // Probe set validity, a safe superset of a tag hit. A false positive
    // only permits a normal cache lookup, which can still miss or replay.
    // Avoid a wide tag mux on the same-cycle LSQ guard path.
    assign probe_set_valid = !cpu_pkg::is_uncached(probe_addr) &&
                       v_q[probe_addr[SETB+OFFB-1:OFFB]];

    // ---------------- lookup pipeline (1-cycle SRAM read) ----------------
    // The tag half of the lookup is read in the op-register cycle and parked
    // in the same flop stage as the SRAM data output, so the 1024:1 tag mux is
    // not in the pend-evaluation cycle. The valid bit stays a live read
    // (v_q one-bit mux) so a same-cycle invalidate/alloc clear still wins.
    // Split the tag mux across the existing op/pend stages. Each A bank
    // reads 1/4 of the rows; B selects the bank without another tag-array read.
    localparam int TBB = (SETB >= 2) ? 2 : 0;
    localparam int TBN = 1 << TBB;
    localparam int TRB = SETB - TBB;
    logic [CTAGB-1:0] tag_a_bank_q [0:TBN-1];
    logic [TBN-1:0] valid_a_bank_q;
    wire [CTAGB-1:0] tag_a_q = tag_a_bank_q[op_set_q >> TRB];
    wire valid_a_q = valid_a_bank_q[op_set_q >> TRB];
    logic [CTAGB-1:0] tag_b_bank_q [0:TBN-1];
    wire [CTAGB-1:0] tag_b_q = tag_b_bank_q[pend_set_q >> TRB];
    logic            pend_q;
    logic [RB-1:0]   pend_tok_q;
    logic [CTAGB-1:0] pend_tag_q;
    logic [SETB-1:0] pend_set_q;
    logic [2:0]      pend_word_q;
    logic            pend_unc_q;
    // flush seen while the lookup sat in the op register (the eval cycle only
    // sees a same-cycle flush)
    logic            pend_kill_q;

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
    // Trigger response already enqueued. A killed MSHR whose trigger never
    // fired still owns one reservation; a killed MSHR whose trigger did fire
    // does not (the event is already in the FIFO).
    logic            m_trig_done [0:MN-1];

    // ---------------- response-space credit counter ----------------
    // occ_q counts every response that is either already in the FIFO or
    // reserved for an in-flight operation (op/pend lookup, MSHR trigger,
    // parked word waiter). Admission is then a 4-bit compare instead of an
    // 18-input popcount plus a 7-bit adder plus a compare, which is the
    // dominant flop-to-flop path in this design. Events move a reservation
    // into the FIFO and therefore do not change occ_q; only a dequeue or a
    // killed reservation that can never produce an event releases a slot.
    logic [FL-1:0] occ_q;

    // ---------------- response FIFO (FD deep, up to 3 enqueues/cycle) ------
    logic [RB-1:0] f_tok [0:FD-1];
    logic [31:0] f_dat [0:FD-1];
    logic        f_rep [0:FD-1];
    logic        f_kill[0:FD-1];   // flushed entry: pop without a response
    logic [FW-1:0] f_head, f_tail;
    logic [FL-1:0] f_lvl;
    wire f_skip = (f_lvl != '0) && f_kill[f_head];
    wire fifo_rsp = (f_lvl != '0) && !f_skip;
    wire fast_rsp, fast_deq;
    assign rsp_valid = fifo_rsp || fast_rsp;
    assign rsp_token = fast_rsp ? (ev0 ? ev0_tok : (ev1 ? ev1_tok : ev2_tok)) : f_tok[f_head];
    assign rsp_data = fast_rsp ? (ev0 ? ev0_dat : (ev1 ? ev1_dat : ev2_dat)) : f_dat[f_head];
    assign rsp_replay = fast_rsp ? 1'b0 : f_rep[f_head];
    wire rsp_deq = fifo_rsp && rsp_ready;

    // ---------------- shared SRAM input op register ----------------
    // Exactly one cache operation (refill write, load lookup, or store
    // hit-update) is captured per cycle. The banks are driven from these flops
    // instead of the lookup/tag cone, so the SRAM address/control pins see a
    // flop-to-pin path. A read's bank data is valid one cycle after the bank
    // samples the captured op, and pend_* is loaded in that same cycle.
    logic            op_valid_q;
    logic            op_read_q;
    logic            op_refill_q;
    logic            op_write_q;
    logic [1:0]      op_slot_q;
    logic [2:0]      op_word_q;
    logic [SETB-1:0] op_set_q;
    logic [TAGB-1:0] op_tag_q;
    logic [RB-1:0]   op_tok_q;
    logic [31:0]     op_wdata_q;
    logic [3:0]      op_wmask_q;

    // ---------------- port owner arbitration ----------------
    wire [1:0]  rslot = rd_rsp_idx[4:3];
    wire [2:0]  rword = rd_rsp_idx[2:0];
    wire        wref  = rd_rsp_valid && (rslot <= MN_LAST) && m_valid[rslot];  // valid refill write
    // A request killed by the flush must not enter the miss path at all: its
    // latched lookup would allocate an MSHR two cycles later, when flush_valid
    // has already dropped (the op-stage and pend kills below would miss it) and
    // its stale completion could later alias a reused rob number.
    wire lk_kill = flush_valid && cpu_pkg::flush_younger(lk_token, flush_rob, flush_dtail);
    // FIFO admission: occ_q already reserves a slot for every accepted lookup
    // (op register + pend stage), every live MSHR trigger and every parked
    // word waiter, so the decision is only "is one slot free?".
    wire lk_acc = !wref && !lk_kill && lk_valid && (occ_q < FL'(FD));
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
    // B stage: the op register drives the banks. A refill write completing its
    // line at this clock edge is visible to a store hit-update accepted in the
    // same cycle; that store's own bank write happens one cycle later (after
    // the fill), so it lands on top of the freshly filled line.
    wire        b_refill      = op_valid_q && op_refill_q;
    wire [1:0]  b_slot        = op_slot_q;
    wire [WB-1:0] b_widx      = op_word_q[WB-1:0];
    wire        b_refill_wr   = b_refill && m_valid[b_slot] && !m_bypass[b_slot];
    wire [NW-1:0] b_dne       = m_done[b_slot] | (ONE_HOT << b_widx);
    wire        b_refill_last = b_refill_wr && (b_dne == ALL_DONE);

    wire b_store_wr = op_valid_q && op_write_q && !op_refill_q;
    wire b_wr_hit = b_store_wr && valid_a_q &&
                    (tag_a_q == op_tag_q[CTAGB-1:0]);
    assign su_hit = b_wr_hit;

    // A store must not update/invalidate a line while a refill for the same set
    // is in flight: the fill could otherwise publish data read before this
    // store's write-through. Waiting one fill is cheaper than an epoch table.
    logic su_set_busy;
    always_comb begin
        su_set_busy = 1'b0;
        for (int s = 0; s < MN; s = s + 1)
            if (m_valid[s] && (m_set[s] == su_addr[SETB+OFFB-1:OFFB]))
                su_set_busy = 1'b1;
    end
    assign su_stall = su_set_busy;

    // A stage: select the single operation for this cycle and capture it.
    wire [2:0]      acc_word = lk_acc ? lk_addr[OFFB-1:2] :
                               su_acc ? su_addr[OFFB-1:2] : rword;
    wire [SETB-1:0] acc_set = lk_acc ? lk_addr[SETB+OFFB-1:OFFB] :
                              su_acc ? su_addr[SETB+OFFB-1:OFFB] : m_set[rslot];
    wire            a_set_fill = b_refill_last && (m_set[b_slot] == acc_set);
    wire [31:0]     acc_wdata = su_acc ? su_data : rd_rsp_data;
    wire [3:0]      acc_wmask = su_acc ? su_strb : 4'hf;
    wire            a_op_valid    = lk_acc || wref || su_acc;
    wire            op_read_sel   = lk_acc;
    wire            op_refill_sel = wref;
    wire            op_write_sel  = su_acc || (wref && !m_bypass[rslot]);

    // B stage: decode the captured op into per-bank enables.
    wire b_read  = op_valid_q && op_read_q;
    wire b_write = op_valid_q && op_write_q;
    wire b_en    = b_read || b_refill_wr || b_wr_hit;
    wire b_we    = b_refill_wr || b_wr_hit;
    logic [NW-1:0] bank_en;
    always_comb begin
        bank_en = '0;
        for (int w = 0; w < NW; w = w + 1)
            bank_en[w] = b_en && (op_word_q[WB-1:0] == w[WB-1:0]);
    end

    wire [31:0] bank_rdata [0:NW-1];
    generate
        for (genvar g = 0; g < NW; g = g + 1) begin : g_dbank
            sram_fakeram #(.DEPTH(cpu_pkg::DC_LINES), .WIDTH(32), .WRITE_GRANULARITY(8)) u_bank (
                .clk(clock), .en(bank_en[g]), .we(b_we), .wmask(op_wmask_q),
                .addr(op_set_q), .wdata(op_wdata_q), .rdata(bank_rdata[g]));
        end
    endgenerate

    logic [31:0] bank_data;
    always_comb begin
        bank_data = '0;
        for (int w = 0; w < NW; w = w + 1)
            if (pend_word_q[WB-1:0] == w[WB-1:0]) bank_data = bank_rdata[w];
    end

    // ---------------- lookup result ----------------
    wire pend_hit  = pend_q && !pend_unc_q && v_q[pend_set_q] &&
                     (tag_b_q == pend_tag_q);
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
    wire pend_kill = pend_q && (pend_kill_q ||
                     (flush_valid && cpu_pkg::flush_younger(pend_tok_q, flush_rob, flush_dtail)));
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
    // the word is in the op register now and lands at this clock edge: answer
    // with the captured refill data instead of the (stale) bank read.
    wire mg_now  = mg_cand && b_refill_wr && (b_slot == mg_slot) && (b_widx == pend_widx);
    // park only when this word's single waiter slot is free
    wire mg_reg  = mg_cand && !mg_now && !m_wv[mg_slot][pend_widx];
    // A flushed lookup must produce NO response at all.  A replay would be
    // harmless, but a hit would put the old rob token back into the FIFO; if
    // that token is reused before the FIFO drains, a younger load consumes
    // stale data.  Drop the reservation instead.
    wire pend_drop = pend_q && pend_kill;

    // keyword completion (trigger word arrived, waiter still alive)
    wire kw_ev = b_refill && m_valid[b_slot] && (b_widx == m_trig[b_slot][WB-1:0]) &&
                 !m_killed[b_slot];
    // parked waiter served at its word arrival (m_wv is cleared at this edge)
    wire park_ev = b_refill && m_valid[b_slot] && m_wv[b_slot][b_widx] &&
                   !m_wkill[b_slot][b_widx];

    // MSHR slot frees at this edge (bypass has a single word).
    wire b_free = b_refill && m_valid[b_slot] &&
                  (m_bypass[b_slot] || (b_dne == ALL_DONE));
    // Reservations that can never produce a FIFO event are released here so a
    // killed flush shadow cannot permanently consume the response space.
    // A trigger whose event already fired (m_trig_done) is already in f_lvl.
    wire rel_trig = b_free && m_killed[b_slot] && !m_trig_done[b_slot] && !kw_ev;
    wire rel_park = b_refill && m_valid[b_slot] && !m_bypass[b_slot] &&
                    m_wv[b_slot][b_widx] && m_wkill[b_slot][b_widx];

    // response FIFO events: E0 = trigger word, E1 = parked word waiter,
    // E2 = pending lookup (hit / partial hit / merged word data / replay).
    wire ev0 = kw_ev;
    wire [RB-1:0] ev0_tok = m_token[b_slot];
    wire [31:0]   ev0_dat = op_wdata_q;
    wire ev1 = park_ev;
    wire [RB-1:0] ev1_tok = m_wt[b_slot][b_widx];
    wire [31:0]   ev1_dat = op_wdata_q;
    wire ev2 = !pend_drop &&
               (pend_pok || mg_now || (pend_miss && !alloc_en && !mg_reg && !mg_now));
    wire [RB-1:0] ev2_tok = pend_tok_q;
    wire [31:0]   ev2_dat = pend_pok ? bank_data : (mg_now ? op_wdata_q : 32'b0);
    wire          ev2_rep = !(pend_pok || mg_now);

    // Bypass the empty FIFO for one completed lookup. A stalled response
    // is captured normally, so its payload survives output backpressure.
    wire one_event = ({ev0,ev1,ev2} == 3'b100) ||
                     ({ev0,ev1,ev2} == 3'b010) ||
                     ({ev0,ev1,ev2} == 3'b001 && !ev2_rep);
    assign fast_rsp = (f_lvl == 0) && one_event;
    assign fast_deq = fast_rsp && rsp_ready;
    wire enq0 = ev0 && !fast_deq;
    wire enq1 = ev1 && !fast_deq;
    wire enq2 = ev2 && !fast_deq;

    // Write positions wrap modulo FD (FD is a power of two).
    wire [FW-1:0] f_pos0 = f_tail;
    wire [FW-1:0] f_pos1 = f_tail + ev0;
    wire [FW-1:0] f_pos2 = f_tail + ev0 + ev1;

    // ---------------- state ----------------
`ifndef SYNTHESIS
    // The FIFO bound is an invariant; catch any violation (a lost or
    // duplicated event) at the cycle it happens instead of corrupting data.
    always_ff @(posedge clock)
        if (!reset && (({1'b0, f_lvl} + enq0 + enq1 + enq2) > 6'(FD)))
            $fatal(1, "dcache: response FIFO overflow");
    // occ_q must always equal FIFO occupancy plus all outstanding
    // reservations (op/pend lookups, live triggers, occupied park slots).
    logic [FL:0] resid;
    always_comb begin
        resid = {1'b0, op_read_q} + {1'b0, pend_q};
        for (int s = 0; s < MN; s = s + 1) begin
            if (m_valid[s] && !m_trig_done[s]) resid = resid + 1'b1;
            for (int w = 0; w < NW; w = w + 1)
                if (m_wv[s][w]) resid = resid + 1'b1;
        end
    end
    always_ff @(posedge clock)
        if (!reset && ({1'b0, occ_q} != ({1'b0, f_lvl} + resid)))
            $fatal(1, "dcache: response credit accounting mismatch");
`endif
    always_ff @(posedge clock) begin
        if (reset) begin
            v_q <= '0;
            for (int b = 0; b < TBN; b = b + 1) tag_a_bank_q[b] <= '0;
            valid_a_bank_q <= '0;
            for (int b = 0; b < TBN; b = b + 1) tag_b_bank_q[b] <= '0;
            pend_q <= 1'b0;
            pend_unc_q <= 1'b0;
            pend_kill_q <= 1'b0;
            op_valid_q <= 1'b0;
            op_read_q  <= 1'b0;
            op_refill_q <= 1'b0;
            op_write_q <= 1'b0;
            op_slot_q  <= 2'd0;
            op_word_q  <= 3'd0;
            op_set_q   <= '0;
            op_tag_q   <= '0;
            op_tok_q   <= '0;
            op_wdata_q <= '0;
            op_wmask_q <= '0;
            for (int s = 0; s < MN; s = s + 1) begin
                m_valid[s]   <= 1'b0;
                m_killed[s]  <= 1'b0;
                m_pushcnt[s] <= '0;
                m_done[s]    <= '0;
                m_wv[s]      <= '0;
                m_wkill[s]   <= '0;
                m_trig_done[s] <= 1'b0;
            end
            f_head <= '0; f_tail <= '0; f_lvl <= '0;
            for (int k = 0; k < FD; k = k + 1) f_kill[k] <= 1'b0;
            occ_q <= '0;
        end else begin
            // ---- lookup pipeline: op register -> pend ----
            // The bank samples the captured op at this edge; its rdata is valid
            // in the next cycle, which is exactly when pend_q goes high. A flush
            // that arrives while the lookup sits in the op register is recorded
            // here so the pend stage cannot allocate an MSHR for it.
            pend_q      <= b_read;
            pend_kill_q <= b_read && flush_valid &&
                           cpu_pkg::flush_younger(op_tok_q, flush_rob, flush_dtail);
            // Store tags read directly from the drain address, without the
            // load/store/refill input arbitration mux in their address path.
            if (su_acc) begin
                for (int b = 0; b < TBN; b = b + 1) begin
                    tag_a_bank_q[b] <= tag_q[SETB'((b << TRB) | int'(su_addr[OFFB+TRB-1:OFFB]))];
                    valid_a_bank_q[b] <= v_q[SETB'((b << TRB) | int'(su_addr[OFFB+TRB-1:OFFB]))];
                    // Forward a fill published at the same edge as the A read.
                    // These are the only writes to tag_q, so B sees the same
                    // tag as a fresh read of tag_q[op_set_q] one cycle later.
                    if (a_set_fill && (int'(acc_set >> TRB) == b)) begin
                        tag_a_bank_q[b] <= m_tag[b_slot][CTAGB-1:0];
                        valid_a_bank_q[b] <= 1'b1;
                    end
                end
            end
            if (b_read) begin
                // Load tag reads use the registered op address. The bank
                // select is evaluated in the response stage, retaining the
                // same SRAM/lookup latency as the unbanked B-stage read.
                for (int b = 0; b < TBN; b = b + 1)
                    tag_b_bank_q[b] <= tag_q[SETB'((b << TRB) | int'(op_set_q[TRB-1:0]))];
                pend_tok_q  <= op_tok_q;
                pend_tag_q  <= op_tag_q[CTAGB-1:0];
                pend_set_q  <= op_set_q;
                pend_word_q <= op_word_q;
                pend_unc_q  <= |op_tag_q[TAGB-1:TAGB-4];   // addr[31:28] != 0
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

            // ---- refill write processing (op-register write stage) ----
            // The bank write and these state updates happen at the same edge.
            if (b_refill && m_valid[b_slot]) begin
                if (m_bypass[b_slot]) begin
                    m_valid[b_slot] <= 1'b0;
                    m_wv[b_slot]    <= '0;
                end else begin
                    logic [NW-1:0] dne;
                    dne = b_dne;
                    m_done[b_slot] <= dne;
                    // this word's parked waiter is answered (or was killed) now
                    m_wv[b_slot][b_widx] <= 1'b0;
                    if (dne == ALL_DONE) begin
                        v_q[m_set[b_slot]]   <= 1'b1;
                        tag_q[m_set[b_slot]] <= m_tag[b_slot][CTAGB-1:0];
                        m_valid[b_slot]      <= 1'b0;
                        m_wv[b_slot]         <= '0;
                    end
                end
                if (kw_ev) m_trig_done[b_slot] <= 1'b1;
                if (b_free) m_trig_done[b_slot] <= 1'b0;
            end

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
                m_trig_done[alloc_slot] <= 1'b0;
                if (!pend_unc) v_q[pend_set_q] <= 1'b0;
            end

            // ---- store-completion invalidate (line may hold a stale fill) ----
            // Set-only clear is a safe superset of the tag-matched invalidate:
            // the store already wrote through, so dropping any line in this set
            // cannot lose data and only costs a later refill.
            if (inv_valid && !cpu_pkg::is_uncached(inv_addr))
                v_q[inv_addr[SETB+OFFB-1:OFFB]] <= 1'b0;

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

            // ---- capture this cycle's single cache op (A stage) ----
            op_valid_q  <= op_read_sel || op_refill_sel || op_write_sel;
            op_read_q   <= op_read_sel;
            op_refill_q <= op_refill_sel;
            op_write_q  <= op_write_sel;
            op_slot_q   <= op_refill_sel ? rslot : 2'd0;
            op_word_q   <= acc_word;
            op_set_q    <= acc_set;
            op_tag_q    <= lk_acc ? lk_addr[31:SETB+OFFB] : su_addr[31:SETB+OFFB];
            op_tok_q    <= lk_token;
            op_wdata_q  <= acc_wdata;
            op_wmask_q  <= acc_wmask;

            // ---- response FIFO (up to 3 enqueues: trigger + parked + lookup) ----
            if (enq0) begin
                f_tok[f_pos0] <= ev0_tok;
                f_dat[f_pos0] <= ev0_dat;
                f_rep[f_pos0] <= 1'b0;
                f_kill[f_pos0] <= 1'b0;
            end
            if (enq1) begin
                f_tok[f_pos1] <= ev1_tok;
                f_dat[f_pos1] <= ev1_dat;
                f_rep[f_pos1] <= 1'b0;
                f_kill[f_pos1] <= 1'b0;
            end
            if (enq2) begin
                f_tok[f_pos2] <= ev2_tok;
                f_dat[f_pos2] <= ev2_dat;
                f_rep[f_pos2] <= ev2_rep;
                f_kill[f_pos2] <= 1'b0;
            end
            if (enq0 || enq1 || enq2)
                f_tail <= f_tail + {2'b0, enq0} + {2'b0, enq1} + {2'b0, enq2};
            // A response already sitting in the FIFO when its load is flushed
            // carries that load's rob token.  Mark it dead so it is popped
            // without being matched by a younger load that reuses the token.
            if (flush_valid)
                for (int k = 0; k < FD; k = k + 1) begin
                    logic [FW-1:0] idx;
                    idx = f_head + k[FW-1:0];
                    if ((k < f_lvl) &&
                        cpu_pkg::flush_younger(f_tok[idx], flush_rob, flush_dtail))
                        f_kill[idx] <= 1'b1;
                end
            if (rsp_deq || f_skip) f_head <= f_head + 1'b1;
            f_lvl <= f_lvl + enq0 + enq1 + enq2 - rsp_deq - f_skip;
            occ_q <= occ_q + lk_acc - rsp_deq - fast_deq - f_skip - rel_trig - rel_park - pend_drop;
        end
    end

endmodule
