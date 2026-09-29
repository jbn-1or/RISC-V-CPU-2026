// 假前端：B 在写后端时用它喂固定的指令流。
// 只用于本地单元测试，绝不写进 verilog/filelist.f。
module fe_stub #(
    parameter int COUNT = 4              // 发多少条假指令
) (
    input  wire                     clock,
    input  wire                     reset,
    output logic                    out_valid,
    output cpu_pkg::decoded_t       out_insn,
    input  wire                     out_ready,
    output logic                    done
);
    import cpu_pkg::*;

    localparam logic [4:0] COUNT_Q = COUNT[4:0];

    logic [4:0] idx;

    // 发送方寄存 payload + valid（契约规定）
    assign out_valid = (idx < COUNT_Q);
    assign done      = (idx >= COUNT_Q);

    always_comb begin
        out_insn = '{pc:        {25'b0, idx, 2'b00},        // 0,4,8,12 ...
                     imm:       32'd1 + {27'b0, idx},      // 假立即数 1,2,3,4
                     rd:        idx,
                     rs1:       5'd0,
                     rs2:       5'd0,
                     op:        OP_ALU,
                     fu:        FU_ALU,
                     uses_rs1:  1'b0,
                     uses_rs2:  1'b0,
                     is_branch: 1'b0,
                     is_exit:   1'b0};
    end

    always_ff @(posedge clock) begin
        if (reset) idx <= 5'd0;
        else if (out_valid && out_ready) idx <= idx + 5'd1;  // 只在 fire 时前进
    end
endmodule
