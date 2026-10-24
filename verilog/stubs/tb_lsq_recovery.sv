// Recovery pauses load scheduling for one cycle. Older loads must resume,
// younger loads/stores must disappear, and retired stores must keep draining.
`timescale 1ns/1ps
module tb_lsq_recovery;
    import cpu_pkg::*;
    localparam int PB = $clog2(PRF_NUM);
    logic clock = 0, reset = 1;
    logic in_valid = 0;
    op_e in_op = OP_LOAD;
    logic [31:0] in_base = 0;
    logic [PB-1:0] in_pdst = 0;
    logic [RB-1:0] in_rob = 0;
    logic [1:0] cmt_valid = 0;
    logic flush_valid = 0, ld_ready = 0, st_ready = 0;
    logic resp_valid = 0;
    mem_resp_t resp;
    writeback_t wb_zero;
    wire ld_valid, st_valid, wb_valid;
    wire [31:0] wb_data;
    wire [RB-1:0] wb_rob;
    mem_req_t ld_req, st_req;

    load_store_queue dut (
        .clock, .reset, .in_valid, .in_op, .in_funct3(3'd2),
        .in_base, .in_imm(32'd0), .in_store_data(32'h12345678), .in_pdst, .in_rob,
        .in_ps2(PB'(0)), .in_rs2_ready(1'b1), .wb_a(wb_zero), .wb_b(wb_zero),
        .ld_alloc_ok(), .st_alloc_ok(), .wb_valid, .wb_tag(), .wb_rob, .wb_data,
        .wb_ready(1'b1), .ndone_valid(), .ndone_rob(), .rob_head(RB'(0)),
        .cmt_valid, .cmt_rob0(RB'(1)), .cmt_rob1(RB'(0)),
        .flush_valid, .flush_rob(RB'(4)), .flush_dtail((RB+1)'(4)),
        .ld_valid, .ld_req, .ld_ready, .st_valid, .st_req, .st_ready,
        .resp_valid, .resp, .resp_replay(1'b0), .probe_addr(), .probe_set_valid(1'b0));

    task automatic tick;
        #5; clock = 1; #5; clock = 0;
    endtask
    task automatic issue(input op_e op, input int rob, input int addr, input int pdst);
        in_valid = 1; in_op = op; in_rob = RB'(rob);
        in_base = 32'(addr); in_pdst = PB'(pdst);
        tick(); in_valid = 0;
    endtask
    initial begin
        wb_zero = '0; resp = '0;
        tick(); tick(); reset = 0;
        issue(OP_STORE, 1, 'h400, 0);
        cmt_valid = 1; tick(); cmt_valid = 0;
        issue(OP_LOAD, 2, 'h100, 33);
        issue(OP_LOAD, 6, 'h200, 34);
        issue(OP_STORE, 7, 'h500, 0);
        #1;
        if (!ld_valid || ld_req.rob != RB'(2) || !st_valid || st_req.rob != RB'(1))
            $fatal(1, "recovery setup failed");

        flush_valid = 1; st_ready = 1; #1;
        if (ld_valid || !st_valid || st_req.rob != RB'(1))
            $fatal(1, "recovery must pause loads while retaining retired stores");
        tick(); flush_valid = 0; st_ready = 0; #1;
        if (!ld_valid || ld_req.rob != RB'(2))
            $fatal(1, "older load did not resume after recovery");
        ld_ready = 1; tick(); ld_ready = 0;

        resp_valid = 1; resp.valid = 1; resp.rob = RB'(2); resp.rdata = 32'habcdef01;
        #1;
        if (!wb_valid || wb_rob != RB'(2) || wb_data != 32'habcdef01)
            $fatal(1, "older load response lost");
        tick(); resp_valid = 0; resp = '0;
        resp_valid = 1; resp.valid = 1; resp.is_store = 1; resp.rob = RB'(1);
        tick(); resp_valid = 0; resp = '0;
        repeat (8) begin
            #1;
            if (ld_valid || st_valid || wb_valid)
                $fatal(1, "killed operation survived recovery");
            tick();
        end
        $display("PASS: LSQ recovery pauses loads, preserves older load and retired store, kills younger operations");
        $finish;
    end
endmodule
