// Cache/AXI integration: load lookups, atomic store drains and response merge.
//
// A cached store is accepted only when both the D$ update and AXI write queue
// can accept it. Uncached stores use only AXI. The cache hit result arrives one
// cycle later and is recorded with the write tag; a missed store invalidates
// its set when AXI B returns to prevent a concurrent fill from leaving stale data.
//
// Response priority: buffered store completion > current AXI B > D$ load.
// Store completions cannot be backpressured; load responses wait in the D$ FIFO.
module memory_subsystem (
    input  wire        clock,
    input  wire        reset,

    // flush broadcast (MSHR waiter kill; see dcache)
    input  wire        flush_valid,
    input  wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] flush_rob,
    input  wire [$clog2(cpu_pkg::ROB_DEPTH):0] flush_dtail,

    // ---- load queue: lookup/retry ----
    input  wire        ld_valid,
    input  cpu_pkg::mem_req_t ld_req,
    output wire        ld_ready,

    // ---- D$ set-valid probe for the same-line guard relaxation ----
    input  wire [31:0] probe_addr,
    output wire        probe_set_valid,

    // ---- store queue: retired store drain ----
    input  wire        st_valid,
    input  cpu_pkg::mem_req_t st_req,
    output wire        st_ready,

    // ---- responses to load/store queue ----
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
    wire        dc_lk_ready, dc_rsp_valid, dc_rsp_replay, dc_su_ready, dc_su_hit, dc_su_stall;
    wire [RB-1:0] dc_rsp_token;
    wire [31:0] dc_rsp_data;
    logic       inv_valid;
    logic [31:0] inv_addr;

    dcache u_dc (
        .clock, .reset,
        .lk_valid(ld_valid), .lk_addr(ld_req.addr), .lk_token(ld_req.rob),
        .lk_ready(dc_lk_ready),
        .probe_addr(probe_addr), .probe_set_valid(probe_set_valid),
        .rsp_valid(dc_rsp_valid), .rsp_token(dc_rsp_token), .rsp_data(dc_rsp_data),
        .rsp_replay(dc_rsp_replay), .rsp_ready(dc_response_take),
        .su_valid(su_valid), .su_addr(su_addr), .su_data(su_data), .su_strb(su_strb),
        .su_ready(dc_su_ready), .su_hit(dc_su_hit), .su_stall(dc_su_stall),
        .inv_valid, .inv_addr,
        .flush_valid, .flush_rob, .flush_dtail,
        .rd_push_valid, .rd_push_addr, .rd_push_idx, .rd_push_ready,
        .rd_rsp_valid, .rd_rsp_idx, .rd_rsp_data, .rd_rsp_ready);

    assign ld_ready = dc_lk_ready;

    // ---------------- store drain (atomic cache update and AXI enqueue) ----------------
    // The D$ hit-update (su) and the AXI write push (wrQ) are independent
    // resources, so one store drains per cycle when both accept. Locking the
    // D$ update and the memory write to the same cycle (wr_push_valid gated by
    // the su side) keeps them atomic. Completion is reported later, on AXI B.
    logic [3:0]  seq_q;
    logic [RB-1:0] tagrob [0:15];
    logic [31:0] tagaddr [0:15];
    logic        tagmiss [0:15];
    // Cache hit/miss is available one cycle after drain acceptance. These
    // registers carry the accepted store identity alongside that cache stage.
    logic        tw_v;
    logic [3:0]  tw_tag;
    logic [31:0] tw_addr;
    logic [RB-1:0] tw_rob;
    logic        tw_unc;

    wire cur_unc = cpu_pkg::is_uncached(st_req.addr);
    // The D$ hit-update and the AXI write push must be accepted together: the
    // tagmiss captured for the store is read from the D$ one cycle later, so a
    // D$ update that the AXI queue did not accept would desynchronise the tag
    // table. Gate the D$ update on wr_push_ready as well.
    wire su_acc  = (dc_su_ready && wr_push_ready && !dc_su_stall) || cur_unc;
    assign wr_push_valid = st_valid && su_acc;
    wire drain_go = wr_push_valid && wr_push_ready;
    assign st_ready = drain_go;

    wire su_valid = st_valid && !cur_unc && wr_push_ready && !dc_su_stall;
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
    wire dc_response_take = out_ld;          // D$ FIFO drains only when selected

    always_comb begin
        resp = '0;
        resp.valid   = out_pend || out_wr || out_ld;
        resp.is_store = out_pend || out_wr;
        if (out_pend)      resp.rob   = sp_rob;
        else if (out_wr)   resp.rob   = wr_rob;
        else               resp.rob   = dc_rsp_token;
        // The data payload is consumed only for a valid load response.
        resp.rdata = dc_rsp_data;
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
