// ALU. Serves OP_LUI/AUIPC/JAL plus OP_ALU (funct3/funct7
// routed). B operand is pre-selected by the caller from uses_imm.
module alu (
    input  wire        in_valid,
    input  wire cpu_pkg::op_e   in_op,
    input  wire [2:0]  in_funct3,
    input  wire [6:0]  in_funct7,
    input  wire        in_uses_imm,  // I-type gate: funct7 slices of an immediate
    input  wire [31:0] in_a,
    input  wire [31:0] in_b,
    input  wire [31:0] in_pc,
    input  wire [31:0] in_imm,
    output wire [31:0] out_res
);
    wire [4:0] shamt = in_b[4:0];
    wire signed [31:0] sa = in_a;

    logic [31:0] r;
    always_comb begin
        if (!in_valid) r = 32'b0;
        else case (in_op)
            cpu_pkg::OP_LUI:   r = in_imm;
            cpu_pkg::OP_AUIPC: r = in_pc + in_imm;
            cpu_pkg::OP_JAL:   r = in_pc + 32'd4;
            cpu_pkg::OP_ALU: case (in_funct3)
                3'b000: r = (!in_uses_imm && in_funct7[5]) ? (in_a - in_b) : (in_a + in_b);
                3'b001: r = in_a << shamt;
                3'b010: r = {31'b0, $signed(in_a) < $signed(in_b)};
                3'b011: r = {31'b0, (in_a < in_b)};
                3'b100: r = in_a ^ in_b;
                // Keep the unsigned SRL operand out of the SRA expression's
                // signedness context (a ternary here turns >>> into >>).
                3'b101: begin
                    if (in_funct7[5]) r = sa >>> shamt;
                    else             r = in_a >> shamt;
                end
                3'b110: r = in_a | in_b;
                3'b111: r = in_a & in_b;
                default: r = 32'b0;
            endcase
            default: r = 32'b0;
        endcase
    end
    assign out_res = r;
endmodule
