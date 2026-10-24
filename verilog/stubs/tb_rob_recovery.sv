// Compare parallel restore selection with a program-order reference scan.
// Fill the ROB, retire a prefix, wrap allocations, then check every possible
// flush point without clocking a flush into the deliberately fixed window.
`timescale 1ns/1ps
module tb_rob_recovery;
    import cpu_pkg::*;
    localparam int PB = $clog2(PRF_NUM);
    logic clock = 0, reset = 1;
    logic [1:0] disp_valid = 0;
    logic [4:0] rd0 = 0, rd1 = 0;
    logic [PB-1:0] dst0 = 0, dst1 = 0, old0 = 0, old1 = 0;
    logic mk0_valid = 0;
    logic [RB-1:0] mk0_rob = 0;
    writeback_t wb_a, wb_b;
    logic flush_valid = 0;
    logic [RB-1:0] flush_rob = 0;
    wire [RB-1:0] head_ptr, alloc_ptr;
    wire [RB:0] flush_dtail;
    wire [31:0] restore_valid;
    wire [32*PB-1:0] restore_pdst;
    int shadow_rd [0:ROB_DEPTH-1];
    int shadow_old [0:ROB_DEPTH-1];
    int shadow_dst [0:ROB_DEPTH-1];
    int serial = 0;

    rob dut (
        .clock, .reset, .disp_valid, .disp_rd0(rd0), .disp_rd1(rd1),
        .disp_pdst0(dst0), .disp_pdst1(dst1), .disp_old0(old0), .disp_old1(old1),
        .disp_load0(1'b0), .disp_load1(1'b0), .disp_store0(1'b0), .disp_store1(1'b0),
        .alloc_ptr, .head_ptr, .alloc_space(), .cst0_valid(), .cst0_rob(), .cst1_valid(), .cst1_rob(),
        .wb_a, .wb_b, .wb_a_ok(), .wb_b_ok(), .sched_b_candidate(wb_b),
        .sched_a_match(), .sched_b_match(), .rec_a_valid(), .rec_a_tag(), .rec_b_valid(), .rec_b_tag(),
        .mk0_valid, .mk0_rob, .mk1_valid(1'b0), .mk1_rob(RB'(0)),
        .ndone_valid(1'b0), .ndone_rob(RB'(0)), .cmt_free_mask(),
        .flush_valid, .flush_rob, .flush_dtail, .flush_free_mask(), .flush_pend_mask(),
        .restore_valid, .restore_pdst);

    task automatic tick;
        #5; clock = 1; #5; clock = 0;
    endtask
    function automatic int arch(input int seq);
        case (seq % 5)
            0: return 1;
            1: return 23;
            2: return 19;
            3: return 1;
            default: return 2;
        endcase
    endfunction
    task automatic push_pair;
        int slot;
        slot = int'(alloc_ptr);
        rd0 = 5'(arch(serial)); rd1 = 5'(arch(serial+1));
        dst0 = PB'(32+serial%32); dst1 = PB'(32+(serial+1)%32);
        old0 = PB'(serial+1); old1 = PB'(serial+2);
        shadow_rd[slot] = int'(rd0); shadow_old[slot] = int'(old0); shadow_dst[slot] = int'(dst0);
        shadow_rd[(slot+1)%ROB_DEPTH] = int'(rd1);
        shadow_old[(slot+1)%ROB_DEPTH] = int'(old1);
        shadow_dst[(slot+1)%ROB_DEPTH] = int'(dst1);
        disp_valid = 3; tick(); disp_valid = 0; serial = serial+2;
    endtask
    task automatic check_window;
        int limit, slot, expected, seen;
        for (int f = 0; f < ROB_DEPTH; f++) begin
            flush_rob = RB'(f); flush_valid = 1; #1;
            limit = (int'(alloc_ptr)-f+ROB_DEPTH)%ROB_DEPTH;
            if (limit == 0) limit = ROB_DEPTH;
            if (int'(flush_dtail) != limit) $fatal(1, "wrong flush distance");
            for (int r = 0; r < 32; r++) begin
                expected = 0; seen = 0;
                for (int n = 1; n < limit; n++) begin
                    slot = (f+n)%ROB_DEPTH;
                    if (!seen && r != 0 && shadow_rd[slot] == r) begin
                        expected = shadow_old[slot]; seen = 1;
                    end
                end
                if (restore_valid[r] != 1'(seen) ||
                    (seen && restore_pdst[r*PB +: PB] !== PB'(expected)))
                    $fatal(1, "restore head=%0d tail=%0d flush=%0d arch=%0d got=%0d expected=%0d",
                           head_ptr, alloc_ptr, f, r, restore_pdst[r*PB +: PB], expected);
            end
            flush_valid = 0; #1;
        end
    endtask
    initial begin
        wb_a = '0; wb_b = '0; tick(); tick(); reset = 0;
        repeat (ROB_DEPTH/2) push_pair();
        check_window();
        // Complete and retire an old prefix through the real ROB interfaces.
        for (int i = 0; i < ROB_DEPTH/2; i++) begin
            mk0_valid = 1; mk0_rob = RB'(i); tick(); mk0_valid = 0;
            wb_a.valid = 1; wb_a.rob = RB'(i); wb_a.prf_tag = PB'(shadow_dst[i]);
            tick(); wb_a.valid = 0; tick();
        end
        if (head_ptr != RB'(ROB_DEPTH/2)) $fatal(1, "retirement setup failed");
        repeat (ROB_DEPTH/4) push_pair();
        check_window();
        $display("PASS: ROB%0d oldest-writer restore, every flush point, full and wrapped windows", ROB_DEPTH);
        $finish;
    end
endmodule
