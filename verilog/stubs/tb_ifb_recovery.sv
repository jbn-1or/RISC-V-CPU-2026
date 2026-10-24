// Every IFB entry is younger than a branch already dispatched to the backend.
// Seed legal queue states to cover large ROB windows and sequence wrap without
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
            for (int seq_base = 0; seq_base < 64; seq_base += 15) begin
                int distance;
                distance = (ROB_DEPTH > 40) ? 40 : ROB_DEPTH-1;
                // A partial, physically wrapped FIFO must also be cleared.
                dut.ifb_head = 5;
                dut.ifb_tail = 3'((5+count)%8);
                dut.ifb_cnt = 4'(count);
                for (int i = 0; i < count; i++) begin
                    fe2rn_t entry;
                    entry = '0; entry.valid = 1;
                    entry.bsf = 6'(seq_base + distance);
                    dut.ifb_mem[(5+i)%8] = entry;
                end
                flush.valid = 1; flush.bsf = 6'(seq_base); flush.pc = 32'h100;
                #1;
                if (fe_valid[0] != 1) $fatal(1, "IFB setup failed");
                tick();
                if (fe_valid != 0 || dut.ifb_cnt != 0)
                    $fatal(1, "IFB retained wrong-path entries: ROB=%0d count=%0d seq=%0d distance=%0d",
                           ROB_DEPTH, count, seq_base, distance);
                flush.valid = 0;
            end
        end
        $display("PASS: IFB recovery clears all younger entries, ROB%0d, partial/full/wrapped queue and branch sequence", ROB_DEPTH);
        $finish;
    end
endmodule
