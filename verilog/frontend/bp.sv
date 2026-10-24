// Branch predictor: 2-bit BHT for direction, BTB for
// conditional-branch and JALR target guessing, RAS for return-address
// prediction. BHT counters and BTB entries are trained by the BRU on
// resolution (one pulse per resolved branch); RAS mis-pops are not repaired
// (documented limitation §5.2).
//
// All structural sizes derive from cpu_pkg knobs (BHT_ENTRIES / BTB_ENTRIES /
// RAS_DEPTH); there are no hard structural constants.
//
// BTB organization: direct-mapped, index = pc[BI+1:2], tag = pc[31:BI+2],
// target stored as target[31:1] (bit 0 is always cleared by JALR semantic and
// branch immediates are even). Lookups are combinational; updates take effect
// the cycle after resolution. Only taken resolutions write the BTB (a
// not-taken branch needs no target); the BHT direction gates cond-branch use.
module bp (
    input  wire        clock,
    input  wire        reset,

    // ---- lookup port 0 (first instruction of the fetch block) ----
    input  wire [31:0] lk0_pc,
    output wire        lk0_dir,        // BHT direction (taken when counter MSB)
    output wire        lk0_hit,        // BTB tag hit
    output wire [31:0] lk0_target,

    // ---- lookup port 1 (second instruction of the fetch block) ----
    input  wire [31:0] lk1_pc,
    output wire        lk1_dir,
    output wire        lk1_hit,
    output wire [31:0] lk1_target,

    // ---- BHT update (BRU resolve, conditional branches) ----
    input  wire        up_valid,
    input  wire [31:0] up_pc,
    input  wire        up_taken,
    input  wire [$clog2(cpu_pkg::BHT_ENTRIES)-1:0] up_ix,  // fetch-time BHT index
    input  wire        up_mispred,   // restore the speculative GHR to this branch's point

    // ---- BTB update (BRU resolve, taken cond branch / non-return JALR) ----
    input  wire        btb_upd_valid,
    input  wire [31:0] btb_upd_pc,
    input  wire [31:0] btb_upd_target,

    // ---- RAS ops at decode, processed slot0 then slot1 ----
    input  wire        s0_v,
    input  wire        s0_ret,
    input  wire        s0_link,
    input  wire [31:0] s0_pc,
    input  wire        s1_v,
    input  wire        s1_ret,
    input  wire        s1_link,
    input  wire [31:0] s1_pc,
    output wire        s0_hit,
    output wire [31:0] s0_top,
    output wire        s1_hit,
    output wire [31:0] s1_top,

    // ---- fetched conditional branches this cycle (speculative GHR advance) ----
    input  wire        s0_cond,      // slot0 is a fetched conditional branch
    input  wire        s0_pt,        // slot0 predicted taken
    input  wire        s1_cond,      // slot1 is a fetched conditional branch
    input  wire        s1_pt,        // slot1 predicted taken
    output wire [$clog2(cpu_pkg::BHT_ENTRIES)-1:0] lk0_ix,  // BHT index port 0 (carried to BRU)
    output wire [$clog2(cpu_pkg::BHT_ENTRIES)-1:0] lk1_ix   // BHT index port 1
);
    localparam int RD   = cpu_pkg::RAS_DEPTH;
    localparam int BN   = cpu_pkg::BTB_ENTRIES;
    localparam int BHTN = cpu_pkg::BHT_ENTRIES;

    localparam int BI   = (BN   > 1) ? $clog2(BN)   : 1;  // BTB index bits
    localparam int BTAG = 30 - BI;                        // tag bits: pc[31:BI+2]
    localparam int BHI  = (BHTN > 1) ? $clog2(BHTN) : 1;  // BHT index bits
    localparam int RSPW = $clog2(RD + 1);                 // RAS pointer bits
    localparam int RSB  = (RD   > 1) ? $clog2(RD)   : 1;  // RAS index bits

    // ---------------- BHT (tournament: bimodal vs gshare) ----------------
    // Two 2-bit-counter tables predict direction: a bimodal table indexed by the
    // branch pc, and a gshare table indexed by pc ^ GHR. A per-pc choice table
    // selects between them and is trained toward whichever was right. This keeps
    // the pc-only strength for data-dependent branches (bimodal) while adding
    // global correlation where it helps (gshare).
    // The GHR advances with every *fetched* conditional branch using its
    // predicted direction (fetch runs in program order), so a branch's lookup
    // sees the true history of older branches. The exact gshare index used for
    // that lookup is captured and carried to the BRU (fe2rn_t.bix), so the
    // resolve-time update touches precisely the counter the fetch-time lookup
    // read (training stays consistent). On a misprediction the GHR is restored
    // to (this branch's fetch-time history + its actual outcome): older branches
    // must have predicted correctly (else an earlier flush), so this recovers
    // the architectural history. BP_GHR_BITS = 0 disables the gshare side.
    // Effective history is min(BP_GHR_BITS, BHI): the index is BHI bits, so a
    // wider BP_GHR_BITS than log2(BHT_ENTRIES) cannot add distinguishing bits.
    localparam int GHRW   = (cpu_pkg::BP_GHR_BITS > 1) ? cpu_pkg::BP_GHR_BITS : 2;
    localparam bit USE_GHR = (cpu_pkg::BP_GHR_BITS > 0);
    localparam int GH     = (GHRW < BHI) ? GHRW : BHI;   // history bits folded in
    logic [GHRW-1:0] ghr;

    wire [BHI-1:0] ib0 = lk0_pc[BHI+1:2];                          // bimodal index 0
    wire [BHI-1:0] ib1 = lk1_pc[BHI+1:2];                          // bimodal index 1
    wire [BHI-1:0] gx0 = USE_GHR ? {{(BHI-GH){1'b0}}, ghr[GH-1:0]} : {BHI{1'b0}};
    wire [BHI-1:0] ig0 = ib0 ^ gx0;                                // gshare index 0
    // history after slot0's own predicted outcome (used by port1 in-block)
    wire [GHRW-1:0] ghr_after0 = (USE_GHR && s0_cond) ? {ghr[GHRW-2:0], s0_pt} : ghr;
    wire [BHI-1:0] gx1 = USE_GHR ? {{(BHI-GH){1'b0}}, ghr_after0[GH-1:0]} : {BHI{1'b0}};
    wire [BHI-1:0] ig1 = ib1 ^ gx1;                                // gshare index 1
    wire [GHRW-1:0] ghr_after1 = (USE_GHR && s1_cond) ? {ghr_after0[GHRW-2:0], s1_pt}
                                                      : ghr_after0;
    // GHR value the mispredicting branch saw at fetch (reconstructed from its
    // carried gshare index), advanced by its actual outcome
    // Use one PC slice. Native Yosys misinterprets the chained packed slice
    // up_pc[BHI+1:2][GH-1:0] as up_pc[GH-1:0], unlike RTL simulation.
    wire [GHRW-1:0] ghr_rst = { {(GHRW-GH){1'b0}},
                                 (up_ix[GH-1:0] ^ up_pc[GH+1:2]) };

    logic [1:0] bht_b [0:BHTN-1];     // bimodal (pc-indexed)
    logic [1:0] bht_g [0:BHTN-1];     // gshare (pc^ghr)
    logic [1:0] cho   [0:BHTN-1];     // choice: MSB=1 selects gshare

    assign lk0_dir = cho[ib0][1] ? bht_g[ig0][1] : bht_b[ib0][1];
    assign lk1_dir = cho[ib1][1] ? bht_g[ig1][1] : bht_b[ib1][1];
    // the gshare index is exactly BHI bits, matching the carried bix width
    assign lk0_ix  = ig0;
    assign lk1_ix  = ig1;

    // ---------------- BTB ----------------
    logic            btb_v   [0:BN-1];
    logic [BTAG-1:0] btb_tag [0:BN-1];
    logic [30:0]     btb_tgt [0:BN-1];

    wire [BI-1:0]   b0  = lk0_pc[BI+1:2];
    wire [BI-1:0]   b1  = lk1_pc[BI+1:2];
    wire [BTAG-1:0] bt0 = lk0_pc[31:BI+2];
    wire [BTAG-1:0] bt1 = lk1_pc[31:BI+2];

    assign lk0_hit    = btb_v[b0] && (btb_tag[b0] == bt0);
    assign lk1_hit    = btb_v[b1] && (btb_tag[b1] == bt1);
    assign lk0_target = {btb_tgt[b0], 1'b0};
    assign lk1_target = {btb_tgt[b1], 1'b0};

    // ---------------- RAS ----------------
    logic [31:0]      ras_mem [0:RD-1];
    logic [RSPW-1:0]  sp_q;

    wire pop0  = s0_v && s0_ret;
    wire push0 = s0_v && s0_link;
    wire pop1  = s1_v && s1_ret;
    wire push1 = s1_v && s1_link;

    wire [RSPW-1:0] sp_after0 = sp_q - {{(RSPW-1){1'b0}}, pop0}
                                     + {{(RSPW-1){1'b0}}, push0};

    // pointer == RD means "full"; its low RSB bits wrap to 0, so the top index
    // (ptr-1) evaluates to RD-1 in the truncated RSB-bit domain.
    assign s0_hit = pop0 && (sp_q != {RSPW{1'b0}});
    assign s0_top = (sp_q != {RSPW{1'b0}})
                    ? ras_mem[sp_q[RSB-1:0] - {{(RSB-1){1'b0}}, 1'b1}] : 32'b0;
    assign s1_hit = pop1 && (sp_after0 != {RSPW{1'b0}});
    assign s1_top = (sp_after0 != {RSPW{1'b0}})
                    ? ras_mem[sp_after0[RSB-1:0] - {{(RSB-1){1'b0}}, 1'b1}] : 32'b0;

    int sp_int;
    always_comb begin
        sp_int = int'(sp_q) + (push0?1:0) + (push1?1:0) - (pop0?1:0) - (pop1?1:0);
        if (sp_int < 0) sp_int = 0;
        if (sp_int > RD) sp_int = RD;
    end

    always_ff @(posedge clock) begin
        if (reset) begin
            for (int i = 0; i < BHTN; i = i + 1) begin
                bht_b[i] = 2'b01; bht_g[i] = 2'b01; cho[i] = 2'b01;
            end
            for (int i = 0; i < BN;  i = i + 1) btb_v[i] = 1'b0;
            for (int i = 0; i < RD;  i = i + 1) ras_mem[i] = 32'b0;
            sp_q <= '0;
            ghr  <= '0;
        end else begin
            if (up_valid) begin
                logic [1:0]  cb, cg, ch;
                logic [BHI-1:0] ibu, igu;
                ibu = up_pc[BHI+1:2];
                igu = up_ix[BHI-1:0];
                cb = bht_b[ibu];
                cg = bht_g[igu];
                // train both component counters
                if (up_taken) begin
                    bht_b[ibu] <= (cb == 2'b11) ? 2'b11 : cb + 2'b01;
                    bht_g[igu] <= (cg == 2'b11) ? 2'b11 : cg + 2'b01;
                end else begin
                    bht_b[ibu] <= (cb == 2'b00) ? 2'b00 : cb - 2'b01;
                    bht_g[igu] <= (cg == 2'b00) ? 2'b00 : cg - 2'b01;
                end
                // choice: nudge toward whichever component predicted right
                ch = cho[ibu];
                if (cb[1] != cg[1]) begin
                    if (cb[1] == up_taken) cho[ibu] <= (ch == 2'b00) ? 2'b00 : ch - 2'b01;
                    else                   cho[ibu] <= (ch == 2'b11) ? 2'b11 : ch + 2'b01;
                end
            end
            // speculative GHR: on *any* misprediction (conditional branch, or a
            // JALR/JAL indirect whose wrong-path fetches advanced the GHR)
            // restore to that instruction's fetch-time history; a conditional
            // branch additionally shifts in its actual outcome. Otherwise
            // advance with the predicted outcomes of the branches fetched this
            // cycle.
            if (USE_GHR) begin
                if (up_mispred) ghr <= up_valid ? {ghr_rst[GHRW-2:0], up_taken}
                                                : ghr_rst;
                else            ghr <= ghr_after1;
            end
            if (btb_upd_valid) begin
                btb_v  [btb_upd_pc[BI+1:2]] <= 1'b1;
                btb_tag[btb_upd_pc[BI+1:2]] <= btb_upd_pc[31:BI+2];
                btb_tgt[btb_upd_pc[BI+1:2]] <= btb_upd_target[31:1];
            end
            if (push0 && (sp_q < RSPW'(RD))) ras_mem[sp_q[RSB-1:0]] <= s0_pc + 32'd4;
            if (push1 && (sp_after0 < RSPW'(RD)))
                ras_mem[sp_after0[RSB-1:0]] <= s1_pc + 32'd4;
            sp_q <= sp_int[RSPW-1:0];
        end
    end
endmodule
