// A store accepted on its producer's writeback cycle must carry ready data,
// even when WB_BYPASS=0 defers ordinary ALU wakeup until the next cycle.
`timescale 1ns/1ps
module tb_store_wakeup;
    import cpu_pkg::*;
    logic clock = 0, reset = 1;
    always #5 clock = ~clock;
    logic [1:0] disp_valid = 0;
    logic lsu_free = 0;
    renamed_t d0, d1;
    writeback_t wb_a, wb_b;
    wire [1:0] iss_valid;
    issue_t iss0, iss1;
    iq dut (
        .clock, .reset, .disp_valid, .d0, .d1, .space(), .wb_a, .wb_b,
        .rob_head(RB'(0)), .flush_valid(1'b0), .flush_rob(RB'(0)), .flush_dtail((RB+1)'(0)),
        .alu0_free(1'b1), .alu1_free(1'b1), .bru_free(1'b1), .mul_free(1'b1), .div_free(1'b1),
        .lsu_free_ld(lsu_free), .lsu_free_st(lsu_free), .iss_valid, .iss0, .iss1,
        .port0(), .port1(), .iss0_v(), .iss0_rob(), .iss1_v(), .iss1_rob());
    initial begin
        d0 = '0; d1 = '0; wb_a = '0; wb_b = '0;
        d0.insn.op = OP_STORE; d0.insn.fu = FU_LSU;
        d0.rs1_ready = 1; d0.rs2_ready = 0; d0.ps2 = 33;
        repeat (3) @(negedge clock); reset = 0; disp_valid = 1;
        @(negedge clock); disp_valid = 0;
        if (iss_valid != 0) $fatal(1, "store issued while LSU was blocked");
        wb_a.valid = 1; wb_a.prf_tag = 33; wb_a.result = 32'h1234abcd; lsu_free = 1;
        #1;
        if (!iss_valid[0] || !iss0.rs2_ready || iss0.ps2 != 33)
            $fatal(1, "same-cycle store writeback lost with WB_BYPASS=%0d", WB_BYPASS);
        @(negedge clock); wb_a = '0;
        $display("PASS: store ready on same-cycle producer writeback, WB_BYPASS=%0d", WB_BYPASS);
        $finish;
    end
    initial begin #10000; $fatal(1, "timeout"); end
endmodule
