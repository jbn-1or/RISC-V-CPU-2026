// LSU B side (design.md §7.1/§7.2): AGU, load queue, store queue, load-store
// forwarding and blocking, replay scheduling, retire-gated store drain.
//
// Loads: allocated at issue (AGU computes the address). Each cycle the oldest
// WAIT entry whose forwarding decision says "go" is selected, latched and
// presented to the A side (lsu_a) as a mem_req_t; the A side answers exactly
// once per accepted request (data or "replay", the latter returns the entry to
// WAIT). A load whose byte range is fully covered by the newest older
// overlapping store completes directly from that store's wdata without any
// memory access. Partial overlap, or a same-line older store (stale-line
// allocation guard), blocks until those stores complete.
//
// Stores: allocated at issue with the §8.2 byte-lane mask; the ROB entry is
// marked done at AGU (early retire, design §6.2.2). A store may only drain to
// AXI after the ROB commits it (retirement pulse), so a wrong-path store can
// never reach memory. Drain selection is oldest-first; completions (B
// responses) pop the oldest drained entry, which frees it.
//
// Age compares use ROB ring ages relative to rob_head; all live entries span
// less than ROB_DEPTH, so unsigned age order equals program order.
module lsu_b (
    input  wire        clock,
    input  wire        reset,

    // ---- issue (from core, program order) ----
    input  wire        in_valid,
    input  wire cpu_pkg::op_e in_op,
    input  wire [2:0]  in_funct3,
    input  wire [31:0] in_base,
    input  wire [31:0] in_imm,
    input  wire [31:0] in_store_data,
    input  wire [$clog2(cpu_pkg::PRF_NUM)-1:0] in_pdst,
    input  wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] in_rob,
    // M8 (§16.4): store data operand tag + whether its value is valid now.
    // If not valid, the STQ captures it later from the writeback-bus CAM.
    input  wire [$clog2(cpu_pkg::PRF_NUM)-1:0] in_ps2,
    input  wire        in_rs2_ready,
    // M8: qualified writeback bus (BA/BB) used only to fill pending store data.
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

    // ---- memory channels to the A side ----
    output wire        ld_valid,
    output cpu_pkg::mem_req_t ld_req,
    input  wire        ld_ready,
    output wire        st_valid,
    output cpu_pkg::mem_req_t st_req,
    input  wire        st_ready,

    // ---- responses from the A side ----
    input  wire        resp_valid,
    input  cpu_pkg::mem_resp_t resp,
    input  wire        resp_replay,

    // ---- M9c: D$ tag probe for the same-line guard relaxation ----
    output wire [31:0] probe_addr,
    input  wire        probe_hit,
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
    logic [1:0]  l_st [0:DQ-1];        // 0=WAIT 1=SENT 2=DONE
    logic [31:0] l_addr [0:DQ-1];
    logic [2:0]  l_f3   [0:DQ-1];
    logic [RB-1:0] l_rob  [0:DQ-1];
    logic [$clog2(cpu_pkg::PRF_NUM)-1:0] l_pdst [0:DQ-1];
    logic [31:0] l_data [0:DQ-1];

    // ---------------- store queue ----------------
    logic [SQ-1:0] s_valid, s_ret, s_drd;
    logic [SQ-1:0] s_dvalid;                 // M8: store data value present
    logic [31:0] s_addr [0:SQ-1];
    logic [31:0] s_data [0:SQ-1];
    logic [3:0]  s_mask [0:SQ-1];
    logic [RB-1:0] s_rob  [0:SQ-1];
    logic [2:0]  s_f3   [0:SQ-1];          // M8: width/sign for late data fill
    logic [$clog2(cpu_pkg::PRF_NUM)-1:0] s_ps2 [0:SQ-1];  // M8: data producer tag

    // ---------------- writeback hold ----------------
    logic        wb_hv;
    logic [PB-1:0] wb_h_tag;
    logic [RB-1:0] wb_h_rob;
    logic [31:0] wb_h_data;

    // M8a early writeback: a load completing THIS cycle (D$ response or store
    // forward) is driven combinationally onto the BB result bus, so a
    // dependent consumer can issue with WB_BYPASS in the same cycle and the 2
    // cycles of the wb_hv hold stage are removed. wb_hv remains the fallback
    // for a same-cycle dual completion (only one result can leave per cycle).
    // Priority on BB: early-LSU > hold-LSU > MUL > ALU1 (see core_ooo).
    logic        early_v;
    logic [PB-1:0] early_tag;
    logic [RB-1:0] early_rob;
    logic [31:0] early_data;
    logic        rsp_hit;
    logic [LB-1:0]  rsp_i;
    logic        fwd_early;
    logic        rsp_do_early;

    assign wb_valid = early_v || wb_hv;
    assign wb_tag   = early_v ? early_tag : wb_h_tag;
    assign wb_rob   = early_v ? early_rob : wb_h_rob;
    assign wb_data  = early_v ? early_data : wb_h_data;
    // The hold entry leaves the bus only when it is the one being presented;
    // when the early path wins, wb_hv must be retained (not dropped).
    wire wb_grant = wb_hv && !early_v && wb_ready;

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
    // In-order commit makes every retired store older than every live entry,
    // but a retired store that is still draining sits BEHIND rob_head, so a
    // plain head-relative age compares wrong against it (an older store can
    // look younger). Key: retired entries carry a monotonic retire-sequence
    // stamp (SEQW-bit domain, gap-free per commit pulse) and live entries get
    // the live domain with head-relative distance ahead; ascending key =
    // program order. The old 31-dist_behind scheme wrapped for a store that
    // stayed undrained >=32 retires behind the head, which made completion /
    // drain pick the wrong entry and left stale store data visible to
    // forwarding.
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
    // simultaneously live stamps (STQ depth 8, drains continuously: live stamp
    // distances are tiny compared to 2048). Retired-vs-live is decided by the
    // domain bit and never reaches this function.
    function automatic logic seq_older(input logic [SEQW-1:0] a, input logic [SEQW-1:0] b);
        logic [SEQW-1:0] d;
        d = b - a;
        seq_older = (d != '0) && !d[SEQW-1];
    endfunction

    // wrap-safe "a is newer than b" over the unified 13-bit program-order key
    // (bit 12 = live domain; live is always younger than retired).
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
            if (l_valid[i] && l_st[i] == 0) begin
                sl_any[i] = |sl_mask;
                f_fwd[i] = tv[1] && ((s_mask[best] & lm) == lm) && s_dvalid[best];
                blk_ov[i] = tv[1] && !f_fwd[i];
                f_go[i] = !tv[1] && !(|sl_mask);
            end
        end
    end

    // M9c guard relaxation index: the oldest load blocked ONLY by the same-line
    // guard. Computed in its own block that does NOT read probe_hit, so gs_i
    // cannot feed back through probe_addr -> probe_hit. That feedback was a
    // circular-combinational path (signal gs_i) that made ABC synthesis
    // explode from minutes to >20 min.
    always_comb begin
        logic gs_v_l;
        logic [K:0] gs_key;
        gs_v_l = 1'b0; gs_i = '0; gs_key = '1;
        for (int i = 0; i < DQ; i = i + 1) begin
            if (l_valid[i] && (l_st[i] == 2'd0) && sl_any[i] && !blk_ov[i] &&
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
        if (gs_v && probe_hit) f_go_r[gs_i] = 1'b1;
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
            if (l_valid[i] && (l_st[i] == 2'd0) && (f_go_r[i] || f_fwd[i]) &&
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
            if (l_valid[i] && (l_st[i] == 2'd2)) begin
                if (!found || (l_key[i] < dbest)) begin
                    dbest = l_key[i];
                    found = 1'b1;
                end
            end
        end
        if (found) begin
            for (int i = 0; i < DQ; i = i + 1)
                if (l_valid[i] && (l_st[i] == 2'd2) && (l_key[i] == dbest))
                    done_mask[i] = 1'b1;
        end
    end
    assign dsel = lowest_l(done_mask);
    wire have_done = (done_mask != '0);
    wire hold_take = have_done && (!wb_hv || wb_grant) && !flush_valid;

    // ---------------- M8a early writeback selection ----------------
    // A D$ load response is matched to its outstanding (SENT) queue entry by
    // rob number; the byte extraction is the same ldext used on the normal
    // path. A store forward completes the latched WAIT candidate directly. Kill
    // filtering is unchanged (the ROB drops a wrong-path writeback to a
    // reclaim); the entry itself is released the same cycle, exactly once.
    always_comb begin
        rsp_hit = 1'b0;
        rsp_i   = '0;
        if (resp_valid && !resp.is_store && !resp_replay) begin
            for (int i = 0; i < DQ; i = i + 1)
                if (l_valid[i] && (l_st[i] == 2'd1) && (l_rob[i] == resp.rob)) begin
                    rsp_hit = 1'b1;
                    rsp_i   = i[LB-1:0];
                end
        end
    end
    // Store forwarding gets a WB register; D$ responses retain their early
    // path. This cuts STQ comparisons out of same-cycle IQ/BRU wakeup.
    assign fwd_early = 1'b0;
    wire fwd_capture = cur_fwd_ok && (!wb_hv || wb_grant) && !flush_valid;
    wire wb_hold_kill = flush_valid &&
        cpu_pkg::flush_younger(wb_h_rob, flush_rob, flush_dtail);
    always_comb begin
        early_v    = 1'b0;
        early_tag  = '0;
        early_rob  = '0;
        early_data = 32'b0;
        if (fwd_early) begin
            early_v    = 1'b1;
            early_tag  = l_pdst[cur_i];
            early_rob  = l_rob[cur_i];
            early_data = f_data[cur_i];
        end else if (rsp_hit) begin
            early_v    = 1'b1;
            early_tag  = l_pdst[rsp_i];
            early_rob  = l_rob[rsp_i];
            early_data = ldext(resp.rdata, l_f3[rsp_i], l_addr[rsp_i][1:0]);
        end
    end
    // the response entry is released early only when it is the one presented
    // on BB this cycle (a coincident store forward takes priority).
    assign rsp_do_early = rsp_hit && !fwd_early;


    always_ff @(posedge clock) begin
        if (reset) begin
            l_valid <= '0;
            s_valid <= '0; s_ret <= '0; s_drd <= '0; s_dvalid <= '0;
            wb_hv <= 1'b0;
            sc_v <= 1'b0; st_v <= 1'b0;
            ret_seq_q <= '0;
        end else begin
            // ---- writeback hold ----
            if (fwd_capture) begin
                wb_hv <= 1'b1;
                wb_h_tag <= l_pdst[cur_i];
                wb_h_rob <= l_rob[cur_i];
                wb_h_data <= f_data[cur_i];
                l_valid[cur_i] <= 1'b0;
            end else if (hold_take) begin
                wb_hv     <= 1'b1;
                wb_h_tag  <= l_pdst[dsel];
                wb_h_rob  <= l_rob[dsel];
                wb_h_data <= l_data[dsel];
                l_valid[dsel] <= 1'b0;
            end else if (wb_grant) begin
                wb_hv <= 1'b0;
            end

            // ---- issue / allocate ----
            if (in_fire && !is_store && !rd0) begin
                l_valid[lpos] <= 1'b1;
                l_st[lpos]    <= 2'd0;
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
                // M8: data may still be in flight; record the producer tag and
                // readiness, and only materialise the value if it is valid now.
                s_f3[spos]     <= in_funct3;
                s_ps2[spos]    <= in_ps2;
                s_dvalid[spos] <= in_rs2_ready;
                s_data[spos]   <= in_rs2_ready ? stsh(in_store_data, in_funct3, in_off)
                                               : 32'b0;
            end

            // ---- M8: late store-data fill from the qualified writeback bus ----
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
            // A candidate is presented the same cycle it is picked; if lsu_a
            // accepts right away (st_ready), mark it drained immediately, else
            // latch it until accepted. Recording only via the latched path
            // would let lsu_a accept the same store twice (double drain).
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
                        l_st[nsel_i] <= 2'd1;
                    end else begin
                        sc_v <= 1'b1;
                        sc_i <= nsel_i;
                    end
                end
            end else if (cur_fwd) begin
                // M8a: a forwarding completion leaves on BB this cycle; release
                // the queue entry now (exactly once) instead of parking it DONE.
                if (fwd_capture) begin
                    l_valid[sc_i] <= 1'b0;
                    sc_v <= 1'b0;
                end
            end else if (ld_ready) begin
                l_st[sc_i] <= 2'd1;
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
                        if (l_valid[i] && (l_st[i] == 2'd1) && (l_rob[i] == resp.rob))
                            l_st[i] <= 2'd0;
                end else if (rsp_do_early) begin
                    // M8a: the response is presented on BB this cycle; release
                    // the outstanding entry now (exactly once).
                    if (l_valid[rsp_i] && (l_st[rsp_i] == 2'd1) && (l_rob[rsp_i] == resp.rob))
                        l_valid[rsp_i] <= 1'b0;
                end else begin
                    for (int i = 0; i < DQ; i = i + 1)
                        if (l_valid[i] && (l_st[i] == 2'd1) && (l_rob[i] == resp.rob)) begin
                            l_st[i]   <= 2'd2;
                            l_data[i] <= ldext(resp.rdata, l_f3[i], l_addr[i][1:0]);
                        end
                end
            end

            if (wb_hold_kill) wb_hv <= 1'b0;

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
