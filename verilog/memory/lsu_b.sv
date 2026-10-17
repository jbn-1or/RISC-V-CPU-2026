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
    localparam int DQ = cpu_pkg::LDQ_DEPTH;   // 8
    localparam int SQ = cpu_pkg::STQ_DEPTH;   // 8
    localparam int RB = $clog2(cpu_pkg::ROB_DEPTH);   // rob index bits
    localparam int PB = $clog2(cpu_pkg::PRF_NUM);     // physical tag bits

    // ---------------- address / mask helpers ----------------
    function automatic logic [3:0] lanes(input logic [2:0] f3, input logic [1:0] off);
        lanes = (f3 == 3'b010) ? 4'b1111 :
                ((f3 == 3'b001) || (f3 == 3'b101)) ? (off[1] ? 4'b1100 : 4'b0011) :
                                                     (4'b0001 << off);
    endfunction

    function automatic logic [31:0] ldext(input logic [31:0] d, input logic [2:0] f3,
                                          input logic [1:0] off);
        logic [31:0] bsel, hsel;
        bsel = d >> {off, 3'b000};
        hsel = d >> {off[1], 4'b0000};
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
               (f3 == 3'b001) ? (d << {off[1], 4'b0000}) :
                                (d << {off, 3'b000});
    endfunction

    function automatic logic [2:0] lowest(input logic [7:0] v);
        lowest = 3'd0;
        for (int i = 7; i >= 0; i = i - 1)
            if (v[i]) lowest = i[2:0];
    endfunction

    // ---------------- load queue ----------------
    logic [7:0]  l_valid;
    logic [1:0]  l_st [0:DQ-1];        // 0=WAIT 1=SENT 2=DONE
    logic [31:0] l_addr [0:DQ-1];
    logic [2:0]  l_f3   [0:DQ-1];
    logic [RB-1:0] l_rob  [0:DQ-1];
    logic [$clog2(cpu_pkg::PRF_NUM)-1:0] l_pdst [0:DQ-1];
    logic [31:0] l_data [0:DQ-1];

    // ---------------- store queue ----------------
    logic [7:0]  s_valid, s_ret, s_drd;
    logic [7:0]  s_dvalid;                 // M8: store data value present
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
    logic [2:0]  rsp_i;
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
    wire lf = (l_valid != 8'hff);
    wire sf = (s_valid != 8'hff);
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
    wire rd0 = is_load && (in_pdst == 6'd0);

    assign ndone_valid = in_fire && (is_store || rd0);
    assign ndone_rob   = in_rob;

    wire [2:0] lpos = lowest(~l_valid);
    wire [2:0] spos = lowest(~s_valid);

    wire [31:0] in_vaddr = in_base + in_imm;
    wire [1:0]  in_off   = in_vaddr[1:0];

    // ---------------- flush kill masks (same-cycle guard) ----------------
    // The latched candidates below are chosen combinationally; a flush in the
    // same cycle would kill the picked entry after the latch decision, leaving
    // a stale selector. Filter the latch predicates with these masks.
    logic [7:0] ld_kill_mask, st_kill_mask;
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
    // stamp (12-bit domain, gap-free per commit pulse) and live entries get
    // the 0x1000+domain with head-relative distance ahead; ascending key =
    // program order. The old 31-dist_behind scheme wrapped for a store that
    // stayed undrained >=32 retires behind the head, which made completion /
    // drain pick the wrong entry and left stale store data visible to
    // forwarding.
    logic [12:0] s_key [0:SQ-1];
    logic [12:0] l_key [0:DQ-1];
    logic [11:0] ret_seq_q;
    logic [11:0] s_seq   [0:SQ-1];
    always_comb begin
        for (int i = 0; i < SQ; i = i + 1)
            s_key[i] = s_ret[i] ? {1'b0, s_seq[i]}
                                : {1'b1, {(12-RB){1'b0}}, (s_rob[i] - rob_head)};
        for (int i = 0; i < DQ; i = i + 1)
            l_key[i] = {1'b1, {(12-RB){1'b0}}, (l_rob[i] - rob_head)};
    end

    // The 12-bit retire stamp wraps every 2048 retire cycles; a plain compare
    // of raw stamps would invert order for two entries straddling that wrap.
    // Retire order is modular-compared instead: "a older than b" iff the
    // forward distance b-a is under half the domain. Sound for any pair of
    // simultaneously live stamps (STQ depth 8, drains continuously: live stamp
    // distances are tiny compared to 2048). Retired-vs-live is decided by the
    // domain bit and never reaches this function.
    function automatic logic seq_older(input logic [11:0] a, input logic [11:0] b);
        logic [11:0] d;
        d = b - a;
        seq_older = (d != 12'd0) && (d < 12'd2048);
    endfunction

    // wrap-safe "a is newer than b" over the unified 13-bit program-order key
    // (bit 12 = live domain; live is always younger than retired).
    function automatic logic key_newer(input logic [12:0] a, input logic [12:0] b);
        if (a[12] != b[12])     key_newer = a[12];
        else if (a[12])         key_newer = (a[11:0] > b[11:0]);   // live: dist ahead
        else                    key_newer = seq_older(b[11:0], a[11:0]);
    endfunction

    // ---------------- STQ drain: oldest retired, not yet drained ------------
    logic [7:0] drain_mask;
    always_comb begin
        logic [11:0] best_seq;
        logic found;
        drain_mask = '0;
        best_seq = 12'd0;
        found = 1'b0;
        // M8: a store drains only once retired AND its data value is present.
        for (int i = 0; i < SQ; i = i + 1) begin
            if (s_valid[i] && s_ret[i] && !s_drd[i] && s_dvalid[i]) begin
                if (!found || seq_older(s_seq[i], best_seq)) begin
                    best_seq = s_seq[i];
                    found = 1'b1;
                end
            end
        end
        if (found) begin
            for (int i = 0; i < SQ; i = i + 1)
                if (s_valid[i] && s_ret[i] && !s_drd[i] && s_dvalid[i] &&
                    (s_seq[i] == best_seq))
                    drain_mask[i] = 1'b1;
        end
    end

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
    logic [2:0]  st_i;
    wire [7:0]  drain_ok = drain_mask & ~st_kill_mask;
    wire [7:0]  st_cand = st_v ? (8'd1 << st_i) : drain_ok;

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
    assign st_valid = (st_cand != 8'd0);

    // line mask derived from the single line-size knob (guard must follow it)
    wire [31:0] line_msk = ~(32'(cpu_pkg::LINE_BYTES) - 32'd1);

    // ---------------- load forwarding evaluation ----------------
    logic [7:0]  f_go, f_fwd;
    logic [7:0]  sl_any, blk_ov;   // per-load: older same-line store / overlap block
    logic [31:0] f_data [0:DQ-1];
    logic [2:0]  gs_i;             // oldest load blocked ONLY by the same-line guard
    logic        gs_v;
    assign probe_addr = l_addr[gs_i];
    always_comb begin
        logic [3:0] lm;
        logic gs_v_l;
        logic [12:0] gs_key;
        lm = 4'b0;
        f_go = '0; f_fwd = '0; sl_any = '0; blk_ov = '0;
        for (int i = 0; i < DQ; i = i + 1) f_data[i] = 32'b0;
        for (int i = 0; i < DQ; i = i + 1) begin
            if (l_valid[i] && (l_st[i] == 2'd0)) begin
                logic [3:0] blk;
                logic [12:0] best_key;
                logic [2:0] best;
                logic found;
                lm = lanes(l_f3[i], l_addr[i][1:0]);
                blk = 1'b0; best_key = 13'd0; best = 3'd0; found = 1'b0;
                for (int s = 0; s < SQ; s = s + 1) begin
                    if (s_valid[s]) begin
                        logic ov, sl, older;
                        older = (s_key[s] < l_key[i]);
                        ov = (s_addr[s][31:2] == l_addr[i][31:2]) && ((s_mask[s] & lm) != 4'd0);
                        sl = ((s_addr[s] & line_msk) == (l_addr[i] & line_msk));
                        if (older && sl) sl_any[i] = 1'b1;    // same-line older store
                        if (older && ov && (!found || key_newer(s_key[s], best_key))) begin
                            best_key = s_key[s];
                            best = s[2:0];
                            found = 1'b1;
                        end
                    end
                end
                if (found) begin
                    // M8: forward only from a store whose data has landed;
                    // otherwise the overlap is unresolved and the load blocks
                    // (§7.2 rule 2), exactly as for a not-yet-completed store.
                    if (((s_mask[best] & lm) == lm) && s_dvalid[best]) begin
                        f_fwd[i] = 1'b1;
                        f_data[i] = ldext(s_data[best], l_f3[i], l_addr[i][1:0]);
                    end else begin
                        blk = 1'b1;
                    end
                end
                blk_ov[i] = blk;
                // base GO: neither an overlap block nor a same-line older store
                if (!f_fwd[i] && !blk && !sl_any[i]) f_go[i] = 1'b1;
            end
        end
        // M9c: relax the same-line guard for the oldest load blocked ONLY by it
        // when the D$ probe says its line currently hits (a hit never allocates,
        // so the stale-fill race cannot occur).
        gs_v_l = 1'b0; gs_i = 3'd0; gs_key = 13'h1fff;
        for (int i = 0; i < DQ; i = i + 1) begin
            if (l_valid[i] && (l_st[i] == 2'd0) && sl_any[i] && !blk_ov[i] &&
                !f_fwd[i] && !ld_kill_mask[i] &&
                (!gs_v_l || (l_key[i] < gs_key))) begin
                gs_v_l = 1'b1; gs_i = i[2:0]; gs_key = l_key[i];
            end
        end
        gs_v = gs_v_l;
        if (gs_v_l && probe_hit) f_go[gs_i] = 1'b1;
    end

    // ---------------- load scheduler ----------------
    // A newly eligible (not yet latched) load is presented to the D$ port in the
    // same cycle it is picked; if the port accepts immediately the entry goes
    // SENT with no latch (removing the mandatory select->present cycle). Only
    // when the port is busy is the candidate latched, and the latched payload
    // then stays stable until accepted. Store-forward completions do not use the
    // memory port, so they also finish in the pick cycle.
    logic       sc_v;
    logic [2:0] sc_i;
    logic       nsel_v;
    logic [2:0] nsel_i;
    wire [2:0]  cur_i   = sc_v ? sc_i : nsel_i;
    wire        cur_v   = sc_v || nsel_v;
    wire        cur_go  = cur_v && f_go[cur_i];
    wire        cur_fwd = cur_v && f_fwd[cur_i];
    wire        cur_fwd_ok = cur_fwd && !ld_kill_mask[cur_i];

    always_comb begin
        logic best_found;
        logic [12:0] best_age;
        logic [2:0] best;
        best_age = 13'd8191; best = 3'd0; best_found = 1'b0;
        for (int i = 0; i < DQ; i = i + 1) begin
            if (l_valid[i] && (l_st[i] == 2'd0) && (f_go[i] || f_fwd[i]) &&
                !ld_kill_mask[i]) begin
                if (!best_found || (l_key[i] < best_age)) begin
                    best_age = l_key[i]; best = i[2:0]; best_found = 1'b1;
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
    logic [7:0] done_mask;
    wire [2:0] dsel;
    logic [12:0] dbest;
    always_comb begin
        logic found;
        done_mask = '0;
        dbest = 13'd8191;
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
    assign dsel = lowest(done_mask);
    wire have_done = (done_mask != 8'd0);
    wire hold_take = have_done && (!wb_hv || wb_grant);

    // ---------------- M8a early writeback selection ----------------
    // A D$ load response is matched to its outstanding (SENT) queue entry by
    // rob number; the byte extraction is the same ldext used on the normal
    // path. A store forward completes the latched WAIT candidate directly. Kill
    // filtering is unchanged (the ROB drops a wrong-path writeback to a
    // reclaim); the entry itself is released the same cycle, exactly once.
    always_comb begin
        rsp_hit = 1'b0;
        rsp_i   = 3'd0;
        if (resp_valid && !resp.is_store && !resp_replay) begin
            for (int i = 0; i < DQ; i = i + 1)
                if (l_valid[i] && (l_st[i] == 2'd1) && (l_rob[i] == resp.rob)) begin
                    rsp_hit = 1'b1;
                    rsp_i   = i[2:0];
                end
        end
    end
    assign fwd_early = cur_fwd_ok;
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
            if (hold_take) begin
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
                        s_seq[i] <= ret_seq_q + 12'd1;
                    end
            // two commit slots retire per cycle at most: cmt1's store consumes
            // base+1, so the base must step by 2 whenever any store retired —
            // stepping by n_ret would alias seq values across cycles and tie
            // the drain/free pickers.
            ret_seq_q <= ret_seq_q + ((n_ret != 2'd0) ? 12'd2 : 12'd0);

            // ---- drain candidate ----
            // A candidate is presented the same cycle it is picked; if lsu_a
            // accepts right away (st_ready), mark it drained immediately, else
            // latch it until accepted. Recording only via the latched path
            // would let lsu_a accept the same store twice (double drain).
            if (!st_v) begin
                if (drain_ok != 8'd0) begin
                    if (st_ready) begin
                        s_drd[lowest(drain_ok)] <= 1'b1;
                    end else begin
                        st_v <= 1'b1;
                        st_i <= lowest(drain_ok);
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
                        if (!ld_kill_mask[nsel_i]) l_valid[nsel_i] <= 1'b0;
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
                if (cur_fwd_ok) l_valid[sc_i] <= 1'b0;
                sc_v <= 1'b0;
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
                    logic found_d;
                    logic [11:0] best_seq2;
                    logic [2:0] best2;
                    found_d = 1'b0; best_seq2 = 12'd0; best2 = 3'd0;
                    for (int i = 0; i < SQ; i = i + 1) begin
                        if (s_valid[i] && s_drd[i]) begin
                            if (!found_d || seq_older(s_seq[i], best_seq2)) begin
                                best_seq2 = s_seq[i]; best2 = i[2:0]; found_d = 1'b1;
                            end
                        end
                    end
                    if (found_d) s_valid[best2] <= 1'b0;
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
