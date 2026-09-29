// 假后端：A 在写前端时用它顶替真正的后端。
// 只用于本地单元测试，绝不写进 verilog/filelist.f。
module be_sink #(
    parameter int LATENCY = 2            // 接收后多少拍“完成”，用来模拟后端忙
) (
    input  wire                     clock,
    input  wire                     reset,
    input  wire                     in_valid,
    input  wire cpu_pkg::decoded_t  in_insn,
    output logic                    in_ready,
    output logic                    commit_valid,
    output logic [31:0]             commit_pc
);
    import cpu_pkg::*;

    logic [1:0] free_cnt;                // 还有几拍才空闲
    logic       pending;

    // 接收方生成 ready（契约规定：ready 允许组合，valid 不许依赖 ready）
    assign in_ready = (free_cnt == 2'd0);

    always_ff @(posedge clock) begin
        if (reset) begin
            free_cnt     <= 2'd0;
            pending      <= 1'b0;
            commit_valid <= 1'b0;
            commit_pc    <= 32'h0;
        end else begin
            commit_valid <= 1'b0;
            if (pending) begin
                free_cnt <= free_cnt - 2'd1;
                if (free_cnt == 2'd1) begin
                    commit_valid <= 1'b1;   // 这条指令“提交”了
                    pending      <= 1'b0;
                end
            end
            if (in_valid && in_ready) begin  // fire
                $display("[be_sink] accept pc=%08h op=%0d rd=%0d imm=%0h",
                         in_insn.pc, in_insn.op, in_insn.rd, in_insn.imm);
                commit_pc <= in_insn.pc;
                if (LATENCY[1:0] != 2'd0) begin
                    free_cnt <= LATENCY[1:0];
                    pending  <= 1'b1;
                end else begin
                    commit_valid <= 1'b1;
                end
            end
        end
    end
endmodule
