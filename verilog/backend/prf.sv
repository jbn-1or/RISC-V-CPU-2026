// Physical register file (design.md §3.2/§6.1): PRF_NUM×32 flop array, 4R/2W.
// Reads are combinational; writes are synchronous. p0 (tag 0) is hardwired to
// zero and is never written (design §9). Reads of p0 therefore return 0.
//
// Storage is an unpacked flop array (Yosys maps indexed reads/writes to
// one-hot muxes; the packed-vector form created a slow barrel-select on the
// PRF read path). The reset loop is unrolled 4-wide because a flat 128-
// iteration loop of delayed array assignments trips Verilator BLKLOOPINIT.
module prf (
    input  wire        clock,
    input  wire        reset,
    input  wire [$clog2(cpu_pkg::PRF_NUM)-1:0] raddr0,
    input  wire [$clog2(cpu_pkg::PRF_NUM)-1:0] raddr1,
    input  wire [$clog2(cpu_pkg::PRF_NUM)-1:0] raddr2,
    input  wire [$clog2(cpu_pkg::PRF_NUM)-1:0] raddr3,
    output wire [31:0] rdata0,
    output wire [31:0] rdata1,
    output wire [31:0] rdata2,
    output wire [31:0] rdata3,
    input  wire [1:0]  wr_valid,
    input  wire [$clog2(cpu_pkg::PRF_NUM)-1:0] waddr0,
    input  wire [$clog2(cpu_pkg::PRF_NUM)-1:0] waddr1,
    input  wire [31:0] wdata0,
    input  wire [31:0] wdata1
);
    logic [31:0] regs [0:cpu_pkg::PRF_NUM-1];

    assign rdata0 = regs[raddr0];
    assign rdata1 = regs[raddr1];
    assign rdata2 = regs[raddr2];
    assign rdata3 = regs[raddr3];

    always_ff @(posedge clock) begin
        if (reset) begin
            for (int i = 0; i < cpu_pkg::PRF_NUM; i = i + 4) begin
                regs[i]     <= 32'b0;
                regs[i + 1] <= 32'b0;
                regs[i + 2] <= 32'b0;
                regs[i + 3] <= 32'b0;
            end
        end else begin
            if (wr_valid[0] && (waddr0 != '0)) regs[waddr0] <= wdata0;
            if (wr_valid[1] && (waddr1 != '0)) regs[waddr1] <= wdata1;
        end
    end
endmodule
