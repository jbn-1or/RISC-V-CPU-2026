// Address generation, load/store queues, forwarding and replay scheduling.
//
// Loads allocate at issue and move WAIT -> SENT on cache acceptance. A replay
// returns them to WAIT; a successful response writes back on BB in the same
// cycle. Fully covered store forwards use a writeback register to keep the
// store-compare tree off the same-cycle wakeup/branch path. Partial overlap
// blocks the load. A same-line guard prevents stale cache allocations.
//
// Stores issue in program order once their address is ready; missing data is
// captured later from qualified writeback buses. The AGU marks the ROB entry
// done, but only retired stores may drain. Entries remain until AXI B completes.
//
// Unretired ages use ROB distance from head. Retired stores use a separate
// modular retirement stamp, since they may outlive their original ROB slot.
module load_store_queue (
    input  wire        clock,
    input  wire        reset,

    // ---- issue (loads may issue out of order; stores in order) ----
    input  wire        in_valid,
    input  wire cpu_pkg::op_e in_op,
    input  wire [2:0]  in_funct3,
    input  wire [31:0] in_base,
    input  wire [31:0] in_imm,
    input  wire [31:0] in_store_data,
    input  wire [$clog2(cpu_pkg::PRF_NUM)-1:0] in_pdst,
    input  wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] in_rob,
    // Store data operand tag + whether its value is valid now.
    // If not valid, the STQ captures it later from the writeback-bus CAM.
    input  wire [$clog2(cpu_pkg::PRF_NUM)-1:0] in_ps2,
    input  wire        in_rs2_ready,
    // Qualified writeback bus (BA/BB) used only to fill pending store data.
    input  cpu_pkg::writeback_t wb_a,
    input  cpu_pkg::writeback_t wb_b,
    output wire        ld_alloc_ok,
    output wire        st_alloc_ok,

    // ---- writeback (BB) ----
    output wire        wb_valid,
    output wire [$clog2(cpu_pkg::PRF_NUM)-1:0] wb_tag,
    output wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] wb_rob,
    output wire [31:0] wb_data,
    input  wire        wb_ready,

    // ---- narrow completion: store AGU done / rd=x0 load ----
    output wire        ndone_valid,
    output wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] ndone_rob,

    // ---- ROB references: commit head + store retirement pulses ----
    input  wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] rob_head,
    input  wire [1:0]  cmt_valid,
    input  wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] cmt_rob0,
    input  wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] cmt_rob1,

    // ---- flush ----
    input  wire        flush_valid,
    input  wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] flush_rob,
    input  wire [$clog2(cpu_pkg::ROB_DEPTH):0] flush_dtail,

    // ---- memory channels to memory_subsystem ----
    output wire        ld_valid,
    output cpu_pkg::mem_req_t ld_req,
    input  wire        ld_ready,
    output wire        st_valid,
    output cpu_pkg::mem_req_t st_req,
    input  wire        st_ready,

    // ---- responses from memory_subsystem ----
    input  wire        resp_valid,
    input  cpu_pkg::mem_resp_t resp,
    input  wire        resp_replay,

    // ---- D$ set-valid probe for the same-line guard relaxation ----
    output wire [31:0] probe_addr,
    input  wire        probe_set_valid,
);
    localparam int DQ = cpu_pkg::LDQ_DEPTH;   // load queue depth
    localparam int SQ = cpu_pkg::STQ_DEPTH;   // store queue depth
    localparam int LB = (DQ > 1) ? $clog2(DQ) : 1;   // load slot index bits
    localparam int SB = (SQ > 1) ? $clog2(SQ) : 1;   // store slot index bits
    localparam int RB = $clog2(cpu_pkg::ROB_DEPTH);   // rob index bits
    localparam int PB = $clog2(cpu_pkg::PRF_NUM);     // physical tag bits

    // Two retire-stamp ticks per store event; half the modular domain
    // exceeds the maximum separation of simultaneously resident stores.
    localparam int SEQW = $clog2(SQ) + 2;
    localparam int K = (SEQW > RB) ? SEQW : RB;
    localparam int SPAD = 1 << SB;

    // ---------------- address / mask helpers ----------------
    function automatic logic [3:0] lanes(input logic [2:0] f3, input logic [1:0] off);
        lanes = (f3 == 3'b010) ? 4'b1111 :
                ((f3 == 3'b001) || (f3 == 3'b101)) ? (off[1] ? 4'b1100 : 4'b0011) :
                                                     ((off == 2'd0) ? 4'b0001 : (off == 2'd1) ? 4'b0010 : (off == 2'd2) ? 4'b0100 : 4'b1000);
    endfunction

    function automatic logic [31:0] ldext(input logic [31:0] d, input logic [2:0] f3,
                                          input logic [1:0] off);
        logic [31:0] bsel, hsel;
        bsel = (off == 0) ? {24'b0,d[7:0]} : (off == 1) ? {24'b0,d[15:8]} :
               (off == 2) ? {24'b0,d[23:16]} : {24'b0,d[31:24]};
        hsel = off[1] ? {16'b0,d[31:16]} : {16'b0,d[15:0]};
        case (f3)
            3'b000:  ldext = {{24{bsel[7]}}, bsel[7:0]};
            3'b001:  ldext = {{16{hsel[15]}}, hsel[15:0]};
            3'b010:  ldext = d;
            3'b100:  ldext = {24'b0, bsel[7:0]};
            default: ldext = {16'b0, hsel[15:0]};
        endcase
    endfunction

    function automatic logic [31:0] stsh(input logic [31:0] d, input logic [2:0] f3,
                                         input logic [1:0] off);
        stsh = (f3 == 3'b010) ? d :
               (f3 == 3'b001) ? (off[1] ? {d[15:0],16'b0} : d) :
                                ((off == 0) ? d : (off == 1) ? {d[23:0],8'b0} : (off == 2) ? {d[15:0],16'b0} : {d[7:0],24'b0});
    endfunction

    function automatic logic [LB-1:0] lowest_l(input logic [DQ-1:0] v);
        lowest_l = '0;
        for (int i = DQ-1; i >= 0; i = i - 1)
            if (v[i]) lowest_l = i[LB-1:0];
    endfunction

    function automatic logic [SB-1:0] lowest_s(input logic [SQ-1:0] v);
        lowest_s = '0;
        for (int i = SQ-1; i >= 0; i = i - 1)
            if (v[i]) lowest_s = i[SB-1:0];
    endfunction

    // ---------------- load queue ----------------
    logic [DQ-1:0] l_valid;
    localparam logic [1:0] LOAD_WAIT = 2'd0; // waiting for forwarding/cache
    localparam logic [1:0] LOAD_SENT = 2'd1; // awaiting cache response/replay
    localparam logic [1:0] LOAD_DONE = 2'd2; // buffered response, awaiting WB hold
    logic [1:0] l_state [0:DQ-1];
    logic [31:0] l_addr [0:DQ-1];
    logic [2:0]  l_f3   [0:DQ-1];
    logic [RB-1:0] l_rob  [0:DQ-1];
    logic [$clog2(cpu_pkg::PRF_NUM)-1:0] l_pdst [0:DQ-1];
    logic [31:0] l_data [0:DQ-1];

    // ---------------- store queue ----------------
    logic [SQ-1:0] s_valid, s_ret, s_drd;
    logic [SQ-1:0] s_dvalid;                 // store data value present
    logic [31:0] s_addr [0:SQ-1];
    logic [31:0] s_data [0:SQ-1];
    logic [3:0]  s_mask [0:SQ-1];
    logic [RB-1:0] s_rob  [0:SQ-1];
    logic [2:0]  s_f3   [0:SQ-1];          // width/sign for late data fill
    logic [$clog2(cpu_pkg::PRF_NUM)-1:0] s_ps2 [0:SQ-1];  // data producer tag

    // ---------------- writeback hold ----------------
    logic        wb_hold_valid;
    logic [PB-1:0] wb_hold_tag;
    logic [RB-1:0] wb_hold_rob;
    logic [31:0] wb_hold_data;

    // D$ data bypasses the hold register; store forwarding enters wb_hold_valid.
    // A coincident cache response wins BB and leaves the hold entry pending.
    // Priority: cache response > held LSU result > MUL > ALU1 (core_ooo).
    logic        cache_wb_valid;
    logic [PB-1:0] cache_wb_tag;
    logic [RB-1:0] cache_wb_rob;
    logic [31:0] cache_wb_data;
    logic        load_response_match;
    logic [LB-1:0]  response_load_slot;

    assign wb_valid = cache_wb_valid || wb_hold_valid;
    assign wb_tag   = cache_wb_valid ? cache_wb_tag : wb_hold_tag;
    assign wb_rob   = cache_wb_valid ? cache_wb_rob : wb_hold_rob;
    assign wb_data  = cache_wb_valid ? cache_wb_data : wb_hold_data;
    // The hold entry leaves the bus only when it is the one being presented;
    // when the early path wins, wb_hold_valid must be retained (not dropped).
    wire wb_grant = wb_hold_valid && !cache_wb_valid && wb_ready;

    // ---------------- issue / allocation ----------------
    wire is_store = (in_op == cpu_pkg::OP_STORE);
    wire is_load  = (in_op == cpu_pkg::OP_LOAD);
    wire lf = (l_valid != {DQ{1'b1}});
    wire sf = (s_valid != {SQ{1'b1}});
    // Readiness is split per op kind (loads need LDQ room, stores need STQ
    // room). The IQ selects using the candidate entry's registered op, so this
    // stays independent of the presented op and cannot form a comb loop.
    assign ld_alloc_ok = !reset && lf;
    assign st_alloc_ok = !reset && sf;
    // A record younger than the flush point must never allocate in the same
    // cycle the flush arrives: the kill scan below only sees already-set valid
    // bits, so the entry would leak as a zombie (and its stale response could
    // alias a reused rob number).
    wire in_kill = flush_valid && cpu_pkg::flush_younger(in_rob, flush_rob, flush_dtail);
    wire in_fire = in_valid && !in_kill && (is_store ? st_alloc_ok : ld_alloc_ok);
    wire rd0 = is_load && (in_pdst == '0);

    assign ndone_valid = in_fire && (is_store || rd0);
    assign ndone_rob   = in_rob;

    wire [LB-1:0] lpos = lowest_l(~l_valid);
    wire [SB-1:0] spos = lowest_s(~s_valid);

    wire [31:0] in_vaddr = in_base + in_imm;
    wire [1:0]  in_off   = in_vaddr[1:0];

    // ---------------- flush kill masks (same-cycle guard) ----------------
    // The latched candidates below are chosen combinationally; a flush in the
    // same cycle would kill the picked entry after the latch decision, leaving
    // a stale selector. Filter the latch predicates with these masks.
    logic [DQ-1:0] ld_kill_mask;
    logic [SQ-1:0] st_kill_mask;
    always_comb begin
        for (int i = 0; i < DQ; i = i + 1)
            ld_kill_mask[i] = flush_valid && l_valid[i] &&
                              cpu_pkg::flush_younger(l_rob[i], flush_rob, flush_dtail);
        for (int i = 0; i < SQ; i = i + 1)
            st_kill_mask[i] = flush_valid && s_valid[i] && !s_ret[i] &&
                              cpu_pkg::flush_younger(s_rob[i], flush_rob, flush_dtail);
    end

    // ---------------- program-order keys ----------------
    // Retired stores are older than all live ROB entries, but may outlive
    // their original ROB slot. Use modular retirement stamps for them and
    // head-relative ROB distances for live entries. Bit K selects the domain.
    logic [K:0] s_key [0:SQ-1];
    logic [K:0] l_key [0:DQ-1];
    logic [SEQW-1:0] ret_seq_q;
    logic [SEQW-1:0] s_seq   [0:SQ-1];
    always_comb begin
        for (int i = 0; i < SQ; i = i + 1)
            s_key[i] = s_ret[i] ? {1'b0, {(K-SEQW){1'b0}}, s_seq[i]}
                                : {1'b1, {(K-RB){1'b0}}, (s_rob[i] - rob_head)};
        for (int i = 0; i < DQ; i = i + 1)
            l_key[i] = {1'b1, {(K-RB){1'b0}}, (l_rob[i] - rob_head)};
    end

    // The Retire stamp wraps in its bounded modular domain; a plain compare
    // of raw stamps would invert order for two entries straddling that wrap.
    // Retire order is modular-compared instead: "a older than b" iff the
    // forward distance b-a is under half the domain. Sound for any pair of
    // simultaneously live stamps: at most 2*STQ_DEPTH ticks separate live
    // stores, below half the SEQW-bit domain. Retired-vs-live uses the domain bit.
    function automatic logic seq_older(input logic [SEQW-1:0] a, input logic [SEQW-1:0] b);
        logic [SEQW-1:0] d;
        d = b - a;
        seq_older = (d != '0) && !d[SEQW-1];
    endfunction

    // Wrap-safe "a is newer than b". Bit K selects the live ROB domain,
    // which is always younger than the retired-store domain.
    function automatic logic key_newer(input logic [K:0] a, input logic [K:0] b);
        if (a[K] != b[K])     key_newer = a[K];
        else if (a[K])         key_newer = (a[K-1:0] > b[K-1:0]);   // live: dist ahead
        else                    key_newer = seq_older(b[SEQW-1:0], a[SEQW-1:0]);
    endfunction

    // ---------------- STQ drain: oldest retired, not yet drained ------------
    logic [SQ-1:0] drain_mask;
    function automatic logic [SB:0] oldest_store(input logic [SQ-1:0] eligible);
        logic [2*SPAD-1:0] tv;
        logic [SEQW-1:0] ts [0:2*SPAD-1];
        logic [SB-1:0] ti [0:2*SPAD-1];
        tv = '0;
        for (int n = 0; n < 2*SPAD; n = n + 1) begin
            ts[n] = '0; ti[n] = '0;
        end
        for (int st = 0; st < SQ; st = st + 1) begin
            tv[SPAD+st] = eligible[st];
            ts[SPAD+st] = s_seq[st];
            ti[SPAD+st] = st[SB-1:0];
        end
        for (int n = SPAD-1; n > 0; n = n - 1) begin
            logic right_wins;
            right_wins = tv[2*n+1] && (!tv[2*n] || seq_older(ts[2*n+1],ts[2*n]));
            tv[n] = tv[2*n] || tv[2*n+1];
            ts[n] = right_wins ? ts[2*n+1] : ts[2*n];
            ti[n] = right_wins ? ti[2*n+1] : ti[2*n];
        end
        oldest_store = {tv[1],ti[1]};
    endfunction
    wire [SB:0] drain_pick = oldest_store(s_valid & s_ret & ~s_drd & s_dvalid);
    always_comb begin
        for (int st = 0; st < SQ; st = st + 1)
            drain_mask[st] = drain_pick[SB] && drain_pick[SB-1:0] == st[SB-1:0];
    end
    wire [SB:0] complete_pick = oldest_store(s_valid & s_drd);

    // store retires this cycle (for the monotonic retire-order stamp)
    logic [1:0] n_ret;
    always_comb begin
        n_ret = 2'd0;
        for (int i = 0; i < SQ; i = i + 1) begin
            if (cmt_valid[0] && s_valid[i] && (s_rob[i] == cmt_rob0) && !s_ret[i]) n_ret = n_ret + 2'd1;
            if (cmt_valid[1] && s_valid[i] && (s_rob[i] == cmt_rob1) && !s_ret[i]) n_ret = n_ret + 2'd1;
        end
    end

    // latched drain candidate (payload must be stable until accepted)
    logic        st_v;
    logic [SB-1:0] st_i;
    wire [SQ-1:0]  drain_ok = drain_mask & ~st_kill_mask;
    wire [SQ-1:0]  st_cand = st_v ? ({{(SQ-1){1'b0}}, 1'b1} << st_i) : drain_ok;

    always_comb begin
        st_req = '0;
        st_req.is_store = 1'b1;
        for (int i = 0; i < SQ; i = i + 1) begin
            if (st_cand[i]) begin
                st_req.addr   = s_addr[i];
                st_req.wdata  = s_data[i];
                st_req.wstrb  = s_mask[i];
                st_req.rob    = s_rob[i];
            end
        end
        // funct3 is not needed for stores downstream (mask/strb carry semantics)
        st_req.funct3 = 3'b000;
    end
    assign st_valid = (st_cand != '0);

    // line mask derived from the single line-size knob (guard must follow it)
    wire [31:0] line_msk = ~(32'(cpu_pkg::LINE_BYTES) - 32'd1);

    // ---------------- load forwarding evaluation ----------------
    logic [DQ-1:0]  f_go, f_fwd;
    logic [DQ-1:0]  sl_any, blk_ov;   // per-load: older same-line store / overlap block
    logic [31:0] f_data [0:DQ-1];
    logic [LB-1:0] gs_i;             // oldest load blocked ONLY by the same-line guard
    logic        gs_v;
    // Evaluate addresses/age in parallel, then choose the youngest matching
    // older store with a balanced tree instead of a serial best-so-far scan.
    always_comb begin
        f_go = '0; f_fwd = '0; sl_any = '0; blk_ov = '0;
        for (int i = 0; i < DQ; i = i + 1) begin
            logic [3:0] lm;
            logic [SPAD-1:0] sl_mask;
            logic [2*SPAD-1:0] tv;
            logic [K:0] tk [0:2*SPAD-1];
            logic [SB-1:0] ti [0:2*SPAD-1];
            logic [SB-1:0] best;
            lm = lanes(l_f3[i], l_addr[i][1:0]);
            sl_mask = '0; tv = '0;
            for (int n = 0; n < 2*SPAD; n = n + 1) begin
                tk[n] = '0; ti[n] = '0;
            end
            for (int st = 0; st < SQ; st = st + 1) begin
                logic older, ov;
                older = s_valid[st] && (s_key[st] < l_key[i]);
                ov = (s_addr[st][31:2] == l_addr[i][31:2]) &&
                     ((s_mask[st] & lm) != 0);
                sl_mask[st] = older && ((s_addr[st] & line_msk) ==
                                        (l_addr[i] & line_msk));
                tv[SPAD+st] = older && ov;
                tk[SPAD+st] = s_key[st];
                ti[SPAD+st] = st[SB-1:0];
            end
            for (int n = SPAD-1; n > 0; n = n - 1) begin
                logic right_wins;
                right_wins = tv[2*n+1] && (!tv[2*n] ||
                             key_newer(tk[2*n+1], tk[2*n]));
                tv[n] = tv[2*n] || tv[2*n+1];
                tk[n] = right_wins ? tk[2*n+1] : tk[2*n];
                ti[n] = right_wins ? ti[2*n+1] : ti[2*n];
            end
            best = ti[1];
            f_data[i] = ldext(s_data[best], l_f3[i], l_addr[i][1:0]);
            if (l_valid[i] && l_state[i] == 0) begin
                sl_any[i] = |sl_mask;
                f_fwd[i] = tv[1] && ((s_mask[best] & lm) == lm) && s_dvalid[best];
                blk_ov[i] = tv[1] && !f_fwd[i];
                f_go[i] = !tv[1] && !(|sl_mask);
            end
        end
    end

    // Guard relaxation index: the oldest load blocked ONLY by the same-line
    // guard. Computed in its own block that does NOT read probe_set_valid, so gs_i
    // cannot feed back through probe_addr -> probe_set_valid. That feedback was a
    // circular-combinational path (signal gs_i) that made ABC synthesis
    // explode from minutes to >20 min.
    always_comb begin
        logic gs_v_l;
        logic [K:0] gs_key;
        gs_v_l = 1'b0; gs_i = '0; gs_key = '1;
        for (int i = 0; i < DQ; i = i + 1) begin
            if (l_valid[i] && (l_state[i] == LOAD_WAIT) && sl_any[i] && !blk_ov[i] &&
                !f_fwd[i] && !ld_kill_mask[i] &&
                (!gs_v_l || (l_key[i] < gs_key))) begin
                gs_v_l = 1'b1; gs_i = i[LB-1:0]; gs_key = l_key[i];
            end
        end
        gs_v = gs_v_l;
    end
    assign probe_addr = l_addr[gs_i];

    // relaxed GO: waive the same-line guard when the D$ probe says the line hits
    // (a hit never allocates, so the stale-fill race cannot occur).
    logic [DQ-1:0] f_go_r;
    always_comb begin
        f_go_r = f_go;
        if (gs_v && probe_set_valid) f_go_r[gs_i] = 1'b1;
    end

    // ---------------- load scheduler ----------------
    // A newly eligible (not yet latched) load is presented to the D$ port in the
    // same cycle it is picked; if the port accepts immediately the entry goes
    // SENT with no latch (removing the mandatory select->present cycle). Only
    // when the port is busy is the candidate latched, and the latched payload
    // then stays stable until accepted. Store-forward completions do not use the
    // memory port, so they also finish in the pick cycle.
    logic       sc_v;
    logic [LB-1:0] sc_i;
    logic       nsel_v;
    logic [LB-1:0] nsel_i;
    wire [LB-1:0]  cur_i   = sc_v ? sc_i : nsel_i;
    wire        cur_v   = sc_v || nsel_v;
    wire        cur_go  = cur_v && f_go_r[cur_i];
    wire        cur_fwd = cur_v && f_fwd[cur_i];
    wire        cur_fwd_ok = cur_fwd && !ld_kill_mask[cur_i];

    always_comb begin
        logic best_found;
        logic [K:0] best_age;
        logic [LB-1:0] best;
        best_age = '1; best = '0; best_found = 1'b0;
        for (int i = 0; i < DQ; i = i + 1) begin
            if (l_valid[i] && (l_state[i] == LOAD_WAIT) && (f_go_r[i] || f_fwd[i]) &&
                !ld_kill_mask[i]) begin
                if (!best_found || (l_key[i] < best_age)) begin
                    best_age = l_key[i]; best = i[LB-1:0]; best_found = 1'b1;
                end
            end
        end
        nsel_v = best_found; nsel_i = best;
    end

    always_comb begin
        ld_req = '0;
        ld_req.is_store = 1'b0;
        if (cur_go) begin
            ld_req.addr   = l_addr[cur_i];
            ld_req.funct3 = l_f3[cur_i];
            ld_req.rob    = l_rob[cur_i];
        end
    end
    assign ld_valid = cur_go;

    // ---------------- writeback selection ----------------
    logic [DQ-1:0] done_mask;
    wire [LB-1:0] dsel;
    logic [K:0] dbest;
    always_comb begin
        logic found;
        done_mask = '0;
        dbest = '1;
        found = 1'b0;
        for (int i = 0; i < DQ; i = i + 1) begin
            if (l_valid[i] && (l_state[i] == LOAD_DONE)) begin
                if (!found || (l_key[i] < dbest)) begin
                    dbest = l_key[i];
                    found = 1'b1;
                end
            end
        end
        if (found) begin
            for (int i = 0; i < DQ; i = i + 1)
                if (l_valid[i] && (l_state[i] == LOAD_DONE) && (l_key[i] == dbest))
                    done_mask[i] = 1'b1;
        end
    end
    assign dsel = lowest_l(done_mask);
    wire have_done = (done_mask != '0);
    wire hold_take = have_done && (!wb_hold_valid || wb_grant) && !flush_valid;

    // ---------------- cache-response writeback ----------------
    // Match the outstanding entry by ROB number. ROB qualification rejects
    // killed results; cache-side kills prevent responses to reused ROB slots.
    always_comb begin
        load_response_match = 1'b0;
        response_load_slot   = '0;
        if (resp_valid && !resp.is_store && !resp_replay) begin
            for (int i = 0; i < DQ; i = i + 1)
                if (l_valid[i] && (l_state[i] == LOAD_SENT) && (l_rob[i] == resp.rob)) begin
                    load_response_match = 1'b1;
                    response_load_slot   = i[LB-1:0];
                end
        end
    end
    // Store forwarding gets a WB register; D$ responses retain their early
    // path. This cuts STQ comparisons out of same-cycle IQ/BRU wakeup.
    wire fwd_capture = cur_fwd_ok && (!wb_hold_valid || wb_grant) && !flush_valid;
    wire wb_hold_kill = flush_valid &&
        cpu_pkg::flush_younger(wb_hold_rob, flush_rob, flush_dtail);
    assign cache_wb_valid = load_response_match;
    assign cache_wb_tag = load_response_match ? l_pdst[response_load_slot] : '0;
    assign cache_wb_rob = load_response_match ? l_rob[response_load_slot] : '0;
    assign cache_wb_data = load_response_match ?
        ldext(resp.rdata, l_f3[response_load_slot], l_addr[response_load_slot][1:0]) : 32'b0;

    always_ff @(posedge clock) begin
        if (reset) begin
            l_valid <= '0;
            s_valid <= '0; s_ret <= '0; s_drd <= '0; s_dvalid <= '0;
            wb_hold_valid <= 1'b0;
            sc_v <= 1'b0; st_v <= 1'b0;
            ret_seq_q <= '0;
        end else begin
            // ---- writeback hold ----
            if (fwd_capture) begin
                wb_hold_valid <= 1'b1;
                wb_hold_tag <= l_pdst[cur_i];
                wb_hold_rob <= l_rob[cur_i];
                wb_hold_data <= f_data[cur_i];
                l_valid[cur_i] <= 1'b0;
            end else if (hold_take) begin
                wb_hold_valid     <= 1'b1;
                wb_hold_tag  <= l_pdst[dsel];
                wb_hold_rob  <= l_rob[dsel];
                wb_hold_data <= l_data[dsel];
                l_valid[dsel] <= 1'b0;
            end else if (wb_grant) begin
                wb_hold_valid <= 1'b0;
            end

            // ---- issue / allocate ----
            if (in_fire && !is_store && !rd0) begin
                l_valid[lpos] <= 1'b1;
                l_state[lpos]    <= LOAD_WAIT;
                l_addr[lpos]  <= in_vaddr;
                l_f3[lpos]    <= in_funct3;
                l_rob[lpos]   <= in_rob;
                l_pdst[lpos]  <= in_pdst;
            end
            if (in_fire && is_store) begin
                s_valid[spos] <= 1'b1;
                s_ret[spos]   <= 1'b0;
                s_drd[spos]   <= 1'b0;
                s_addr[spos]  <= in_vaddr;
                s_mask[spos]  <= lanes(in_funct3, in_off);
                s_rob[spos]   <= in_rob;
                // data may still be in flight; record the producer tag and
                // readiness, and only materialise the value if it is valid now.
                s_f3[spos]     <= in_funct3;
                s_ps2[spos]    <= in_ps2;
                s_dvalid[spos] <= in_rs2_ready;
                s_data[spos]   <= in_rs2_ready ? stsh(in_store_data, in_funct3, in_off)
                                               : 32'b0;
            end

            // ---- late store-data fill from the qualified writeback bus ----
            // A store issued on address alone may still be waiting for its rs2
            // value; capture it when that producer writes back.
            if (wb_a.valid)
                for (int i = 0; i < SQ; i = i + 1)
                    if (s_valid[i] && !s_dvalid[i] && (s_ps2[i] == wb_a.prf_tag)) begin
                        s_data[i]   <= stsh(wb_a.result, s_f3[i], s_addr[i][1:0]);
                        s_dvalid[i] <= 1'b1;
                    end
            if (wb_b.valid)
                for (int i = 0; i < SQ; i = i + 1)
                    if (s_valid[i] && !s_dvalid[i] && (s_ps2[i] == wb_b.prf_tag)) begin
                        s_data[i]   <= stsh(wb_b.result, s_f3[i], s_addr[i][1:0]);
                        s_dvalid[i] <= 1'b1;
                    end

            // ---- store retirement pulses (stamp the retire order) ----
            if (cmt_valid[0])
                for (int i = 0; i < SQ; i = i + 1)
                    if (s_valid[i] && (s_rob[i] == cmt_rob0) && !s_ret[i]) begin
                        s_ret[i] <= 1'b1;
                        s_seq[i] <= ret_seq_q;
                    end
            if (cmt_valid[1])
                for (int i = 0; i < SQ; i = i + 1)
                    if (s_valid[i] && (s_rob[i] == cmt_rob1) && !s_ret[i]) begin
                        s_ret[i] <= 1'b1;
                        s_seq[i] <= ret_seq_q + SEQW'(1);
                    end
            // two commit slots retire per cycle at most: cmt1's store consumes
            // base+1, so the base must step by 2 whenever any store retired —
            // stepping by n_ret would alias seq values across cycles and tie
            // the drain/free pickers.
            ret_seq_q <= ret_seq_q + ((n_ret != 2'd0) ? SEQW'(2) : '0);

            // ---- drain candidate ----
            // A candidate is presented the same cycle it is picked; if memory_subsystem
            // accepts right away (st_ready), mark it drained immediately, else
            // latch it until accepted. Recording only via the latched path
            // would let memory_subsystem accept the same store twice (double drain).
            if (!st_v) begin
                if (drain_ok != '0) begin
                    if (st_ready) begin
                        s_drd[lowest_s(drain_ok)] <= 1'b1;
                    end else begin
                        st_v <= 1'b1;
                        st_i <= lowest_s(drain_ok);
                    end
                end
            end else if (st_ready) begin
                s_drd[st_i] <= 1'b1;
                st_v <= 1'b0;
            end

            // ---- load scheduler ----
            if (!sc_v) begin
                if (nsel_v) begin
                    if (f_fwd[nsel_i]) begin
                        // forwarded this cycle: release immediately, no latch
                        if (fwd_capture) l_valid[nsel_i] <= 1'b0;
                        else begin sc_v <= 1'b1; sc_i <= nsel_i; end
                    end else if (ld_ready) begin
                        // the D$ accepted the combinationally presented request
                        l_state[nsel_i] <= LOAD_SENT;
                    end else begin
                        sc_v <= 1'b1;
                        sc_i <= nsel_i;
                    end
                end
            end else if (cur_fwd) begin
                // Capture the forward in the WB hold and release its queue entry.
                if (fwd_capture) begin
                    l_valid[sc_i] <= 1'b0;
                    sc_v <= 1'b0;
                end
            end else if (ld_ready) begin
                l_state[sc_i] <= LOAD_SENT;
                sc_v <= 1'b0;
            end else if (!f_go[sc_i] && !f_fwd[sc_i]) begin
                // The candidate's decision is NOT monotone: its forward source
                // (an older store) can retire+complete between the latch and
                // the completion, leaving the entry blocked, while a younger
                // entry may be GO. Release the latch and re-pick next cycle.
                sc_v <= 1'b0;
            end

            // ---- responses ----
            if (resp_valid) begin
                if (resp.is_store) begin
                    // completions arrive in drain order: free the oldest drained
                    // (retired-only set: wrap-safe retire-stamp compare)
                    if (complete_pick[SB]) s_valid[complete_pick[SB-1:0]] <= 1'b0;
                end else if (resp_replay) begin
                    for (int i = 0; i < DQ; i = i + 1)
                        if (l_valid[i] && (l_state[i] == LOAD_SENT) && (l_rob[i] == resp.rob))
                            l_state[i] <= LOAD_WAIT;
                end else if (load_response_match) begin
                    // The response is presented on BB this cycle; release
                    // the outstanding entry now (exactly once).
                    if (l_valid[response_load_slot] && (l_state[response_load_slot] == LOAD_SENT) && (l_rob[response_load_slot] == resp.rob))
                        l_valid[response_load_slot] <= 1'b0;
                end else begin
                    for (int i = 0; i < DQ; i = i + 1)
                        if (l_valid[i] && (l_state[i] == LOAD_SENT) && (l_rob[i] == resp.rob)) begin
                            l_state[i]   <= LOAD_DONE;
                            l_data[i] <= ldext(resp.rdata, l_f3[i], l_addr[i][1:0]);
                        end
                end
            end

            if (wb_hold_kill) wb_hold_valid <= 1'b0;

            // ---- flush kills (loads always; stores only if not retired) ----
            if (flush_valid) begin
                for (int i = 0; i < DQ; i = i + 1)
                    if (l_valid[i] && cpu_pkg::flush_younger(l_rob[i], flush_rob, flush_dtail))
                        l_valid[i] <= 1'b0;
                for (int i = 0; i < SQ; i = i + 1)
                    if (s_valid[i] && !s_ret[i] &&
                        cpu_pkg::flush_younger(s_rob[i], flush_rob, flush_dtail))
                        s_valid[i] <= 1'b0;
                if (sc_v && cpu_pkg::flush_younger(l_rob[sc_i], flush_rob, flush_dtail))
                    sc_v <= 1'b0;
                if (st_v && cpu_pkg::flush_younger(s_rob[st_i], flush_rob, flush_dtail))
                    st_v <= 1'b0;
            end
        end
    end

endmodule
