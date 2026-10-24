// Conflict addresses distinguish real two-way storage from an unused ASSOC.
// Also cover replacement, byte hit-updates and invalidation of either way.
`timescale 1ns/1ps
module tb_cache_assoc;
    import cpu_pkg::*;
    logic clock = 0, reset = 1;
    always #5 clock = ~clock;
    logic ld_valid = 0;
    logic [31:0] ld_addr = 0;
    wire ld_ready, ld_rsp_valid, ld_replay;
    wire [31:0] ld_data;
    logic su_valid = 0, inv_valid = 0;
    logic [31:0] su_addr = 0, inv_addr = 0;
    wire su_ready, su_hit;
    wire dr_valid;
    wire [31:0] dr_addr;
    wire [4:0] dr_idx;
    logic ds_valid = 0;
    logic [31:0] ds_data = 0;
    logic [4:0] ds_idx = 0;
    int dreads = 0, ireads = 0;
    logic if_valid = 0;
    logic [31:0] if_addr = 0;
    wire if_busy, if_rsp_valid, ir_valid;
    wire [31:0] if_w0, if_w1, ir_addr;
    wire [4:0] ir_idx;
    logic is_valid = 0;
    logic [31:0] is_data = 0;
    logic [4:0] is_idx = 0;
    localparam logic [31:0] DA = 32'h40000;
    localparam logic [31:0] DB = DA + DC_LINES * LINE_BYTES;
    localparam logic [31:0] DC = DB + DC_LINES * LINE_BYTES;
    localparam logic [31:0] IA = 32'h1000;
    localparam logic [31:0] IB = IA + IC_LINES * LINE_BYTES;
    localparam logic [31:0] IC = IB + IC_LINES * LINE_BYTES;

    function automatic logic [31:0] value(input logic [31:0] addr);
        return 32'h12345678 ^ addr;
    endfunction

    dcache dc (
        .clock, .reset, .lk_valid(ld_valid), .lk_addr(ld_addr), .lk_token(RB'(1)), .lk_ready(ld_ready),
        .probe_addr(DA), .probe_set_valid(), .rsp_valid(ld_rsp_valid), .rsp_token(),
        .rsp_data(ld_data), .rsp_replay(ld_replay), .rsp_ready(1'b1),
        .su_valid, .su_addr, .su_data(32'h0000ab00), .su_strb(4'b0010),
        .su_ready, .su_hit, .su_stall(), .inv_valid, .inv_addr,
        .flush_valid(1'b0), .flush_rob(RB'(0)), .flush_dtail((RB+1)'(0)),
        .rd_push_valid(dr_valid), .rd_push_addr(dr_addr), .rd_push_idx(dr_idx), .rd_push_ready(1'b1),
        .rd_rsp_valid(ds_valid), .rd_rsp_idx(ds_idx), .rd_rsp_data(ds_data), .rd_rsp_ready());
    icache ic (
        .clock, .reset, .req_valid(if_valid), .req_addr(if_addr), .busy(if_busy),
        .rsp_valid(if_rsp_valid), .rsp_word0(if_w0), .rsp_word1(if_w1),
        .rd_push_valid(ir_valid), .rd_push_addr(ir_addr), .rd_push_idx(ir_idx), .rd_push_ready(1'b1),
        .rd_rsp_valid(is_valid), .rd_rsp_idx(is_idx), .rd_rsp_data(is_data), .rd_rsp_ready());

    always @(posedge clock) begin
        if (reset) begin
            ds_valid <= 0; is_valid <= 0; dreads = 0; ireads = 0;
        end else begin
            ds_valid <= dr_valid; ds_idx <= dr_idx; ds_data <= value(dr_addr);
            is_valid <= ir_valid; is_idx <= ir_idx; is_data <= value(ir_addr);
            if (dr_valid) dreads = dreads + 1;
            if (ir_valid) ireads = ireads + 1;
        end
    end

    task automatic load(input logic [31:0] addr, input logic [31:0] expected);
        logic accepted;
        accepted = 0; ld_valid = 1; ld_addr = addr;
        while (!accepted) begin
            @(posedge clock); accepted = ld_ready;
            @(negedge clock);
        end
        ld_valid = 0;
        while (!ld_rsp_valid) @(negedge clock);
        if (ld_replay || ld_data !== expected)
            $fatal(1, "D$ addr=%h data=%h expected=%h replay=%b", addr, ld_data, expected, ld_replay);
        repeat (40) @(negedge clock);
    endtask
    task automatic fetch(input logic [31:0] addr);
        if_addr = addr; if_valid = 1;
        @(negedge clock);
        while (!if_rsp_valid) begin
            if_valid = !if_busy;
            @(negedge clock);
        end
        if_valid = 0;
        if (if_w0 !== value(addr) || if_w1 !== value(addr+4))
            $fatal(1, "I$ addr=%h data=%h/%h", addr, if_w0, if_w1);
        repeat (40) @(negedge clock);
    endtask

    int before_reads;
    initial begin
        repeat (3) @(negedge clock); reset = 0;
        load(DA, value(DA)); load(DB, value(DB));
        before_reads = dreads; load(DA, value(DA));
        if (dreads-before_reads != ((ASSOC == 2) ? 0 : LINE_BYTES/4))
            $fatal(1, "D$ ASSOC=%0d wrong conflict miss count=%0d", ASSOC, dreads-before_reads);
        if (ASSOC == 2) begin
            load(DC, value(DC));
            before_reads = dreads;
            load(DB, value(DB)); load(DC, value(DC));
            if (dreads != before_reads) $fatal(1, "D$ replacement lost surviving way");
        end else load(DB, value(DB));
        su_addr = DB; su_valid = 1;
        while (!su_ready) @(negedge clock);
        @(negedge clock); su_valid = 0;
        if (!su_hit) $fatal(1, "D$ store did not hit cached way");
        repeat (3) @(negedge clock);
        load(DB, (value(DB) & 32'hffff00ff) | 32'h0000ab00);
        inv_addr = DB; inv_valid = 1;
        @(negedge clock); inv_valid = 0;
        before_reads = dreads; load(DB, value(DB));
        if (dreads-before_reads != LINE_BYTES/4) $fatal(1, "D$ invalidation did not force refill");

        fetch(IA); fetch(IB);
        before_reads = ireads; fetch(IA);
        if (ireads-before_reads != ((ASSOC == 2) ? 0 : LINE_BYTES/4))
            $fatal(1, "I$ ASSOC=%0d wrong conflict miss count=%0d", ASSOC, ireads-before_reads);
        if (ASSOC == 2) begin
            fetch(IC); before_reads = ireads; fetch(IB); fetch(IC);
            if (ireads != before_reads) $fatal(1, "I$ replacement lost surviving way");
        end
        $display("PASS: ASSOC=%0d conflict hits, replacement, byte update, invalidate", ASSOC);
        $finish;
    end
    initial begin #200000; $fatal(1, "timeout"); end
endmodule
