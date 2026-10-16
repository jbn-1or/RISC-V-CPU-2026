// Unit test: div unit on a battery of cases (incl. spec edge cases).
`timescale 1ns/1ps
module tb_div;
    import cpu_pkg::*;
    logic clock = 0, reset = 1;
    logic req_valid; logic [31:0] req_a, req_b;
    logic [2:0] req_f3a; logic [2:0] req_f3b; logic req_fused;
    logic [$clog2(cpu_pkg::PRF_NUM)-1:0] ta, tb2; logic [$clog2(cpu_pkg::ROB_DEPTH)-1:0] ra, rb;
    wire req_ready, wb_valid; wire [$clog2(cpu_pkg::PRF_NUM)-1:0] wb_tag; wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] wb_rob; wire [31:0] wb_data;

    div u (.clock, .reset, .req_valid, .req_a, .req_b, .req_f3a, .req_f3b,
           .req_fused, .req_tag_a(ta), .req_rob_a(ra), .req_tag_b(tb2),
           .req_rob_b(rb), .req_ready, .wb_valid, .wb_tag, .wb_rob, .wb_data);

    always #5 clock = ~clock;

    always @(negedge clock) if (wb_valid) $display("[tbsaw] t=%0t tag=%h data=%h state=%0d", $time, wb_tag, wb_data, u.state);

    int errors;
    task automatic do_one(input logic [31:0] A, input logic [31:0] B,
                          input logic [2:0] F3, input logic [31:0] EXP);
        string opn;
        int seen = 0;
        opn = (F3 == 3'd4) ? "DIV" : (F3 == 3'd5) ? "DIVU" :
              (F3 == 3'd6) ? "REM" : "REMU";
        @(negedge clock);
        req_valid = 1; req_a = A; req_b = B; req_f3a = F3; req_f3b = 3'd0;
        $display("[tb] req on a=%h b=%h t=%0t", A, B, $time);
        req_fused = 1'b0; ta = 6'd1; ra = 5'd2; tb2 = 6'd0; rb = 5'd3;
        @(negedge clock);
        req_valid = 0;   // request already fired at the posedge after drive
        $display("[tb] req off t=%0t", $time);
        // wait wb (tag=1)
        repeat (200) begin
            @(negedge clock);
            if (wb_valid && wb_tag == 6'd1) begin
                seen = 1;
                if (wb_data !== EXP) begin
                    $display("FAIL %0d op=%s: got %h exp %h", $time, opn, wb_data, EXP);
                    errors++;
                end else begin
                    $display("ok   %0d op=%s = %h", $time, opn, wb_data);
                end
                break;
            end
        end
        if (seen == 0) begin $display("FAIL %0d op=%s: no WB", $time, opn); errors++; end
    endtask

    initial begin : main
        errors = 0;
        repeat (3) @(negedge clock);
        reset = 0;
        // signed division
        do_one(32'd35018, 32'd3087, 3'd6, 32'd1061);   // 18 REM? no: 17: rem 35018%3087
        do_one(32'd100, 32'd7, 3'd4, 32'd14);          // DIV 100/7
        do_one(32'd100, 32'd7, 3'd6, 32'd2);           // REM
        do_one(32'd7, 32'd100, 3'd6, 32'd7);           // 7%100 = 7
        do_one(32'd5, 32'd0, 3'd4, 32'hffffffff);      // DIV x/0
        do_one(32'd5, 32'd0, 3'd6, 32'd5);             // REM x/0 = x
        do_one(32'h80000000, 32'hffffffff, 3'd4, 32'h80000000); // overflow DIV
        do_one(32'h80000000, 32'hffffffff, 3'd6, 32'd0);        // overflow REM
        do_one(-32'd17, 32'd5, 3'd6, -32'd2);          // -17%5 = -2
        do_one(-32'd17, 32'd5, 3'd4, -32'd3);          // -17/5 = -3
        do_one(-32'd17, -32'd5, 3'd6, -32'd2);         // -17%-5
        do_one(32'hffffffff, 32'd7, 3'd7, 32'd3);          // REMU 0xffffffff%7
        if (errors == 0) $display("[tb_div] ALL OK");
        else $display("[tb_div] %0d errors", errors);
        $finish;
    end
endmodule
