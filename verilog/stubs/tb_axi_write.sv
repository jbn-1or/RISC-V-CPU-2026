// Checks independent AW/W backpressure, ordered B tags, and bubble-free issue.
module tb_axi_write;
    localparam int N = 256;
    logic clock = 0;
    always #5 clock = ~clock;
    logic reset = 1;
    logic push_valid, push_ready;
    logic [31:0] push_addr, push_data;
    logic [3:0] push_strb, push_tag;
    wire [31:0] awaddr, wdata;
    wire [3:0] wstrb, rsp_tag;
    wire awvalid, wvalid, bready, rsp_valid;
    logic awready = 0, wready = 0, bvalid = 0;
    int cycle = 0, pushed = 0, aws = 0, ws = 0, bs = 0;
    int aw_time [N], w_time [N];
    int last_aw = -1;
    logic aw_held = 0, w_held = 0;
    logic [31:0] held_addr, held_data;
    logic [3:0] held_strb;

    function automatic logic [31:0] addr_for(input int n);
        return 32'h1000 + 4 * n;
    endfunction
    function automatic logic [31:0] data_for(input int n);
        return 32'hcab00000 ^ (32'h10203 * n);
    endfunction
    function automatic logic [3:0] strb_for(input int n);
        return 4'(1 + n % 15);
    endfunction

    axi_master dut (
        .clock, .reset,
        .rd_push_valid(1'b0), .rd_push_addr(32'd0),
        .rd_push_src(cpu_pkg::MRF_IC), .rd_push_idx(5'd0), .rd_push_ready(),
        .rd_rsp_valid(), .rd_rsp_src(), .rd_rsp_idx(), .rd_rsp_err(),
        .rd_rsp_data(), .rd_rsp_ready(1'b1),
        .wr_push_valid(push_valid), .wr_push_addr(push_addr),
        .wr_push_data(push_data), .wr_push_strb(push_strb), .wr_push_tag(push_tag),
        .wr_push_ready(push_ready), .wr_rsp_valid(rsp_valid), .wr_rsp_tag(rsp_tag),
        .araddr(), .arvalid(), .arready(1'b1),
        .rdata(32'd0), .rresp(2'd0), .rvalid(1'b0), .rready(),
        .awaddr, .awvalid, .awready, .wdata, .wstrb, .wvalid, .wready,
        .bvalid, .bready
    );

    initial begin
        push_valid = 0;
        push_addr = 0; push_data = 0; push_strb = 0; push_tag = 0;
        repeat (3) @(negedge clock);
        reset = 0;
    end

    // Drive on falling edges, sample only on rising edges. The first 64
    // writes have no stalls; later writes stall AW and W independently.
    always @(negedge clock) begin
        if (!reset) begin
            push_valid = pushed < N;
            push_addr = addr_for(pushed);
            push_data = data_for(pushed);
            push_strb = strb_for(pushed);
            push_tag = 4'(pushed);
            awready = aws < 64 || (cycle % 7 < 4);
            wready = ws < 64 || (cycle % 11 >= 5);
            bvalid = 0;
            if (bs < aws && bs < ws)
                bvalid = cycle >= ((aw_time[bs] > w_time[bs]) ?
                                    aw_time[bs] : w_time[bs]) + (bs < 64 ? 0 : 1 + bs % 5);
        end
    end

    always @(posedge clock) begin
        if (!reset) begin
            cycle = cycle + 1;
            if (cycle > 10000) $fatal(1, "write-channel timeout");
            if (aw_held && (!awvalid || awaddr !== held_addr))
                $fatal(1, "AW payload changed under backpressure");
            if (w_held && (!wvalid || wdata !== held_data || wstrb !== held_strb))
                $fatal(1, "W payload changed under backpressure");
            aw_held = awvalid && !awready;
            w_held = wvalid && !wready;
            held_addr = awaddr; held_data = wdata; held_strb = wstrb;

            if (push_valid && push_ready) pushed = pushed + 1;
            if (awvalid && awready) begin
                if (aws >= pushed || awaddr !== addr_for(aws))
                    $fatal(1, "AW order/data mismatch at %0d", aws);
                if (aws > 0 && aws < 64 && cycle != last_aw + 1)
                    $fatal(1, "issue bubble at write %0d", aws);
                last_aw = cycle;
                aw_time[aws] = cycle;
                aws = aws + 1;
            end
            if (wvalid && wready) begin
                if (ws >= pushed || wdata !== data_for(ws) || wstrb !== strb_for(ws))
                    $fatal(1, "W order/data mismatch at %0d", ws);
                w_time[ws] = cycle;
                ws = ws + 1;
            end
            if (bvalid && bready) begin
                if (!rsp_valid || rsp_tag !== 4'(bs))
                    $fatal(1, "B tag mismatch at %0d", bs);
                bs = bs + 1;
                if (bs == N) begin
                    $display("PASS: %0d writes, independent AW/W stalls, ordered tags, 1 write/cycle", N);
                    $finish;
                end
            end
        end
    end
endmodule
