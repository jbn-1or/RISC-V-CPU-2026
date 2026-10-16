// LSU unit test (M3 A3/B3 acceptance): lsu_b + lsu_a (with the D$) + axi_master
// against a sim.cpp-like AXI4-Lite slave (16-deep queues, fixed latency,
// in-order R, word-aligned enforcement, write-through memory).
//
// Covered directed scenarios (promoted from tools/mk_storeload.py and
// tools/mk_unaligned.py):
//   T1 retire-gated store drain (no AXI write before the ROB commit pulse)
//   T2 SW->LW full forwarding (no memory access)
//   T3 byte/half/word forwarding variants incl. sign extension
//   T4 partial overlap (LW after SB) blocks until the store completes
//   T5 same-line guard (LW same line, no overlap) blocks until completion
//   T6 flush kills an unretired store: it never reaches memory
//   T7 unaligned SB/SH + write-through + eviction read-back
//   T8 MSHR: concurrent misses, same-set replay, in-order completion
`timescale 1ns/1ps
module tb_lsu;
    import cpu_pkg::*;
    logic clock = 0, reset = 1;
    always #5 clock = ~clock;

    int cyc = 0;
    always_ff @(posedge clock) cyc <= cyc + 1;

    // ---------------- B-side issue signals ----------------
    logic        in_valid = 0;
    cpu_pkg::op_e in_op = cpu_pkg::OP_LOAD;
    logic [2:0]  in_funct3 = 3'd2;
    logic [31:0] in_base = 0, in_imm = 0, in_store_data = 0;
    logic [5:0]  in_pdst = 0;
    logic [$clog2(cpu_pkg::ROB_DEPTH)-1:0] in_rob = 0;
    wire         ld_alloc_ok, st_alloc_ok;

    // writeback / narrow completion
    wire        wb_valid;
    wire [5:0]  wb_tag;
    wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] wb_rob;
    wire [31:0] wb_data;
    wire        ndone_valid;
    wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] ndone_rob;

    // ROB references
    logic [$clog2(cpu_pkg::ROB_DEPTH)-1:0] rob_head = 0;
    logic [1:0] cmt_valid = 2'd0;
    logic [$clog2(cpu_pkg::ROB_DEPTH)-1:0] cmt_rob0 = 0, cmt_rob1 = 0;

    // flush
    logic       flush_valid = 0;
    logic [$clog2(cpu_pkg::ROB_DEPTH)-1:0] flush_rob = 0;
    logic [$clog2(cpu_pkg::ROB_DEPTH):0] flush_dtail = 0;

    // B <-> A channels
    wire        ld_valid, ld_ready, st_valid, st_ready;
    cpu_pkg::mem_req_t ld_req, st_req;
    wire        resp_valid, resp_replay;
    cpu_pkg::mem_resp_t resp;

    cpu_pkg::writeback_t tb_wb0 = '0, tb_wb1 = '0;
    lsu_b u_lsu (
        .clock, .reset,
        .in_valid, .in_op, .in_funct3, .in_base, .in_imm, .in_store_data, .in_pdst, .in_rob,
        // directed tests drive ready store data directly (M8 late-fill path idle)
        .in_ps2(6'd0), .in_rs2_ready(1'b1), .wb_a(tb_wb0), .wb_b(tb_wb1),
        .ld_alloc_ok, .st_alloc_ok,
        .wb_valid, .wb_tag, .wb_rob, .wb_data, .wb_ready(1'b1),
        .ndone_valid, .ndone_rob,
        .rob_head, .cmt_valid, .cmt_rob0, .cmt_rob1,
        .flush_valid, .flush_rob, .flush_dtail,
        .ld_valid, .ld_req, .ld_ready,
        .st_valid, .st_req, .st_ready,
        .resp_valid, .resp, .resp_replay);

    // ---------------- A side ----------------
    wire        la_rd_v, la_rd_ready, la_rd_rsp_valid, la_rd_rsp_ready;
    wire [31:0] la_rd_addr, la_rd_rsp_data;
    wire [4:0]  la_rd_idx, la_rd_rsp_idx;
    wire        la_wr_v, la_wr_ready, la_wr_rsp_valid;
    wire [31:0] la_wr_addr, la_wr_data;
    wire [3:0]  la_wr_strb, la_wr_tag, la_wr_rsp_tag;

    lsu_a u_lsa (
        .clock, .reset,
        .flush_valid, .flush_rob, .flush_dtail,
        .ld_valid, .ld_req, .ld_ready,
        .st_valid, .st_req, .st_ready,
        .resp_valid, .resp, .resp_replay,
        .rd_push_valid(la_rd_v), .rd_push_addr(la_rd_addr), .rd_push_idx(la_rd_idx),
        .rd_push_ready(la_rd_ready),
        .rd_rsp_valid(la_rd_rsp_valid), .rd_rsp_idx(la_rd_rsp_idx),
        .rd_rsp_data(la_rd_rsp_data), .rd_rsp_ready(la_rd_rsp_ready),
        .wr_push_valid(la_wr_v), .wr_push_addr(la_wr_addr), .wr_push_data(la_wr_data),
        .wr_push_strb(la_wr_strb), .wr_push_tag(la_wr_tag), .wr_push_ready(la_wr_ready),
        .wr_rsp_valid(la_wr_rsp_valid), .wr_rsp_tag(la_wr_rsp_tag));

    // ---------------- AXI master ----------------
    wire        ax_rd_v, ax_rd_ready, ax_rd_rsp_valid;
    wire [31:0] ax_rd_addr, ax_rd_rsp_data;
    wire [4:0]  ax_rd_idx, ax_rd_rsp_idx;
    wire [1:0]  ax_rd_rsp_src, ax_rd_rsp_err;
    wire        ax_wr_v, ax_wr_ready, ax_wr_rsp_valid;
    wire [31:0] ax_wr_addr, ax_wr_data;
    wire [3:0]  ax_wr_strb, ax_wr_tag, ax_wr_rsp_tag;

    wire [31:0] araddr, awaddr, wdata;
    wire        arvalid, awvalid, wvalid, rready, bready;
    wire        arready, rvalid, awready, wready, bvalid;
    wire [31:0] rdata;
    wire [1:0]  rresp, bresp;
    wire [3:0]  wstrb;

    axi_master u_axi (
        .clock, .reset,
        .rd_push_valid(la_rd_v), .rd_push_addr(la_rd_addr), .rd_push_src(cpu_pkg::MRF_DC),
        .rd_push_idx(la_rd_idx), .rd_push_ready(la_rd_ready),
        .rd_rsp_valid(ax_rd_rsp_valid), .rd_rsp_src(ax_rd_rsp_src), .rd_rsp_idx(ax_rd_rsp_idx),
        .rd_rsp_err(ax_rd_rsp_err), .rd_rsp_data(ax_rd_rsp_data), .rd_rsp_ready(1'b1),
        .wr_push_valid(la_wr_v), .wr_push_addr(la_wr_addr), .wr_push_data(la_wr_data),
        .wr_push_strb(la_wr_strb), .wr_push_tag(la_wr_tag), .wr_push_ready(la_wr_ready),
        .wr_rsp_valid(la_wr_rsp_valid), .wr_rsp_tag(la_wr_rsp_tag),
        .araddr, .arvalid, .arready,
        .rdata, .rresp, .rvalid, .rready,
        .awaddr, .awvalid, .awready,
        .wdata, .wstrb, .wvalid, .wready,
        .bvalid, .bready);

    assign la_rd_rsp_valid = ax_rd_rsp_valid;
    assign la_rd_rsp_idx   = ax_rd_rsp_idx;
    assign la_rd_rsp_data  = ax_rd_rsp_data;

    // ================= AXI slave (sim.cpp-like) =================
    localparam int QD = 16;
    localparam int SLV_LAT = 6;

    logic [31:0] mem [0:262143];

    // read side: FIFO of {addr, due}; in-order responses, rready always 1
    logic [31:0] rdq_a [0:QD-1];
    logic [5:0]  rdq_due [0:QD-1];
    logic [4:0]  rdq_cnt;
    logic [4:0]  rdq_head, rdq_tail;
    logic        rv_q;
    logic [31:0] rd_rdata_q;
    wire rd_push_s = arvalid && arready;
    assign arready = !reset && (rdq_cnt < QD);
    assign rvalid  = rv_q;
    assign rdata   = rd_rdata_q;
    assign rresp   = 2'b00;

    // write side: independent AW/W FIFOs, pair when both available
    logic [31:0] awq_a [0:QD-1];
    logic [4:0]  awq_cnt;
    logic [4:0]  awq_head, awq_tail;
    logic [31:0] wq_d [0:QD-1];
    logic [3:0]  wq_s [0:QD-1];
    logic [4:0]  wq_cnt;
    logic [4:0]  wq_head, wq_tail;
    assign awready = !reset && (awq_cnt < QD);
    assign wready  = !reset && (wq_cnt < QD);
    wire aw_push = awvalid && awready;
    wire w_push  = wvalid && wready;

    logic        wr_svc;
    logic [5:0]  wr_due;
    logic [31:0] wr_addr_r, wr_data_r;
    logic [3:0]  wr_strb_r;
    logic        bv_q;
    assign bvalid = bv_q;
    assign bresp  = 2'b00;

    // write log (applied writes)
    int          wr_log_cnt = 0;
    logic [31:0] wr_log_addr [0:127];
    logic [31:0] wr_log_data [0:127];
    logic [3:0]  wr_log_strb [0:127];

    // exit capture
    logic        exit_seen = 0;
    logic [31:0] exit_val = 0;

    wire rd_pop_s = !rv_q && (rdq_cnt != 5'd0) && (rdq_due[rdq_head] <= cyc[5:0]);
    wire wr_pair  = !wr_svc && (awq_cnt != 5'd0) && (wq_cnt != 5'd0);
    wire wr_apply = wr_svc && (wr_due <= cyc[5:0]) && !bv_q;

    always_ff @(posedge clock) begin
        if (reset) begin
            rdq_cnt <= 0; rdq_head <= 0; rdq_tail <= 0; rv_q <= 0;
            awq_cnt <= 0; awq_head <= 0; awq_tail <= 0;
            wq_cnt <= 0; wq_head <= 0; wq_tail <= 0;
            wr_svc <= 0; bv_q <= 0;
        end else begin
            // ---- reads ----
            if (rd_push_s) begin
                rdq_a[rdq_tail]   <= araddr;
                rdq_due[rdq_tail] <= cyc[5:0] + SLV_LAT[5:0];
                rdq_tail <= rdq_tail + 5'd1;
            end
            if (rd_pop_s) begin
                rv_q <= 1'b1;
                rd_rdata_q <= mem[rdq_a[rdq_head][19:2]];
                rdq_head <= rdq_head + 5'd1;
            end
            case ({rd_push_s, rd_pop_s})
                2'b10: rdq_cnt <= rdq_cnt + 5'd1;
                2'b01: rdq_cnt <= rdq_cnt - 5'd1;
                default: ;
            endcase
            if (rv_q && rready) rv_q <= 1'b0;

            // ---- writes ----
            if (aw_push) begin
                awq_a[awq_tail] <= awaddr;
                awq_tail <= awq_tail + 5'd1;
            end
            case ({aw_push, wr_pair})
                2'b10: awq_cnt <= awq_cnt + 5'd1;
                2'b01: awq_cnt <= awq_cnt - 5'd1;
                default: ;
            endcase
            if (w_push) begin
                wq_d[wq_tail] <= wdata;
                wq_s[wq_tail] <= wstrb;
                wq_tail <= wq_tail + 5'd1;
            end
            case ({w_push, wr_pair})
                2'b10: wq_cnt <= wq_cnt + 5'd1;
                2'b01: wq_cnt <= wq_cnt - 5'd1;
                default: ;
            endcase
            if (wr_pair) begin
                wr_svc   <= 1'b1;
                wr_addr_r <= awq_a[awq_head];
                wr_data_r <= wq_d[wq_head];
                wr_strb_r <= wq_s[wq_head];
                wr_due   <= cyc[5:0] + SLV_LAT[5:0];
                awq_head <= awq_head + 5'd1;
                wq_head  <= wq_head + 5'd1;
            end
            if (wr_apply) begin
                wr_svc <= 1'b0;
                bv_q   <= 1'b1;
                if (wr_addr_r == 32'h8000_0000) begin
                    if (wr_strb_r == 4'hf) begin exit_seen <= 1'b1; exit_val <= wr_data_r; end
                    else $fatal(1, "tb_lsu: exit write with wstrb=%h", wr_strb_r);
                end else if (wr_addr_r[1:0] == 2'b00) begin
                    for (int b = 0; b < 4; b = b + 1)
                        if (wr_strb_r[b]) mem[wr_addr_r[19:2]][b*8 +: 8] <= wr_data_r[b*8 +: 8];
                    wr_log_addr[wr_log_cnt] <= wr_addr_r;
                    wr_log_data[wr_log_cnt] <= wr_data_r;
                    wr_log_strb[wr_log_cnt] <= wr_strb_r;
                    wr_log_cnt <= wr_log_cnt + 1;
                end else begin
                    // sim.cpp: unaligned writes are SLVERR and are NOT applied
                    $display("[tb_lsu] slave: dropped unaligned write addr=%h", wr_addr_r);
                end
            end
            if (bv_q && bready) bv_q <= 1'b0;
        end
    end

    // AXI contract assertions
    always_ff @(posedge clock) begin
        if (!reset) begin
            if (arvalid && arready && (araddr[1:0] != 2'b00))
                $fatal(1, "tb_lsu: unaligned AR addr=%h", araddr);
            if (awvalid && awready && (awaddr[1:0] != 2'b00))
                $fatal(1, "tb_lsu: unaligned AW addr=%h", awaddr);
            if (wr_svc && (wr_addr_r[1:0] != 2'b00))
                $fatal(1, "tb_lsu: unaligned applied write addr=%h", wr_addr_r);
        end
    end

    // ================= monitors =================
    logic        wb_seen [0:31];
    logic [31:0] wb_data_of [0:31];
    int          wb_cyc_of [0:31];
    logic        st_done [0:31];
    int          st_cyc_of [0:31];
    int          nd_cnt = 0;
    logic [4:0]  nd_rob_last = 0;

    always_ff @(posedge clock) begin
        if (!reset) begin
            if (wb_valid) begin
                wb_seen[wb_rob] <= 1'b1;
                wb_data_of[wb_rob] <= wb_data;
                wb_cyc_of[wb_rob] <= cyc;
            end
            if (resp_valid && resp.is_store) begin
                st_done[resp.rob] <= 1'b1;
                st_cyc_of[resp.rob] <= cyc;
            end
            if (ndone_valid) begin
                nd_cnt <= nd_cnt + 1;
                nd_rob_last <= ndone_rob;
            end
        end
    end

    // ================= driver tasks =================
    int errors = 0;
    task automatic chk(input logic cond, input string msg);
        if (!cond) begin
            errors = errors + 1;
            $display("[tb_lsu] FAIL: %s", msg);
        end
    endtask

    task automatic step(input int n);
        repeat (n) @(negedge clock);
    endtask

    task automatic issue(input cpu_pkg::op_e op, input [31:0] base, input [2:0] f3,
                         input [31:0] data, input [4:0] rob, input [5:0] pdst);
        while (!(op == cpu_pkg::OP_STORE ? st_alloc_ok : ld_alloc_ok)) @(negedge clock);
        in_valid = 1'b1; in_op = op; in_base = base; in_imm = 32'd0; in_funct3 = f3;
        in_store_data = data; in_rob = rob; in_pdst = pdst;
        step(1);
        in_valid = 0;
        step(1);
    endtask

    task automatic issue_load(input [31:0] addr, input [2:0] f3, input [4:0] rob, input [5:0] pdst);
        issue(cpu_pkg::OP_LOAD, addr, f3, 32'd0, rob, pdst);
    endtask

    task automatic issue_store(input [31:0] addr, input [31:0] data, input [2:0] f3, input [4:0] rob);
        issue(cpu_pkg::OP_STORE, addr, f3, data, rob, 6'd0);
    endtask

    task automatic retire(input [4:0] rob);
        cmt_valid = 2'b01; cmt_rob0 = rob;
        step(1);
        cmt_valid = 2'd0;
        rob_head = rob + 5'd1;
        step(1);
    endtask

    task automatic wait_wb(input [4:0] rob, input int timeout, output logic ok);
        int t;
        ok = 1'b0; t = 0;
        while (!wb_seen[rob] && t < timeout) begin step(1); t = t + 1; end
        if (wb_seen[rob]) ok = 1'b1;
    endtask

    task automatic wait_st_done(input [4:0] rob, input int timeout, output logic ok);
        int t;
        ok = 1'b0; t = 0;
        while (!st_done[rob] && t < timeout) begin step(1); t = t + 1; end
        if (st_done[rob]) ok = 1'b1;
    endtask

    // ================= test sequence =================
    logic ok;
    int   wr_n;
    logic [4:0] rb;

    initial begin
        for (int i = 0; i < 262144; i = i + 1) mem[i] = 32'd0;
        for (int i = 0; i < 32; i = i + 1) begin
            wb_seen[i] = 0; wb_data_of[i] = 0; wb_cyc_of[i] = 0;
            st_done[i] = 0; st_cyc_of[i] = 0;
        end
        // preloads
        mem[32'h0000_0054 >> 2] = 32'hAABBCCDD;
        mem[32'h0000_0058 >> 2] = 32'h00112233;
        mem[32'h0002_0000 >> 2] = 32'hAAAA0000;
        mem[32'h0002_0100 >> 2] = 32'hBBBB1111;
        mem[32'h0003_0000 >> 2] = 32'hCCCC2222;

        repeat (5) @(negedge clock);
        reset = 0;
        step(1);

        // ---------------- T1: retire-gated drain ----------------
        issue_store(32'h0000_0040, 32'hAABBCCDD, 3'd2, 5'd0);
        chk(nd_cnt == 1 && nd_rob_last == 5'd0, "T1 store ndone pulse at AGU");
        step(30);
        wr_n = wr_log_cnt;
        chk(wr_n == 0, "T1 no AXI write before retire");
        retire(5'd0);
        wait_st_done(5'd0, 200, ok);
        chk(ok, "T1 store completion after retire");
        step(5);
        chk(wr_log_cnt == 1, "T1 exactly one AXI write");
        chk(wr_log_addr[0] == 32'h0000_0040 && wr_log_data[0] == 32'hAABBCCDD &&
            wr_log_strb[0] == 4'hf, "T1 write payload");
        chk(mem[32'h40 >> 2] == 32'hAABBCCDD, "T1 memory content");

        // ---------------- T2: SW -> LW full forward ----------------
        issue_store(32'h0000_0044, 32'h11223344, 3'd2, 5'd1);
        issue_load(32'h0000_0044, 3'd2, 5'd2, 6'd1);
        wait_wb(5'd2, 50, ok);
        chk(ok, "T2 load wb");
        chk(wb_data_of[2] == 32'h11223344, "T2 forwarded data");
        chk(wb_cyc_of[2] < st_cyc_of[1] || !st_done[1], "T2 forwarded before store completion");
        chk(!st_done[1], "T2 store still undrained (no retire)");

        // ---------------- T3: byte/half/word forwarding ----------------
        issue_store(32'h0000_0048, 32'h0000005A, 3'd0, 5'd3);            // sb 0x5A
        issue_load(32'h0000_0048, 3'd4, 5'd4, 6'd3);                     // lbu
        wait_wb(5'd4, 50, ok);
        chk(ok && (wb_data_of[4] == 32'h0000005A), "T3 SB->LBU");

        issue_store(32'h0000_004A, 32'h0000BEEF, 3'd1, 5'd5);            // sh 0xBEEF
        issue_load(32'h0000_004A, 3'd5, 5'd6, 6'd4);                     // lhu
        wait_wb(5'd6, 50, ok);
        chk(ok && (wb_data_of[6] == 32'h0000BEEF), "T3 SH->LHU");

        issue_store(32'h0000_0050, 32'h44332211, 3'd2, 5'd7);            // sw
        issue_load(32'h0000_0051, 3'd0, 5'd8, 6'd5);                     // lb  -> 0x22
        wait_wb(5'd8, 50, ok);
        chk(ok && (wb_data_of[8] == 32'h00000022), "T3 SW->LB byte1");
        issue_load(32'h0000_0053, 3'd0, 5'd9, 6'd6);                     // lb  -> 0x44
        wait_wb(5'd9, 50, ok);
        chk(ok && (wb_data_of[9] == 32'h00000044), "T3 SW->LB byte3");
        issue_load(32'h0000_0052, 3'd4, 5'd10, 6'd7);                    // lbu -> 0x33
        wait_wb(5'd10, 50, ok);
        chk(ok && (wb_data_of[10] == 32'h00000033), "T3 SW->LBU byte2");

        // ---------------- T4: partial overlap blocks ----------------
        issue_store(32'h0000_0054, 32'h00000077, 3'd0, 5'd11);           // sb -> [0x54]
        issue_load(32'h0000_0054, 3'd2, 5'd12, 6'd8);                    // lw: partial overlap
        step(40);
        chk(!wb_seen[12], "T4 load blocked while store live");
        retire(5'd11);
        wait_st_done(5'd11, 200, ok);
        chk(ok, "T4 store completion");
        wait_wb(5'd12, 300, ok);
        chk(ok, "T4 load completes after store");
        chk(wb_data_of[12] == 32'hAABBCC77, "T4 merged data");
        chk(wb_cyc_of[12] > st_cyc_of[11], "T4 load after store completion");

        // ---------------- T5: same-line guard ----------------
        issue_store(32'h0000_005C, 32'h55667788, 3'd2, 5'd13);
        issue_load(32'h0000_0058, 3'd2, 5'd14, 6'd9);                    // same line, no overlap
        step(40);
        chk(!wb_seen[14], "T5 load blocked by same-line store");
        retire(5'd13);
        wait_st_done(5'd13, 200, ok);
        chk(ok, "T5 store completion");
        wait_wb(5'd14, 300, ok);
        chk(ok && (wb_data_of[14] == 32'h00112233), "T5 load data after unblock");
        chk(wb_cyc_of[14] > st_cyc_of[13], "T5 load after store completion");

        // ---------------- T6: flush kills an unretired store ----------------
        issue_store(32'h0000_0060, 32'h12345678, 3'd2, 5'd15);
        step(2);
        flush_valid = 1; flush_rob = $clog2(cpu_pkg::ROB_DEPTH)'(14); flush_dtail = 2;   // kill rob 15
        step(1);
        flush_valid = 0; flush_dtail = 0;
        step(60);
        wr_n = wr_log_cnt;
        for (int i = 0; i < wr_n; i = i + 1)
            chk(wr_log_addr[i] != 32'h0000_0060, "T6 killed store never reaches memory");
        rob_head = 5'd16;                                                 // advance past the dead slot

        // ---------------- T7: unaligned SB/SH + eviction read-back --------
        // sb 0x5A to 0x81 (lane 1), sh 0xBEEF to 0x82 (lanes 2-3)
        issue_store(32'h0000_0081, 32'h0000005A, 3'd0, 5'd16);
        retire(5'd16);
        wait_st_done(5'd16, 200, ok);
        chk(ok, "T7 sb completes");
        issue_store(32'h0000_0082, 32'h0000BEEF, 3'd1, 5'd17);
        retire(5'd17);
        wait_st_done(5'd17, 200, ok);
        chk(ok, "T7 sh completes");
        step(5);
        // aligned word write with proper lanes
        begin
            int found;
            found = 0;
            for (int i = 0; i < wr_log_cnt; i = i + 1)
                if (wr_log_addr[i] == 32'h0000_0080) begin
                    found = found + 1;
                    if (found == 1)
                        chk(wr_log_strb[i] == 4'b0010 && wr_log_data[i] == 32'h00005A00,
                            "T7 sb lanes");
                    if (found == 2)
                        chk(wr_log_strb[i] == 4'b1100 && wr_log_data[i] == 32'hBEEF0000,
                            "T7 sh lanes");
                end
            chk(found == 2, "T7 two writes to 0x80");
            chk(mem[32'h80 >> 2] == 32'hBEEF5A00, "T7 memory word");
        end
        issue_load(32'h0000_0081, 3'd4, 5'd18, 6'd10);                   // lbu
        wait_wb(5'd18, 300, ok);
        chk(ok && (wb_data_of[18] == 32'h0000005A), "T7 read-back LBU via memory");
        issue_load(32'h0000_0082, 3'd5, 5'd19, 6'd11);                   // lhu
        wait_wb(5'd19, 300, ok);
        chk(ok && (wb_data_of[19] == 32'h0000BEEF), "T7 read-back LHU via memory");
        issue_load(32'h0000_0080, 3'd2, 5'd20, 6'd12);                   // lw
        wait_wb(5'd20, 300, ok);
        chk(ok && (wb_data_of[20] == 32'hBEEF5A00), "T7 read-back LW");

        // eviction pressure: touch 300 distinct lines (stride 0x10)
        rb = 5'd20;
        for (int i = 0; i < 300; i = i + 1) begin
            rb = rb + 5'd1;
            wb_seen[rb] = 1'b0;
            issue_load(32'h0001_0000 + (i << 4), 3'd2, rb, 6'd20);
            wait_wb(rb, 400, ok);
            chk(ok, "T7 eviction load completes");
        end
        rb = rb + 5'd1;
        wb_seen[rb] = 1'b0;
        issue_load(32'h0000_0080, 3'd2, rb, 6'd21);                      // re-read after eviction
        wait_wb(rb, 400, ok);
        chk(ok && (wb_data_of[rb] == 32'hBEEF5A00), "T7 LW after eviction");

        // ---------------- T8: MSHR concurrency + same-set replay ----------
        // 0x20000 and 0x30000 share D$ set 0; 0x20100 is a different set.
        rb = rb + 5'd1;
        wb_seen[rb] = 1'b0; wb_seen[rb + 5'd1] = 1'b0; wb_seen[rb + 5'd2] = 1'b0;
        issue_load(32'h0002_0000, 3'd2, rb, 6'd22);
        issue_load(32'h0003_0000, 3'd2, rb + 5'd1, 6'd23);               // same set -> replay
        issue_load(32'h0002_0100, 3'd2, rb + 5'd2, 6'd24);               // other set
        wait_wb(rb, 600, ok);
        chk(ok && (wb_data_of[rb] == 32'hAAAA0000), "T8 miss A");
        wait_wb(rb + 5'd1, 600, ok);
        chk(ok && (wb_data_of[rb + 5'd1] == 32'hCCCC2222), "T8 same-set replay load");
        wait_wb(rb + 5'd2, 600, ok);
        chk(ok && (wb_data_of[rb + 5'd2] == 32'hBBBB1111), "T8 concurrent other-set load");

        // ---------------- report ----------------
        if (errors == 0) $display("[tb_lsu] ALL OK");
        else             $display("[tb_lsu] FAILED: %0d error(s)", errors);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("[tb_lsu] FAIL: global timeout");
        $finish;
    end
endmodule
