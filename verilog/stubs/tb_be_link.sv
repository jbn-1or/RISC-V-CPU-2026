// Backend link unit test: core_ooo (rename/rob/iq/prf + FUs + blocking LSU)
// driven by a synthetic instruction stream, with a local memory stub.
// Program checks: ALU chain, MUL/DIV, load/store, and a taken branch that is
// predicted not-taken: the wrong-path store must be flushed, so the final
// value read from memory stays intact.
`timescale 1ns/1ps
module tb_be_link;
    import cpu_pkg::*;
    logic clock = 0, reset = 1;
    always #5 clock = ~clock;

    // ---------------- program ROM ----------------
    logic [31:0] rom [0:63];
    initial begin
        for (int i = 0; i < 64; i = i + 1) rom[i] = 32'h00000013; // nop
        rom[0]  = 32'h00500093; // addi x1,x0,5
        rom[1]  = 32'h00700113; // addi x2,x0,7
        rom[2]  = 32'h002081b3; // add  x3,x1,x2   = 12
        rom[3]  = 32'hfff00213; // addi x4,x0,-1
        rom[4]  = 32'h022082b3; // mul  x5,x1,x2   = 35
        rom[5]  = 32'h0212c333; // div  x6,x5,x1   = 7
        rom[6]  = 32'h00302023; // sw   x3,0(x0)   mem[0]=12
        rom[7]  = 32'h00002383; // lw   x7,0(x0)   = 12
        rom[8]  = 32'h00338463; // beq  x7,x3,+8   taken (mispredict -> flush)
        rom[9]  = 32'h00002023; // sw   x0,0(x0)   wrong path (must be killed)
        rom[10] = 32'h00002403; // lw   x8,0(x0)   = 12
        rom[11] = 32'h00300493; // addi x9,x0,3
        rom[12] = 32'h00940533; // add  x10,x8,x9  = 15
        rom[13] = 32'h006285b3; // add  x11,x5,x6  = 42
        rom[14] = 32'h00b50633; // add  x12,x10,x11= 57
        rom[15] = 32'h80000f37; // lui  x30,0x80000
        rom[16] = 32'h00cf2023; // sw   x12,0(x30) -> exit with 57
    end

    // ---------------- fe driver ----------------
    logic [31:0] fpc;
    logic [1:0]  fe_valid;
    fe2rn_t fe0, fe1;

    wire [5:0] idx0 = fpc[7:2];
    wire [31:0] raw0 = rom[idx0];
    wire [31:0] raw1 = rom[idx0 + 6'd1];
    decoded_t d0, d1;
    decode1 dec0 (.in_pc(fpc),         .in_raw(raw0), .out_d(d0));
    decode1 dec1 (.in_pc(fpc + 32'd4), .in_raw(raw1), .out_d(d1));

    always_comb begin
        fe0 = '0;
        fe0.insn  = d0;
        fe1 = '0;
        fe1.insn  = d1;
        fe_valid  = {(fpc < 32'd92), (fpc < 32'd96)};
    end

    // ---------------- core ----------------
    logic [1:0] fe_take;
    flush_t     flush_out;
    wire [5:0]  flush_dtail;
    mem_req_t  ld_req, st_req;
    wire       ld_valid, ld_ready, st_valid, st_ready;
    mem_resp_t resp;
    wire       resp_valid, resp_replay;

    core_ooo u_core (
        .clock, .reset,
        .fe_valid, .fe0, .fe1, .fe_take, .flush_out,
        .flush_dtail_out(flush_dtail),
        .br_upd_valid(), .br_upd_pc(), .br_upd_taken(),
        .btb_upd_valid(), .btb_upd_pc(), .btb_upd_target(),
        .ld_valid, .ld_req, .ld_ready,
        .st_valid, .st_req, .st_ready,
        .resp_valid, .resp, .resp_replay
    );

    always_ff @(posedge clock) begin
        if (reset) begin
            fpc <= 32'd0;
        end else if (flush_out.valid) begin
            fpc <= flush_out.pc;
        end else if (fe_take[0]) begin
            fpc <= fpc + (fe_take[0] ? 32'd4 : 32'd0) + (fe_take[1] ? 32'd4 : 32'd0);
        end
    end

    // ---------------- A-side memory stub (plays memory_subsystem) ----------------
    // Loads: accepted immediately, answered after a fixed latency, paired by
    // rob. Stores: accepted when idle, applied to memory, completion
    // (is_store=1) returned after a fixed latency, in order.
    logic [31:0] mem [0:255];
    localparam int LD_LAT = 3, ST_LAT = 3;

    logic        ldq_v [0:7];
    logic [$clog2(cpu_pkg::ROB_DEPTH)-1:0] ldq_rob [0:7];
    logic [5:0]  ldq_addr [0:7];
    logic [2:0]  ldq_wait [0:7];
    logic [2:0]  ldq_tail;
    logic        ldq_full;

    logic        stq_v [0:3];
    logic [$clog2(cpu_pkg::ROB_DEPTH)-1:0] stq_rob [0:3];
    logic [31:0] stq_addr, stq_data;
    logic [3:0]  stq_strb;
    logic [2:0]  stq_wait;
    logic [1:0]  stq_tail;
    logic        st_busy;

    wire ld_accept = ld_valid && ld_ready;
    wire st_accept = st_valid && st_ready;

    assign ld_ready = !ldq_full;
    assign st_ready = !st_busy;
    assign ldq_full = ldq_v[ldq_tail];

    always_comb begin
        resp = '0;
        resp.valid    = 1'b0;
        resp.is_store = 1'b0;
        resp.rob      = '0;
        resp.rdata    = 32'd0;
        // oldest store completion wins
        for (int i = 0; i < 4; i = i + 1)
            if (stq_v[i] && (stq_wait == 3'd0) && !resp.valid) begin
                resp.valid = 1'b1; resp.is_store = 1'b1; resp.rob = stq_rob[i];
            end
        if (!resp.valid)
            for (int i = 0; i < 8; i = i + 1)
                if (ldq_v[i] && (ldq_wait[i] == 3'd0) && !resp.valid) begin
                    resp.valid = 1'b1; resp.rob = ldq_rob[i];
                    resp.rdata = mem[ldq_addr[i][9:2]];
                end
    end
    assign resp_valid = resp.valid;
    assign resp_replay = 1'b0;

    always_ff @(posedge clock) begin
        if (reset) begin
            for (int i = 0; i < 8; i = i + 1) ldq_v[i] <= 1'b0;
            for (int i = 0; i < 4; i = i + 1) stq_v[i] <= 1'b0;
            ldq_tail <= '0; stq_tail <= '0; st_busy <= 1'b0; stq_wait <= '0;
        end else begin
            // load queue
            if (ld_accept) begin
                ldq_v[ldq_tail]    <= 1'b1;
                ldq_rob[ldq_tail]  <= ld_req.rob;
                ldq_addr[ldq_tail] <= ld_req.addr[9:2];
                ldq_wait[ldq_tail] <= LD_LAT[2:0];
                ldq_tail <= ldq_tail + 3'd1;
            end
            for (int i = 0; i < 8; i = i + 1) begin
                if (ldq_v[i]) begin
                    if (ldq_wait[i] == 3'd0) begin
                        if (resp_valid && !resp.is_store && (resp.rob == ldq_rob[i]))
                            ldq_v[i] <= 1'b0;
                    end else ldq_wait[i] <= ldq_wait[i] - 3'd1;
                end
            end
            // store queue
            if (st_accept) begin
                stq_v[stq_tail]  <= 1'b1;
                stq_rob[stq_tail]<= st_req.rob;
                stq_addr <= st_req.addr; stq_data <= st_req.wdata;
                stq_strb <= st_req.wstrb;
                stq_wait <= ST_LAT[2:0];
                stq_tail <= stq_tail + 2'd1;
                st_busy  <= 1'b1;
            end else if (st_busy) begin
                if (stq_wait == 3'd1) begin
                    if (stq_addr[31:28] == 4'h0)
                        for (int b = 0; b < 4; b = b + 1)
                            if (stq_strb[b])
                                mem[stq_addr[9:2]][b*8 +: 8] <= stq_data[b*8 +: 8];
                    if ((stq_addr == 32'h80000000) && (stq_strb == 4'hf)) begin
                        done <= 1'b1; result <= stq_data;
                    end
                end
                if (stq_wait == 3'd0) st_busy <= 1'b0;
                else stq_wait <= stq_wait - 3'd1;
            end
            for (int i = 0; i < 4; i = i + 1) begin
                if (stq_v[i]) begin
                    if ((stq_wait == 3'd0) && resp_valid && resp.is_store &&
                        (resp.rob == stq_rob[i]))
                        stq_v[i] <= 1'b0;
                end
            end
        end
    end
    logic done;
    logic [31:0] result;

    // ---------------- run ----------------
    int cyc;
    initial begin
        for (int i = 0; i < 256; i = i + 1) mem[i] = 32'd0;
        repeat (5) @(negedge clock);
        reset = 0;
        cyc = 0;
        while (!done && cyc < 4000) begin
            @(negedge clock);
            cyc = cyc + 1;
        end
        if (!done) begin
            $display("[tb_be_link] FAIL: timeout (no exit write) cyc=%0d", cyc);
        end else if (result !== 32'd57) begin
            $display("[tb_be_link] FAIL: exit result %0d (exp 57) cyc=%0d mem0=%0d",
                     result, cyc, mem[0]);
        end else begin
            $display("[tb_be_link] ALL OK: result=%0d cyc=%0d mem0=%0d", result, cyc, mem[0]);
        end
        $finish;
    end
endmodule
