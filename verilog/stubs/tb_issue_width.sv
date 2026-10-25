// ISSUE_WIDTH must change the maximum number of actual IQ grants.
`timescale 1ns/1ps
module tb_issue_width;
    import cpu_pkg::*;
    logic clock = 0, reset = 1;
    always #5 clock = ~clock;
    logic [1:0] disp_valid = 0;
    logic [RB-1:0] rob_head = '0;
    renamed_t d0, d1;
    writeback_t wb_a, wb_b;
    wire [1:0] iss_valid;
    issue_t iss0, iss1;
    int total = 0, peak = 0;
    iq dut (
        .clock, .reset, .disp_valid, .d0, .d1, .space(), .wb_a, .wb_b,
        .rob_head, .flush_valid(1'b0), .flush_rob(RB'(0)), .flush_dtail((RB+1)'(0)),
        .alu0_free(1'b1), .alu1_free(1'b1), .bru_free(1'b1),
        .mul_free(1'b1), .div_free(1'b1), .lsu_free_ld(1'b1), .lsu_free_st(1'b1),
        .iss_valid, .iss0, .iss1, .port0(), .port1(),
        .iss0_v(), .iss0_rob(), .iss1_v(), .iss1_rob());
    always @(posedge clock) if (!reset) begin
        int count;
        count = int'(iss_valid[0]) + int'(iss_valid[1]);
        if (count > ISSUE_WIDTH) $fatal(1, "issued %0d with ISSUE_WIDTH=%0d", count, ISSUE_WIDTH);
        if (count > peak) peak = count;
        total = total + count;
    end
    initial begin
        d0 = '0; d1 = '0; wb_a = '0; wb_b = '0;
        d0.insn.op = OP_ALU; d0.insn.fu = FU_ALU;
        d0.rs1_ready = 1; d0.rs2_ready = 1;
        d1 = d0; d1.rob = RB'(1);
        repeat (3) @(negedge clock);
        reset = 0; disp_valid = 3;
        @(negedge clock); disp_valid = 0;
        repeat (5) @(negedge clock);
        if (total != 2 || peak != ISSUE_WIDTH)
            $fatal(1, "wrong grant count total=%0d peak=%0d width=%0d", total, peak, ISSUE_WIDTH);
        // An older instruction waiting for a producer must not prevent a
        // younger independent instruction from executing out of order.
        reset = 1;
        repeat (2) @(negedge clock);
        reset = 0;
        d0.ps1 = $clog2(PRF_NUM)'(33); d0.rs1_ready = 0;
        d1.ps1 = '0; d1.rs1_ready = 1;
        disp_valid = 3;
        @(negedge clock); disp_valid = 0;
        #1;
        if (iss_valid != 1 || iss0.rob != RB'(1))
            $fatal(1, "younger ready instruction did not bypass blocked older instruction");
        @(negedge clock);
        #1;
        if (iss_valid != 0)
            $fatal(1, "older instruction issued before its operand became ready");
        wb_a.valid = 1; wb_a.prf_tag = $clog2(PRF_NUM)'(33);
        @(negedge clock); wb_a = '0;
        repeat (3) @(negedge clock);
        if (total != 4) $fatal(1, "out-of-order wakeup lost or duplicated a grant");
        // Memory selection must follow ROB ring order even when the rotating
        // slot priority prefers the younger load. Exercise every head, with
        // both tags before/after head and with a pair crossing physical wrap.
        for (int head = 0; head < ROB_DEPTH; head++) begin
            int distance;
            reset = 1;
            @(negedge clock);
            reset = 0; rob_head = RB'(head);
            distance = head % (ROB_DEPTH-1);
            d0 = '0; d0.insn.op = OP_LOAD; d0.insn.fu = FU_LSU;
            d0.rs1_ready = 1; d0.rs2_ready = 1;
            d0.rob = RB'(head+distance);
            d1 = d0; d1.rob = RB'(head+distance+1);
            disp_valid = 3;
            @(negedge clock); disp_valid = 0;
            dut.rot_q = $clog2(IQ_DEPTH)'(1);
            #1;
            if (iss_valid != 1 || iss0.rob != d0.rob)
                $fatal(1, "LSU oldest selection failed: head=%0d older=%0d younger=%0d", head, d0.rob, d1.rob);
            @(negedge clock);
            #1;
            if (iss_valid != 1 || iss0.rob != d1.rob)
                $fatal(1, "LSU lost younger load after oldest grant");
            @(negedge clock);
        end
        $display("PASS: ISSUE_WIDTH=%0d, peak=%0d, total=%0d", ISSUE_WIDTH, peak, total);
        $finish;
    end
    initial begin #10000; $fatal(1, "timeout"); end
endmodule
