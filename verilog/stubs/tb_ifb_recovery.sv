// Every IFB entry is younger than a branch already dispatched to the backend.
// Seed legal queue states to cover every queue occupancy and physical wrap without
// depending on instruction-cache warmup or a particular memory latency.
`timescale 1ns/1ps
module tb_ifb_recovery;
    import cpu_pkg::*;
    logic clock = 0, reset = 1;
    flush_t flush;
    decoded_t d0, d1;
    wire [1:0] fe_valid;
    fetch_unit dut (
        .clock, .reset, .flush, .flush_next_pc(32'h108),
        .dec_pc_s(), .dec_raw_s(), .dec_valid_s(), .dec_out_valid(2'b0),
        .dec_d0(d0), .dec_d1(d1), .fe_valid, .fe0(), .fe1(), .fe_take(2'b0),
        .br_upd_valid(1'b0), .br_upd_pc(32'b0), .br_upd_taken(1'b0),
        .br_upd_ix($clog2(BHT_ENTRIES)'(0)), .br_upd_mispred(1'b0),
        .btb_upd_valid(1'b0), .btb_upd_pc(32'b0), .btb_upd_target(32'b0),
        .rd_push_valid(), .rd_push_addr(), .rd_push_idx(), .rd_push_ready(1'b0),
        .rd_rsp_valid(1'b0), .rd_rsp_idx(5'b0), .rd_rsp_data(32'b0), .rd_rsp_ready());
    task automatic tick;
        #5; clock = 1; #5; clock = 0;
    endtask
    initial begin
        d0 = '0; d1 = '0; flush = '0;
        tick(); tick(); reset = 0;
        for (int count = 1; count <= 8; count++) begin
            for (int head = 0; head < 8; head++) begin
                // A partial, physically wrapped FIFO must also be cleared.
                dut.ifb_head = 3'(head);
                dut.ifb_tail = 3'((head+count)%8);
                dut.ifb_cnt = 4'(count);
                for (int i = 0; i < count; i++) begin
                    fe2rn_t entry;
                    entry = '0;
                    entry.insn.pc = 32'(4*i);
                    dut.ifb_mem[(head+i)%8] = entry;
                end
                flush.valid = 1; flush.pc = 32'h100;
                #1;
                if (fe_valid[0] != 1) $fatal(1, "IFB setup failed");
                tick();
                if (fe_valid != 0 || dut.ifb_cnt != 0)
                    $fatal(1, "IFB retained wrong-path entries: ROB=%0d count=%0d head=%0d",
                           ROB_DEPTH, count, head);
                flush.valid = 0;
            end
        end
        $display("PASS: IFB recovery clears all younger entries, ROB%0d, every occupancy and head", ROB_DEPTH);
        $finish;
    end
endmodule
