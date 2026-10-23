// Branch/JALR resolution unit.
// Computes condition per funct3 and the true target; compares against the
// predictor's direction/target, and the caller
// turns a mismatch into a flush_t broadcast.
module bru (
    input  wire        in_valid,
    input  wire cpu_pkg::op_e   in_op,        // OP_BR or OP_JALR
    input  wire [2:0]  in_funct3,
    input  wire [31:0] in_a,
    input  wire [31:0] in_b,
    input  wire [31:0] in_pc,
    input  wire [31:0] in_imm,
    input  wire        in_pred_taken,
    input  wire [31:0] in_pred_target,
    output wire [31:0] out_link,     // pc+4 (JALR link)
    output wire        out_taken,
    output wire [31:0] out_target,
    output wire        out_mispred
);
    logic cond;
    always_comb begin
        case (in_funct3)
            3'b000:  cond = (in_a == in_b);                        // BEQ
            3'b001:  cond = (in_a != in_b);                        // BNE
            3'b100:  cond = ($signed(in_a) < $signed(in_b));        // BLT
            3'b101:  cond = ($signed(in_a) >= $signed(in_b));       // BGE
            3'b110:  cond = (in_a < in_b);                         // BLTU
            3'b111:  cond = (in_a >= in_b);                        // BGEU
            default: cond = 1'b0;
        endcase
    end

    wire [31:0] tgt_br  = in_pc + in_imm;
    wire [31:0] tgt_jalr = (in_a + in_imm) & 32'hfffffffe; // &~1

    assign out_taken   = (in_op == cpu_pkg::OP_JALR) ? 1'b1 : (cond && in_valid);
    assign out_target  = (in_op == cpu_pkg::OP_JALR) ? tgt_jalr : tgt_br;
    assign out_link    = in_pc + 32'd4;                    // JALR link value
    assign out_mispred = (out_taken != in_pred_taken) ||
                         (out_taken && (out_target != in_pred_target));
endmodule
