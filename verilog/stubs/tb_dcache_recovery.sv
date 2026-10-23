// Recovery concurrent with a critical-word response under backpressure.
// Killed tokens must not reappear after ROB-number reuse; older loads survive.
`timescale 1ns/1ps
module tb_dcache_recovery;
    logic clock = 0, reset = 1;
    always #5 clock = ~clock;
    logic lk_valid = 0;
    logic [31:0] lk_addr = 0;
    logic [4:0] lk_token = 0;
    wire lk_ready, rsp_valid, rsp_replay;
    wire [4:0] rsp_token;
    wire [31:0] rsp_data;
    logic rsp_ready = 0, flush_valid = 0;
    logic [4:0] flush_rob = 2;
    logic [5:0] flush_dtail = 6;
    wire rd_push_valid, rd_rsp_ready;
    wire [31:0] rd_push_addr;
    wire [4:0] rd_push_idx;
    logic rd_rsp_valid = 0;
    logic [4:0] rd_rsp_idx = 0;
    logic [31:0] rd_rsp_data = 0;
    logic [4:0] read_tags [0:31];
    int read_count = 0, responses_seen = 0;
    logic expected_valid = 0;
    logic [4:0] expected_token = 0;
    logic [31:0] expected_data = 0;

    dcache dut (
        .clock, .reset, .lk_valid, .lk_addr, .lk_token, .lk_ready,
        .probe_addr(32'd0), .probe_set_valid(),
        .rsp_valid, .rsp_token, .rsp_data, .rsp_replay, .rsp_ready,
        .su_valid(1'b0), .su_addr(32'd0), .su_data(32'd0), .su_strb(4'd0),
        .su_ready(), .su_hit(), .su_stall(), .inv_valid(1'b0), .inv_addr(32'd0),
        .flush_valid, .flush_rob, .flush_dtail,
        .rd_push_valid, .rd_push_addr, .rd_push_idx, .rd_push_ready(1'b1),
        .rd_rsp_valid, .rd_rsp_idx, .rd_rsp_data, .rd_rsp_ready);

    always @(posedge clock) begin
        if (reset) begin read_count = 0; responses_seen = 0; end
        else begin
            if (rd_push_valid) begin
                if (read_count >= 32) $fatal(1, "unexpected refill count");
                read_tags[read_count] = rd_push_idx;
                read_count = read_count + 1;
            end
            if (rsp_valid && rsp_ready) begin
                if (!expected_valid || rsp_replay || rsp_token != expected_token ||
                    rsp_data !== expected_data)
                    $fatal(1, "stale/unexpected response: token=%0d data=%h replay=%b",
                           rsp_token, rsp_data, rsp_replay);
                responses_seen = responses_seen + 1;
            end
        end
    end

    task automatic step(input int n);
        repeat(n) @(negedge clock);
    endtask
    task automatic issue_load(input logic [31:0] addr, input logic [4:0] token);
        logic accepted;
        accepted = 0;
        lk_addr = addr; lk_token = token; lk_valid = 1;
        while (!accepted) begin
            @(posedge clock); accepted = lk_ready;
            @(negedge clock);
        end
        lk_valid = 0;
    endtask
    task automatic wait_reads(input int n);
        int timeout;
        timeout = 0;
        while (read_count < n && timeout < 100) begin step(1); timeout++; end
        if (read_count != n) $fatal(1, "missing refill requests");
    endtask
    task automatic send_word(input int index, input logic [31:0] data);
        rd_rsp_idx = read_tags[index]; rd_rsp_data = data; rd_rsp_valid = 1;
        step(1);
        if (!rd_rsp_ready) $fatal(1, "unexpected refill backpressure");
        rd_rsp_valid = 0;
    endtask
    task automatic run_case(input logic killed);
        reset = 1; lk_valid = 0; rd_rsp_valid = 0;
        flush_valid = 0; rsp_ready = 0; expected_valid = 0;
        step(3); reset = 0; step(1);
        issue_load(32'h0, killed ? 5'd4 : 5'd1);
        wait_reads(8);
        send_word(0, 32'h11112222);
        // The accepted word reaches the response stage on the next edge.
        // Hold the consumer stalled across recovery and all remaining fills.
        flush_valid = 1; step(1); flush_valid = 0;
        for (int i = 1; i < 8; i++) send_word(i, 32'h11112222 + 32'(i));
        step(2);
        if (killed) begin
            issue_load(32'h40, 5'd4); // reuse the killed load's ROB number
            wait_reads(16);
            for (int i = 8; i < 16; i++) send_word(i, 32'h33334444 + 32'(i-8));
            step(2);
        end
        expected_token = killed ? 5'd4 : 5'd1;
        expected_data = killed ? 32'h33334444 : 32'h11112222;
        expected_valid = 1; rsp_ready = 1;
        step(8);
        if (responses_seen != 1) $fatal(1, "expected exactly one surviving load");
    endtask

    initial begin
        step(1);
        run_case(1);
        run_case(0);
        $display("PASS: recovery/refill collision, ROB reuse, older load preserved");
        $finish;
    end
    initial begin #100000; $fatal(1, "timeout"); end
endmodule
