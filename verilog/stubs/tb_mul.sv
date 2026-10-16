// Unit test: mul unit — MUL / MULH / MULHSU / MULHU over tricky operands.
`timescale 1ns/1ps
module tb_mul;
    import cpu_pkg::*;
    logic clock = 0, reset = 1;
    logic req_valid; logic [31:0] req_a, req_b;
    logic [2:0] req_f3;
    logic [$clog2(cpu_pkg::PRF_NUM)-1:0] ta; logic [$clog2(cpu_pkg::ROB_DEPTH)-1:0] ra;
    wire req_ready, wb_valid; wire [$clog2(cpu_pkg::PRF_NUM)-1:0] wb_tag; wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] wb_rob; wire [31:0] wb_data;

    mul u (.clock, .reset, .req_valid, .req_a, .req_b, .req_funct3(req_f3),
           .req_tag(ta), .req_rob(ra), .req_ready,
           .wb_valid, .wb_tag, .wb_rob, .wb_data);

    always #5 clock = ~clock;

    int errors;

    string opn;
    int seen;
    task automatic do_one(input logic [31:0] A, input logic [31:0] B,
                          input logic [2:0] F3, input logic [31:0] EXP);
        seen = 0;
        opn = (F3 == 3'd0) ? "MUL" : (F3 == 3'd1) ? "MULH" :
              (F3 == 3'd2) ? "MULHSU" : "MULHU";
        @(negedge clock);
        req_valid = 1; req_a = A; req_b = B; req_f3 = F3; ta = 6'd1; ra = 5'd0;
        @(negedge clock);
        req_valid = 0;
        repeat (30) begin
            @(negedge clock);
            if (wb_valid && wb_tag == 6'd1) begin
                seen = 1;
                if (wb_data !== EXP) begin
                    $display("FAIL %0d op=%s: got %h exp %h", $time, opn, wb_data, EXP);
                    errors++;
                end else $display("ok   %0d op=%s = %h", $time, opn, wb_data);
                break;
            end
        end
        if (seen == 0) begin $display("FAIL %0d op=%s: no WB", $time, opn); errors++; end
    endtask

    initial begin
        errors = 0;
        repeat (3) @(negedge clock);
        reset = 0;
        // low multiply
        do_one(32'd6, 32'd7, 3'd0, 32'd42);
        do_one(32'hdeadbeef, 32'hbaadf00d, 3'd0, 32'hdf55c223);
        // MULH signed using 64-bit math
        do_one(32'h80000000, 32'h2, 3'd1, 32'hffffffff);  // -2^31 * 2 = -2^32 -> high= -1
        do_one(32'h80000000, 32'h80000000, 3'd1, 32'h40000000); // (-2^31)^2 high = 2^62 high=0x40000000
        do_one(-32'd3, 32'd5, 3'd1, 32'hffffffff);        // -15 high = -1
        do_one(32'd7, 32'd11, 3'd1, 32'd0);
        // MULHSU: signed a x unsigned b
        do_one(32'h80000000, 32'hffffffff, 3'd2, 32'h80000000); // -2^31*(2^32-1) = -2^63+2^31 -> high 0x80000000
        do_one(-32'd3, 32'd5, 3'd2, 32'hffffffff);       // -15 high -1
        do_one(32'd7, 32'd11, 3'd2, 32'd0);
        // MULHU
        do_one(32'h80000000, 32'h2, 3'd3, 32'h00000001); // 2^31*2 = 2^32 high=1
        do_one(32'hffffffff, 32'hffffffff, 3'd3, 32'hfffffffe);
        do_one(32'd7, 32'd11, 3'd3, 32'd0);
        if (errors == 0) $display("[tb_mul] ALL OK");
        else $display("[tb_mul] %0d errors", errors);
        $finish;
    end
endmodule
