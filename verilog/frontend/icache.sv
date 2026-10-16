// Instruction cache (design.md §5.1): 2 banks (even/odd line words) of
// IC_LINES*(LINE_BYTES/8) words each, direct-mapped, one outstanding refill.
// A fetch block is 8 bytes (2 consecutive line words) and is served in one
// pipelined read. On a miss the cache refills the whole line with
// LINE_BYTES/4 back-to-back AXI reads and asserts busy (fetch stalls).
module icache (
    input  wire        clock,
    input  wire        reset,

    // fetch request (8B-aligned block address), 1-cycle read latency
    input  wire        req_valid,
    input  wire [31:0] req_addr,
    output wire        busy,          // refilling: no response available
    output wire        rsp_valid,
    output wire [31:0] rsp_word0,
    output wire [31:0] rsp_word1,

    // AXI read push (src = MRF_IC, set by top)
    output wire        rd_push_valid,
    output wire [31:0] rd_push_addr,
    output wire [4:0]  rd_push_idx,
    input  wire        rd_push_ready,
    input  wire        rd_rsp_valid,
    input  wire [4:0]  rd_rsp_idx,
    input  wire [31:0] rd_rsp_data,
    output wire        rd_rsp_ready
);
    localparam int SETB = $clog2(cpu_pkg::IC_LINES);            // 7
    localparam int OFFB = $clog2(cpu_pkg::LINE_BYTES);          // 4/5
    localparam int NW   = cpu_pkg::LINE_BYTES / 4;              // words per line 4/8
    localparam int WB   = $clog2(NW);                           // word index bits 2/3
    localparam int BB   = OFFB - 3;                             // 8B blocks per line bits 1/2
    localparam int TAGB = 32 - SETB - OFFB;                     // 21/20
    localparam int CWB  = $clog2(NW + 1);                       // refill counter bits 3/4
    localparam int BD   = cpu_pkg::IC_LINES * (cpu_pkg::LINE_BYTES / 8);  // per-bank depth
`ifndef SYNTHESIS
    initial if ((cpu_pkg::LINE_BYTES != 16) && (cpu_pkg::LINE_BYTES != 32))
        $fatal(1, "icache: LINE_BYTES must be 16 or 32 for this implementation");
`endif

    logic [cpu_pkg::IC_LINES-1:0] v_q;
    logic [TAGB-1:0] tag_q [0:cpu_pkg::IC_LINES-1];

    // request latched last cycle (its data is on the banks this cycle)
    logic        pend_q;
    logic [SETB-1:0] req_set_q;
    logic [TAGB-1:0] req_tag_q;

    // refill state
    logic        busy_q;
    logic [CWB-1:0] rf_cnt;   // pushes accepted (also next word index)
    logic [CWB-1:0] rf_done;  // responses written
    logic [SETB-1:0] rf_set;
    logic [TAGB-1:0] rf_tag;
    localparam logic [CWB-1:0] RF_END = NW[CWB-1:0];

    wire [SETB-1:0] req_set = req_addr[SETB+OFFB-1:OFFB];
    wire [TAGB-1:0] req_tag = req_addr[31:SETB+OFFB];
    wire [BB-1:0]   req_blk = req_addr[OFFB-1:3];

    // ---------------- SRAM controls ----------------
    // read (normal operation): both banks read the pair for the requested 8B block
    wire rd_en = req_valid && !busy_q;
    wire [SETB+BB-1:0] rd_addr = {req_set, req_blk};

    // refill write: one 32-bit word into bank rsp_word[0] at slot {set, word[WB-1:1]}
    wire [WB-1:0] rsp_word = rd_rsp_idx[WB-1:0];
    wire rf_wr = rd_rsp_valid && busy_q;
    wire [SETB+BB-1:0] wr_addr = {rf_set, rsp_word[WB-1:1]};

    wire [31:0] b0_rdata, b1_rdata;

    sram_fakeram #(.DEPTH(BD), .WIDTH(32)) u_bank0 (
        .clk(clock), .en(rd_en || (rf_wr && (rsp_word[0] == 1'b0))),
        .we (rf_wr && (rsp_word[0] == 1'b0)),
        .wmask(1'b1), .addr(rd_en ? rd_addr : wr_addr),
        .wdata(rd_rsp_data), .rdata(b0_rdata));

    sram_fakeram #(.DEPTH(BD), .WIDTH(32)) u_bank1 (
        .clk(clock), .en(rd_en || (rf_wr && (rsp_word[0] == 1'b1))),
        .we (rf_wr && (rsp_word[0] == 1'b1)),
        .wmask(1'b1), .addr(rd_en ? rd_addr : wr_addr),
        .wdata(rd_rsp_data), .rdata(b1_rdata));

    // ---------------- response / miss ----------------
    wire hit = pend_q && v_q[req_set_q] && (tag_q[req_set_q] == req_tag_q);
    wire miss = pend_q && !hit;

    assign busy       = busy_q;
    assign rsp_valid  = pend_q && hit && !busy_q;
    assign rsp_word0  = b0_rdata;
    assign rsp_word1  = b1_rdata;

    // ---------------- refill AXI ----------------
    // push all line words as fast as rdQ accepts them (rdQ pipelines);
    // busy clears only once all responses have been written back.
    assign rd_push_valid = busy_q && (rf_cnt != RF_END);
    assign rd_push_addr  = {rf_tag, rf_set, rf_cnt[WB-1:0], 2'b00};
    assign rd_push_idx   = {2'b00, rf_cnt[2:0]};
    assign rd_rsp_ready  = busy_q;

    always_ff @(posedge clock) begin
        if (reset) begin
            v_q <= '0;
            pend_q <= 1'b0;
            busy_q <= 1'b0;
            rf_cnt <= '0; rf_done <= '0;
        end else begin
            // latch request
            pend_q    <= req_valid && !busy_q;
            if (req_valid && !busy_q) begin
                req_set_q  <= req_set;
                req_tag_q  <= req_tag;
            end
            // miss -> start refill
            if (miss) begin
                busy_q <= 1'b1;
                rf_cnt <= '0; rf_done <= '0;
                rf_set <= req_set_q;
                rf_tag <= req_tag_q;
            end
            // refill pushes
            if (rd_push_valid && rd_push_ready) rf_cnt <= rf_cnt + 1'b1;
            // refill writes
            if (rf_wr) begin
                rf_done <= rf_done + 1'b1;
                if ((rf_done + 1'b1) == RF_END) begin
                    v_q[rf_set] <= 1'b1;
                    tag_q[rf_set] <= rf_tag;
                    busy_q <= 1'b0;
                end
            end
        end
    end
endmodule
