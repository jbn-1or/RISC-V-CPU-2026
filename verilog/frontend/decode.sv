// Single-instruction RV32IM decoder.
// Combinational decode. The course omits CSR/FENCE/ECALL/EBREAK;
// unsupported opcodes produce OP_NOP. No exception interface is implemented.
module decode1 (
    input  wire [31:0] in_pc,
    input  wire [31:0] in_raw,
    output cpu_pkg::decoded_t   out_d
);
    logic [6:0] opcode;
    logic [4:0] rd, rs1, rs2;
    logic [2:0] f3;
    logic [6:0] f7;
    cpu_pkg::decoded_t t;
    assign opcode = in_raw[6:0];
    assign rd  = in_raw[11:7];
    assign rs1 = in_raw[19:15];
    assign rs2 = in_raw[24:20];
    assign f3  = in_raw[14:12];
    assign f7  = in_raw[31:25];

    // sign/zero shifted operands are built per-opcode below
    wire [31:0] imm_i = {{20{in_raw[31]}}, in_raw[31:20]};
    wire [31:0] imm_s = {{20{in_raw[31]}}, in_raw[31:25], in_raw[11:7]};
    wire [31:0] imm_b = {{19{in_raw[31]}}, in_raw[31], in_raw[7],
                         in_raw[30:25], in_raw[11:8], 1'b0};
    wire [31:0] imm_u = {in_raw[31:12], 12'b0};
    wire [31:0] imm_j = {{11{in_raw[31]}}, in_raw[31], in_raw[19:12],
                         in_raw[20], in_raw[30:21], 1'b0};

    always_comb begin
        // typed defaults (no implicit enum conversion)
        t.op = cpu_pkg::OP_NOP;
        t.fu = cpu_pkg::FU_ALU;
        t.imm = 32'b0;
        t.pc = in_pc;
        t.rd = rd; t.rs1 = rs1; t.rs2 = rs2;
        t.funct3 = f3; t.funct7 = f7;
        t.uses_rs1 = 1'b0; t.uses_rs2 = 1'b0; t.uses_imm = 1'b0;
        t.is_ret = 1'b0;
        case (opcode)
            7'h37: begin // LUI
                t.op = cpu_pkg::OP_LUI;   t.fu = cpu_pkg::FU_ALU; t.imm = imm_u; t.uses_imm = 1'b1; end
            7'h17: begin // AUIPC
                t.op = cpu_pkg::OP_AUIPC; t.fu = cpu_pkg::FU_ALU; t.imm = imm_u; t.uses_imm = 1'b1; end
            7'h6f: begin // JAL
                t.op = cpu_pkg::OP_JAL;   t.fu = cpu_pkg::FU_ALU; t.imm = imm_j; end
            7'h67: begin // JALR
                t.op = cpu_pkg::OP_JALR;  t.fu = cpu_pkg::FU_BR;  t.imm = imm_i;
                t.uses_rs1 = (rs1 != cpu_pkg::ZERO_REG);
                t.is_ret = (rd == 5'd0) && ((rs1 == 5'd1) || (rs1 == 5'd5)); end
            7'h63: begin // conditional branches
                t.op = cpu_pkg::OP_BR;    t.fu = cpu_pkg::FU_BR;  t.imm = imm_b;
                t.rd = 5'd0;   // B-type bits[11:7] are imm, no dest
                t.uses_rs1 = (rs1 != cpu_pkg::ZERO_REG); t.uses_rs2 = (rs2 != cpu_pkg::ZERO_REG); end
            7'h03: begin // loads
                t.op = cpu_pkg::OP_LOAD;  t.fu = cpu_pkg::FU_LSU; t.imm = imm_i;
                t.uses_rs1 = (rs1 != cpu_pkg::ZERO_REG); end
            7'h23: begin // stores
                t.op = cpu_pkg::OP_STORE; t.fu = cpu_pkg::FU_LSU; t.imm = imm_s;
                t.rd = 5'd0;   // S-type bits[11:7] are imm, no dest
                t.uses_rs1 = (rs1 != cpu_pkg::ZERO_REG); t.uses_rs2 = (rs2 != cpu_pkg::ZERO_REG); end
            7'h13: begin // I-type ALU
                t.op = cpu_pkg::OP_ALU;   t.fu = cpu_pkg::FU_ALU; t.imm = imm_i; t.uses_imm = 1'b1;
                t.uses_rs1 = (rs1 != cpu_pkg::ZERO_REG);
            end
            7'h33: begin // R-type
                t.uses_rs1 = (rs1 != cpu_pkg::ZERO_REG); t.uses_rs2 = (rs2 != cpu_pkg::ZERO_REG);
                if (f7 == 7'b0000001) begin // M extension
                    if (f3 <= 3'b011) begin t.op = cpu_pkg::OP_MUL; t.fu = cpu_pkg::FU_MUL; end
                    else begin t.op = cpu_pkg::OP_DIV; t.fu = cpu_pkg::FU_DIV; end
                end else if (f7 == 7'b0100000) begin
                    if (f3 == 3'b000 || f3 == 3'b101) begin
                        t.op = cpu_pkg::OP_ALU; t.fu = cpu_pkg::FU_ALU;
                    end else t.op = cpu_pkg::OP_NOP;
                end else if (f7 == 7'b0) begin
                    t.op = cpu_pkg::OP_ALU; t.fu = cpu_pkg::FU_ALU;
                end else t.op = cpu_pkg::OP_NOP;
            end
            default: begin
                t.op = cpu_pkg::OP_NOP;
            end
        endcase
        out_d = t;
    end
endmodule

// Two independent lanes; DIV and REM each issue as one instruction.
module decode (
    input  wire [1:0]       in_valid_s,
    input  wire [63:0]      in_pc_s,    // slot0 low half
    input  wire [63:0]      in_raw_s,   // slot0 low half
    output cpu_pkg::decoded_t  out_d0,
    output cpu_pkg::decoded_t  out_d1,
    output wire [1:0]       out_valid
);
    decode1 u0 (.in_pc(in_pc_s[31:0]),  .in_raw(in_raw_s[31:0]), .out_d(out_d0));
    decode1 u1 (.in_pc(in_pc_s[63:32]), .in_raw(in_raw_s[63:32]), .out_d(out_d1));
    assign out_valid = in_valid_s;
endmodule
