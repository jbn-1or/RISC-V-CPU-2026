// 单元测试顶层：假前端 -> 假后端，验证 valid/ready 握手链路是否正确。
// 运行：sh verilog/stubs/run_ut.sh   （详见 verilog/stubs/README.md）
module tb_stub_link;
    logic clock = 1'b0;
    logic reset = 1'b1;

    logic               fe_valid, fe_ready, fe_done;
    cpu_pkg::decoded_t  fe_insn;
    logic               be_commit_valid;
    logic [31:0]        be_commit_pc;

    int committed;

    fe_stub #(.COUNT(4)) u_fe (
        .clock, .reset,
        .out_valid (fe_valid), .out_insn (fe_insn),
        .out_ready (fe_ready), .done     (fe_done)
    );

    be_sink #(.LATENCY(2)) u_be (
        .clock, .reset,
        .in_valid (fe_valid), .in_insn (fe_insn), .in_ready (fe_ready),
        .commit_valid (be_commit_valid), .commit_pc (be_commit_pc)
    );

    always #1 clock = ~clock;          // 1 个时间单位半周期

    always_ff @(posedge clock) if (be_commit_valid) committed <= committed + 1;

    initial begin
        committed = 0;
        repeat (3) @(posedge clock);
        reset = 1'b0;
        repeat (80) @(posedge clock);
        if (committed != 4) $fatal(1, "stub link failed: committed=%0d", committed);
        $display("[tb_stub_link] ok: committed=%0d fe_done=%0d", committed, fe_done);
        $finish;
    end
endmodule
