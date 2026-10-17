// student_top: AXI4-Lite master + M3 out-of-order core. Frontend (fetch_unit
// with icache/BP + decode) and the A-side memory subsystem (lsu_a with the
// dcache inside) live here; the backend (core_ooo with lsu_b) owns LDQ/STQ.
// No functional logic: pure interconnect plus the read-push arbitration
// (D$ refills/bypass reads > I$ refills) and read-response routing by source.
module student_top (
    input  wire        clock,
    input  wire        reset,

    output wire [31:0] araddr,
    output wire        arvalid,
    input  wire        arready,

    input  wire [31:0] rdata,
    input  wire [1:0]  rresp,
    input  wire        rvalid,
    output wire        rready,

    output wire [31:0] awaddr,
    output wire        awvalid,
    input  wire        awready,

    output wire [31:0] wdata,
    output wire [3:0]  wstrb,
    output wire        wvalid,
    input  wire        wready,

    // B-channel response: required by the AXI4-Lite interface template; write
    // errors are intentionally ignored (design §7.6), so it is not consumed.
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [1:0]  bresp,
    /* verilator lint_on UNUSEDSIGNAL */
    input  wire        bvalid,
    output wire        bready
);
    // ---------------- frontend decode interface ----------------
    wire [63:0] fu_dec_pc, fu_dec_raw;
    wire [1:0]  fu_dec_valid;
    cpu_pkg::decoded_t dec_d0, dec_d1;
    wire [1:0]  dec_ov;


    wire [1:0]       fe_valid, fe_take;
    cpu_pkg::fe2rn_t fe0, fe1;
    cpu_pkg::flush_t flush;
    wire             br_upd_valid, br_upd_taken, br_upd_mispred;
    wire [31:0]      br_upd_pc;
    wire [$clog2(cpu_pkg::BHT_ENTRIES)-1:0] br_upd_ix;
    wire             btb_upd_valid;
    wire [31:0]      btb_upd_pc, btb_upd_target;

    // M8b: combinational early redirect (BRU resolve cycle) -> frontend.
    // The frontend's flush is advanced one cycle (the backend still receives
    // the registered `flush`), so the PC restarts at the correct target one
    // cycle earlier while the ROB/IQ/LSU kill protocol is unchanged.
    wire             co_redir_valid;
    wire [31:0]      co_redir_pc;
    wire [5:0]       co_redir_bsf;

    cpu_pkg::flush_t fe_flush;
    always_comb begin
        fe_flush       = flush;
        fe_flush.valid = co_redir_valid;
        fe_flush.pc    = co_redir_pc;
        fe_flush.bsf   = co_redir_bsf;
    end

    decode u_dec (
        .in_valid_s(fu_dec_valid), .in_pc_s(fu_dec_pc), .in_raw_s(fu_dec_raw),
        .out_d0(dec_d0), .out_d1(dec_d1), .out_valid(dec_ov));

    // ---------------- fetch unit read-push/rsp ----------------
    wire        fu_rd_v, fu_rd_ready;
    wire [31:0] fu_rd_addr;
    wire [4:0]  fu_rd_idx;
    wire        fu_rsp_valid, fu_rsp_ready;
    wire [4:0]  fu_rsp_idx;
    wire [31:0] fu_rsp_data;

    fetch_unit u_fe (
        .clock, .reset, .flush(fe_flush),
        .dec_pc_s(fu_dec_pc), .dec_raw_s(fu_dec_raw), .dec_valid_s(fu_dec_valid),
        .dec_out_valid(dec_ov), .dec_d0(dec_d0), .dec_d1(dec_d1),
        .fe_valid, .fe0, .fe1, .fe_take,
        .br_upd_valid, .br_upd_pc, .br_upd_taken, .br_upd_ix, .br_upd_mispred,
        .btb_upd_valid, .btb_upd_pc, .btb_upd_target,
        .rd_push_valid(fu_rd_v), .rd_push_addr(fu_rd_addr), .rd_push_idx(fu_rd_idx),
        .rd_push_ready(fu_rd_ready),
        .rd_rsp_valid(fu_rsp_valid), .rd_rsp_idx(fu_rsp_idx),
        .rd_rsp_data(fu_rsp_data), .rd_rsp_ready(fu_rsp_ready));

    // ---------------- core (B side) ----------------
    wire             co_ld_valid, co_ld_ready;
    wire             co_st_valid, co_st_ready;
    wire             co_resp_valid, co_resp_replay;
    cpu_pkg::mem_req_t  co_ld_req, co_st_req;
    cpu_pkg::mem_resp_t co_resp;
    wire [$clog2(cpu_pkg::ROB_DEPTH):0] co_flush_dtail;

    core_ooo u_core (
        .clock, .reset,
        .fe_valid, .fe0, .fe1, .fe_take, .flush_out(flush),
        .flush_dtail_out(co_flush_dtail),
        .redir_valid(co_redir_valid), .redir_pc(co_redir_pc), .redir_bsf(co_redir_bsf),
        .br_upd_valid, .br_upd_pc, .br_upd_taken, .br_upd_ix, .br_upd_mispred,
        .btb_upd_valid, .btb_upd_pc, .btb_upd_target,
        .ld_valid(co_ld_valid), .ld_req(co_ld_req), .ld_ready(co_ld_ready),
        .st_valid(co_st_valid), .st_req(co_st_req), .st_ready(co_st_ready),
        .resp_valid(co_resp_valid), .resp(co_resp), .resp_replay(co_resp_replay),
        .probe_addr(dc_probe_addr), .probe_hit(dc_probe_hit));

    // ---------------- A-side memory subsystem: lsu_a + dcache ----------------
    wire        la_rd_v, la_rd_ready, la_rd_rsp_valid, la_rd_rsp_ready;
    wire [31:0] la_rd_addr, la_rd_rsp_data;
    wire [4:0]  la_rd_idx, la_rd_rsp_idx;
    wire        la_wr_v, la_wr_ready, la_wr_rsp_valid;
    wire [31:0] la_wr_addr, la_wr_data;
    wire [3:0]  la_wr_strb, la_wr_tag, la_wr_rsp_tag;

    // M9c: D$ tag probe (lsu_b -> lsu_a/dcache) for same-line guard relaxation
    wire [31:0] dc_probe_addr;
    wire        dc_probe_hit;

    lsu_a u_lsa (
        .clock, .reset,
        .flush_valid(flush.valid), .flush_rob(flush.rob), .flush_dtail(co_flush_dtail),
        .ld_valid(co_ld_valid), .ld_req(co_ld_req), .ld_ready(co_ld_ready),
        .probe_addr(dc_probe_addr), .probe_hit(dc_probe_hit),
        .st_valid(co_st_valid), .st_req(co_st_req), .st_ready(co_st_ready),
        .resp_valid(co_resp_valid), .resp(co_resp), .resp_replay(co_resp_replay),
        .rd_push_valid(la_rd_v), .rd_push_addr(la_rd_addr), .rd_push_idx(la_rd_idx),
        .rd_push_ready(la_rd_ready),
        .rd_rsp_valid(la_rd_rsp_valid), .rd_rsp_idx(la_rd_rsp_idx),
        .rd_rsp_data(la_rd_rsp_data), .rd_rsp_ready(la_rd_rsp_ready),
        .wr_push_valid(la_wr_v), .wr_push_addr(la_wr_addr), .wr_push_data(la_wr_data),
        .wr_push_strb(la_wr_strb), .wr_push_tag(la_wr_tag), .wr_push_ready(la_wr_ready),
        .wr_rsp_valid(la_wr_rsp_valid), .wr_rsp_tag(la_wr_rsp_tag));

    // ---------------- AXI read-push arbitration (D$ > I$) ----------------
    wire           ax_rd_v, ax_rd_ready;
    wire [31:0]    ax_rd_addr;
    wire [4:0]     ax_rd_idx;
    cpu_pkg::mrf_e ax_rd_src;

    assign ax_rd_v     = la_rd_v || fu_rd_v;
    assign ax_rd_addr  = la_rd_v ? la_rd_addr : fu_rd_addr;
    assign ax_rd_idx   = la_rd_v ? la_rd_idx  : fu_rd_idx;
    assign ax_rd_src   = la_rd_v ? cpu_pkg::MRF_DC : cpu_pkg::MRF_IC;
    assign la_rd_ready = ax_rd_ready;
    assign fu_rd_ready = !la_rd_v && ax_rd_ready;

    // ---------------- AXI master ----------------
    wire        ax_rsp_valid, ax_rsp_ready;
    wire [1:0]  ax_rsp_src;
    wire [4:0]  ax_rsp_idx;
    wire [31:0] ax_rsp_data;

    axi_master u_axi (
        .clock, .reset,
        .rd_push_valid(ax_rd_v), .rd_push_addr(ax_rd_addr),
        .rd_push_src(ax_rd_src), .rd_push_idx(ax_rd_idx), .rd_push_ready(ax_rd_ready),
        .rd_rsp_valid(ax_rsp_valid), .rd_rsp_src(ax_rsp_src), .rd_rsp_idx(ax_rsp_idx),
        .rd_rsp_err(), .rd_rsp_data(ax_rsp_data), .rd_rsp_ready(ax_rsp_ready),
        .wr_push_valid(la_wr_v), .wr_push_addr(la_wr_addr), .wr_push_data(la_wr_data),
        .wr_push_strb(la_wr_strb), .wr_push_tag(la_wr_tag), .wr_push_ready(la_wr_ready),
        .wr_rsp_valid(la_wr_rsp_valid), .wr_rsp_tag(la_wr_rsp_tag),
        .araddr, .arvalid, .arready,
        .rdata, .rresp, .rvalid, .rready,
        .awaddr, .awvalid, .awready,
        .wdata, .wstrb, .wvalid, .wready,
        .bvalid, .bready);

    // ---------------- read-response routing by source ----------------
    assign fu_rsp_valid  = ax_rsp_valid && (ax_rsp_src == cpu_pkg::MRF_IC);
    assign la_rd_rsp_valid = ax_rsp_valid && (ax_rsp_src != cpu_pkg::MRF_IC);
    assign ax_rsp_ready  = (ax_rsp_src == cpu_pkg::MRF_IC) ? fu_rsp_ready : la_rd_rsp_ready;
    assign fu_rsp_idx    = ax_rsp_idx;
    assign fu_rsp_data   = ax_rsp_data;
    assign la_rd_rsp_idx = ax_rsp_idx;
    assign la_rd_rsp_data = ax_rsp_data;




endmodule
