// LSU A side (design.md §7.3/§7.4): owns the D$ (instantiates dcache), forwards
// load replay requests, drives store hit-updates + write-through drains into the
// AXI write path, and merges A-side responses back to lsu_b.
//
// Load requests are stateless here: ld_req is presented to the D$ lookup port
// and answered later by the D$ response FIFO (hit / keyword) or a replay event.
// Store drains run a small FSM per store: cache hit-update first (so any later
// cache hit is coherent), then wrQ push with a 4-bit identity tag; the B
// response for that tag becomes a store completion. Because the AXI B channel
// returns in write order, tags are looked up in a small table.
//
// Response arbitration: store completions have priority over load responses
// (load responses can wait in the D$ FIFO, B responses cannot be retracted).
module lsu_a (
    input  wire        clock,
    input  wire        reset,

    // flush broadcast (MSHR waiter kill; see dcache)
    input  wire        flush_valid,
    input  wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] flush_rob,
    input  wire [$clog2(cpu_pkg::ROB_DEPTH):0] flush_dtail,

    // ---- B side: load replay ----
    input  wire        ld_valid,
    input  cpu_pkg::mem_req_t ld_req,
    output wire        ld_ready,

    // ---- M9c: D$ tag probe for the same-line guard relaxation ----
    input  wire [31:0] probe_addr,
    output wire        probe_hit,

    // ---- B side: store drain ----
    input  wire        st_valid,
    input  cpu_pkg::mem_req_t st_req,
    output wire        st_ready,

    // ---- responses to B ----
    output wire        resp_valid,
    output cpu_pkg::mem_resp_t resp,
    output wire        resp_replay,

    // ---- AXI read push/response (src = MRF_DC set by top) ----
    output wire        rd_push_valid,
    output wire [31:0] rd_push_addr,
    output wire [4:0]  rd_push_idx,
    input  wire        rd_push_ready,
    input  wire        rd_rsp_valid,
    input  wire [4:0]  rd_rsp_idx,
    input  wire [31:0] rd_rsp_data,
    output wire        rd_rsp_ready,

    // ---- AXI write push/response ----
    output wire        wr_push_valid,
    output wire [31:0] wr_push_addr,
    output wire [31:0] wr_push_data,
    output wire [3:0]  wr_push_strb,
    output wire [3:0]  wr_push_tag,
    input  wire        wr_push_ready,
    input  wire        wr_rsp_valid,
    input  wire [3:0]  wr_rsp_tag,
);
    // ---------------- D$ ----------------
    localparam int RB = $clog2(cpu_pkg::ROB_DEPTH);
    wire        dc_lk_ready, dc_rsp_valid, dc_rsp_replay, dc_su_ready, dc_su_hit;
    wire [RB-1:0] dc_rsp_token;
    wire [31:0] dc_rsp_data;
    logic       inv_valid;
    logic [31:0] inv_addr;

    dcache u_dc (
        .clock, .reset,
        .lk_valid(ld_valid), .lk_addr(ld_req.addr), .lk_token(ld_req.rob),
        .lk_ready(dc_lk_ready),
        .probe_addr(probe_addr), .probe_hit(probe_hit),
        .rsp_valid(dc_rsp_valid), .rsp_token(dc_rsp_token), .rsp_data(dc_rsp_data),
        .rsp_replay(dc_rsp_replay), .rsp_ready(dc_rsp_sel_q),
        .su_valid(su_valid), .su_addr(su_addr), .su_data(su_data), .su_strb(su_strb),
        .su_ready(dc_su_ready), .su_hit(dc_su_hit),
        .inv_valid, .inv_addr,
        .flush_valid, .flush_rob, .flush_dtail,
        .rd_push_valid, .rd_push_addr, .rd_push_idx, .rd_push_ready,
        .rd_rsp_valid, .rd_rsp_idx, .rd_rsp_data, .rd_rsp_ready);

    assign ld_ready = dc_lk_ready;

    // ---------------- store drain (S3-5: single-cycle) ----------------
    // The D$ hit-update (su) and the AXI write push (wrQ) are independent
    // resources, so one store completes per cycle when both accept. Locking the
    // D$ update and the memory write to the same cycle (wr_push_valid gated by
    // the su side) keeps them atomic. This replaces the old IDLE/SU/PUSH
    // 3-cycle sequence that capped drain throughput at 1 store/3 cycles.
    logic [3:0]  seq_q;
    logic [RB-1:0] tagrob [0:15];
    logic [31:0] tagaddr [0:15];
    logic        tagmiss [0:15];
    logic        tw_v;
    logic [3:0]  tw_tag;
    logic [31:0] tw_addr;
    logic [RB-1:0] tw_rob;
    logic        tw_unc;

    wire cur_unc = cpu_pkg::is_uncached(st_req.addr);
    wire su_acc  = dc_su_ready || cur_unc;
    assign wr_push_valid = st_valid && su_acc;
    wire drain_go = wr_push_valid && wr_push_ready;
    assign st_ready = drain_go;

    wire su_valid = st_valid && !cur_unc;
    wire [31:0] su_addr  = st_req.addr;
    wire [31:0] su_data  = st_req.wdata;
    wire [3:0]  su_strb  = st_req.wstrb;

    // AXI writes must be word-aligned (the byte lanes travel in wstrb); the
    // raw byte address is kept for the D$ hit-update and tagaddr/invalidate.
    assign wr_push_addr  = {st_req.addr[31:2], 2'b00};
    assign wr_push_data  = st_req.wdata;
    assign wr_push_strb  = st_req.wstrb;
    assign wr_push_tag   = seq_q;

    // ---------------- response merge ----------------
    logic       sp_v;          // buffered store completion
    logic [RB-1:0] sp_rob;
    wire [RB-1:0] wr_rob = tagrob[wr_rsp_tag];

    // store-completion line invalidate: a drain that missed the D$ may have
    // been raced by a stale refill (the fill's AXI read can be serviced before
    // this store's write is applied), so drop the line when the write is
    // confirmed (B). A fill landing after the B is ordered after the applied
    // write and therefore fresh.
    always_comb begin
        inv_valid = wr_rsp_valid && tagmiss[wr_rsp_tag] &&
                    !cpu_pkg::is_uncached(tagaddr[wr_rsp_tag]);
        inv_addr  = tagaddr[wr_rsp_tag];
    end

    wire out_pend = sp_v;
    wire out_wr   = !sp_v && wr_rsp_valid;
    wire out_ld   = !sp_v && !wr_rsp_valid && dc_rsp_valid;
    wire dc_rsp_sel_q = out_ld;          // D$ FIFO drains only when selected

    always_comb begin
        resp = '0;
        resp.valid   = out_pend || out_wr || out_ld;
        resp.is_store = out_pend || out_wr;
        if (out_pend)      resp.rob   = sp_rob;
        else if (out_wr)   resp.rob   = wr_rob;
        else               resp.rob   = dc_rsp_token;
        resp.rdata = out_ld ? dc_rsp_data : 32'b0;
    end
    assign resp_valid  = resp.valid;
    assign resp_replay = out_ld && dc_rsp_replay;

    // ---------------- state ----------------
    always_ff @(posedge clock) begin
        if (reset) begin
            seq_q <= 4'd0;
            sp_v <= 1'b0;
            sp_rob <= 5'd0;
            tw_v <= 1'b0;
            tw_tag <= 4'd0;
            tw_addr <= 32'd0;
            tw_rob <= '0;
            tw_unc <= 1'b0;
        end else begin
            // store completion buffer: drains every cycle it is set; a B that
            // cannot be output this cycle (buffer occupied) replaces it
            if (wr_rsp_valid && sp_v) begin
                sp_v   <= 1'b1;
                sp_rob <= wr_rob;
            end else begin
                sp_v <= 1'b0;
            end

            if (tw_v) begin
                tagrob[tw_tag]  <= tw_rob;
                tagaddr[tw_tag] <= tw_addr;
                tagmiss[tw_tag] <= tw_unc ? 1'b1 : !dc_su_hit;
                tw_v <= 1'b0;
            end
            if (drain_go) begin
                tw_v    <= 1'b1;
                tw_tag  <= seq_q;
                tw_addr <= st_req.addr;
                tw_rob  <= st_req.rob;
                tw_unc  <= cur_unc;
                seq_q   <= seq_q + 4'd1;
            end
        end
    end
endmodule
