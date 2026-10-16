// Pipelined 32x32 multiplier (design.md §6.4.2), structural over MUL_LAT.
// Signed Booth-radix-4 core: b (as a two's-complement value) = Σ d_k·2^{2k},
// k=0..15, digits from bits (2k-1, 2k, 2k+1) on the raw 32-bit b; identity
// holds exactly for the signed interpretation, so the core computes
// a_s × b_s. Negative digits store the complement BEFORE the weight shift,
// (~m)<<2k, and the +2^{2k} correction completes the two's-complement
// negation: (~m)<<2k + 2^{2k} ≡ -m·4^k (mod 2^70) — the discarded 2^70·4^k
// term cannot affect bits [63:0]. (Complementing AFTER the shift would need
// the correction at bit 0, not 2k.) Unsigned variants are exact with free
// correction terms:
//   MULHSU: p = p_s + (b31 ? a : 0)·2^32
//   MULHU : p = p_s + (b31 ? a : 0)·2^32 + (a31 ? b : 0)·2^32
// (the +2^64·a31·b31 term does not affect bits [63:0]). The corrections plus
// the booth negative-digit constants (+2^2k) are merged into one 36-bit value
// `u` that travels with the meta chain; the final adder stage folds it in.
//
// MUL_LAT>=4: fire -> wb_valid = 4 cycles (adder tree levels x/y/z registered
//             separately), throughput 1/cycle. Default.
// MUL_LAT==2: fire -> wb_valid = 2 cycles (three tree levels combined, only
//             the 2-way z sum registered), throughput 1/cycle; shorter
//             dependent-chain latency at a longer per-stage carry path.
module mul (
    input  wire        clock,
    input  wire        reset,
    input  wire        req_valid,
    input  wire [31:0] req_a,
    input  wire [31:0] req_b,
    input  wire [2:0]  req_funct3,
    input  wire [$clog2(cpu_pkg::PRF_NUM)-1:0] req_tag,
    input  wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] req_rob,
    output wire        req_ready,
    output wire        wb_valid,
    output wire [$clog2(cpu_pkg::PRF_NUM)-1:0] wb_tag,
    output wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] wb_rob,
    output wire [31:0] wb_data
);
    assign req_ready = 1'b1; // pipeline accepts one request per cycle

    // meta packing {valid, highsel, tag[PB-1:0], rob[RW-1:0]} (parameterized
    // slices; the old hard-coded [12:0]/[10:5]/[4:0] broke at ROB64/PRF128)
    localparam int PB = $clog2(cpu_pkg::PRF_NUM);
    localparam int RW = $clog2(cpu_pkg::ROB_DEPTH);
    localparam int MW = 2 + PB + RW;

    wire [69:0] aext70 = {{38{req_a[31]}}, req_a};
    wire [69:0] aext2  = {aext70[68:0], 1'b0};

    logic [69:0] digit_base [0:15];
    logic        digit_neg  [0:15];
    genvar j;
    generate
        for (j = 0; j < 16; j = j + 1) begin : digits
            wire       b_hi  = req_b[2*j + 1];
            wire       b_mid = req_b[2*j];
            wire       b_lo  = (j == 0) ? 1'b0 : req_b[2*j - 1];
            wire [2:0] b3    = {b_hi, b_mid, b_lo};
            wire [69:0] mag_v = (b3 == 3'b011 || b3 == 3'b100) ? aext2 : aext70;
            always_comb begin
                digit_neg[j] = 1'b0;
                case (b3)
                    3'b001, 3'b010, 3'b011: digit_base[j] = mag_v << (2*j);
                    3'b100, 3'b101, 3'b110: begin
                        digit_base[j] = (~mag_v) << (2*j); digit_neg[j] = 1'b1; end
                    default:        digit_base[j] = 70'b0;    // 000 / 111
                endcase
            end
        end
    endgenerate

    // booth negative-digit correction: sparse bits at 2^2k, one per neg digit
    logic [31:0] corr_booth_comb;
    genvar cj;
    generate
        for (cj = 0; cj < 32; cj = cj + 1) begin : corr_bits
            if (cj % 2 == 0) assign corr_booth_comb[cj] = digit_neg[cj/2];
            else assign corr_booth_comb[cj] = 1'b0;
        end
    endgenerate

    wire        b31 = req_b[31];
    wire        a31 = req_a[31];
    wire [33:0] corr_a = (b31 && (req_funct3 == 3'b010 || req_funct3 == 3'b011))
                         ? {2'b0, req_a} : 34'b0;
    wire [33:0] corr_b = (a31 && req_funct3 == 3'b011) ? {2'b0, req_b} : 34'b0;
    wire [35:0] u_in   = {2'b0, corr_a} + {2'b0, corr_b};

    wire fire = req_valid && !reset;

    generate
    if (cpu_pkg::MUL_LAT >= 4) begin : g_pipe4
        // ---------------- stage regs ----------------
        logic [69:0] v_r   [0:15];
        logic [35:0] u_r   [0:3];
        logic [31:0] c_r   [0:3];
        logic [MW-1:0] meta [0:3]; // {valid, highsel, tag[PB-1:0], rob[RW-1:0]}

        // tree comb (from registers) and stage regs
        logic [71:0] x_r [0:7];
        logic [72:0] y_r [0:3];
        logic [73:0] z_r [0:1];
        wire [71:0] xv00 = {{2{v_r[0][69]}},  v_r[0]}  + {{2{v_r[1][69]}},  v_r[1]};
        wire [71:0] xv01 = {{2{v_r[2][69]}},  v_r[2]}  + {{2{v_r[3][69]}},  v_r[3]};
        wire [71:0] xv02 = {{2{v_r[4][69]}},  v_r[4]}  + {{2{v_r[5][69]}},  v_r[5]};
        wire [71:0] xv03 = {{2{v_r[6][69]}},  v_r[6]}  + {{2{v_r[7][69]}},  v_r[7]};
        wire [71:0] xv04 = {{2{v_r[8][69]}},  v_r[8]}  + {{2{v_r[9][69]}},  v_r[9]};
        wire [71:0] xv05 = {{2{v_r[10][69]}}, v_r[10]} + {{2{v_r[11][69]}}, v_r[11]};
        wire [71:0] xv06 = {{2{v_r[12][69]}}, v_r[12]} + {{2{v_r[13][69]}}, v_r[13]};
        wire [71:0] xv07 = {{2{v_r[14][69]}}, v_r[14]} + {{2{v_r[15][69]}}, v_r[15]};

        wire [72:0] y0 = {{1{x_r[0][71]}},  x_r[0]}  + {{1{x_r[1][71]}},  x_r[1]};
        wire [72:0] y1 = {{1{x_r[2][71]}},  x_r[2]}  + {{1{x_r[3][71]}},  x_r[3]};
        wire [72:0] y2 = {{1{x_r[4][71]}},  x_r[4]}  + {{1{x_r[5][71]}},  x_r[5]};
        wire [72:0] y3 = {{1{x_r[6][71]}},  x_r[6]}  + {{1{x_r[7][71]}},  x_r[7]};

        wire [73:0] z0 = {{1{y_r[0][72]}}, y_r[0]} + {{1{y_r[1][72]}}, y_r[1]};
        wire [73:0] z1 = {{1{y_r[2][72]}}, y_r[2]} + {{1{y_r[3][72]}}, y_r[3]};

        // final merge: signed tree sums + booth correction (bit 0)
        //              + unsigned-variant corrections (bit weight 2^32)
        wire [77:0] pf = {{4{z_r[0][73]}}, z_r[0]} + {{4{z_r[1][73]}}, z_r[1]} +
                         {{46'b0}, c_r[3]} + {{10'b0}, u_r[3], 32'b0};

        assign wb_valid = meta[3][MW-1];
        assign wb_tag   = meta[3][RW +: PB];
        assign wb_rob   = meta[3][0 +: RW];
        assign wb_data  = meta[3][MW-2] ? pf[63:32] : pf[31:0];

        always_ff @(posedge clock) begin
            if (reset) begin
                meta[0] <= '0; meta[1] <= '0; meta[2] <= '0; meta[3] <= '0;
                c_r[0] <= '0; c_r[1] <= '0; c_r[2] <= '0; c_r[3] <= '0;
                u_r[0] <= '0; u_r[1] <= '0; u_r[2] <= '0; u_r[3] <= '0;
            end else begin
                            // level 0: capture booth terms at fire
                if (fire) begin
                    for (int k = 0; k < 16; k = k + 1)
                        v_r[k] <= digit_base[k];
                    u_r[0] <= u_in; c_r[0] <= corr_booth_comb;
                    meta[0] <= {1'b1, req_funct3 != 3'b000, req_tag, req_rob}; // valid=1
                end else begin
                    meta[0] <= {1'b0, 1'b0, req_tag, req_rob};                 // valid=0
                end
                // levels 1..4: shift meta/correction, register tree results
                x_r[0] <= xv00; x_r[1] <= xv01; x_r[2] <= xv02; x_r[3] <= xv03;
                u_r[1] <= u_r[0]; c_r[1] <= c_r[0];
                x_r[4] <= xv04; x_r[5] <= xv05; x_r[6] <= xv06; x_r[7] <= xv07;
                y_r[0] <= y0; y_r[1] <= y1; y_r[2] <= y2; y_r[3] <= y3;
                u_r[2] <= u_r[1]; c_r[2] <= c_r[1];
                z_r[0] <= z0;
                z_r[1] <= z1;
                u_r[3] <= u_r[2]; c_r[3] <= c_r[2];
                            meta[1] <= meta[0];
                meta[2] <= meta[1];
                meta[3] <= meta[2];
            end
        end
    end else if (cpu_pkg::MUL_LAT == 2) begin : g_pipe2
        // fire -> wb_valid = 2 cycles: digits are captured at fire, the whole
        // x/y/z reduction is one comb stage, only the final 2-way z sum and
        // the meta/correction pair are registered; the pf merge is stage 2.
        logic [69:0] v_r   [0:15];
        logic [73:0] z_r   [0:1];
        logic [35:0] u_r0, u_r1;
        logic [31:0] c_r0, c_r1;
        logic [MW-1:0] meta [0:1]; // {valid, highsel, tag[PB-1:0], rob[RW-1:0]}

        wire [71:0] xv00 = {{2{v_r[0][69]}},  v_r[0]}  + {{2{v_r[1][69]}},  v_r[1]};
        wire [71:0] xv01 = {{2{v_r[2][69]}},  v_r[2]}  + {{2{v_r[3][69]}},  v_r[3]};
        wire [71:0] xv02 = {{2{v_r[4][69]}},  v_r[4]}  + {{2{v_r[5][69]}},  v_r[5]};
        wire [71:0] xv03 = {{2{v_r[6][69]}},  v_r[6]}  + {{2{v_r[7][69]}},  v_r[7]};
        wire [71:0] xv04 = {{2{v_r[8][69]}},  v_r[8]}  + {{2{v_r[9][69]}},  v_r[9]};
        wire [71:0] xv05 = {{2{v_r[10][69]}}, v_r[10]} + {{2{v_r[11][69]}}, v_r[11]};
        wire [71:0] xv06 = {{2{v_r[12][69]}}, v_r[12]} + {{2{v_r[13][69]}}, v_r[13]};
        wire [71:0] xv07 = {{2{v_r[14][69]}}, v_r[14]} + {{2{v_r[15][69]}}, v_r[15]};

        wire [72:0] yc0 = {{1{xv00[71]}}, xv00} + {{1{xv01[71]}}, xv01};
        wire [72:0] yc1 = {{1{xv02[71]}}, xv02} + {{1{xv03[71]}}, xv03};
        wire [72:0] yc2 = {{1{xv04[71]}}, xv04} + {{1{xv05[71]}}, xv05};
        wire [72:0] yc3 = {{1{xv06[71]}}, xv06} + {{1{xv07[71]}}, xv07};

        wire [73:0] zc0 = {{1{yc0[72]}}, yc0} + {{1{yc1[72]}}, yc1};
        wire [73:0] zc1 = {{1{yc2[72]}}, yc2} + {{1{yc3[72]}}, yc3};

        wire [77:0] pf = {{4{z_r[0][73]}}, z_r[0]} + {{4{z_r[1][73]}}, z_r[1]} +
                         {{46'b0}, c_r1} + {{10'b0}, u_r1, 32'b0};

        assign wb_valid = meta[1][MW-1];
        assign wb_tag   = meta[1][RW +: PB];
        assign wb_rob   = meta[1][0 +: RW];
        assign wb_data  = meta[1][MW-2] ? pf[63:32] : pf[31:0];

        always_ff @(posedge clock) begin
            if (reset) begin
                meta[0] <= '0; meta[1] <= '0;
                c_r0 <= '0; c_r1 <= '0; u_r0 <= '0; u_r1 <= '0;
            end else begin
                // level 0: capture booth terms at fire
                if (fire) begin
                    for (int k = 0; k < 16; k = k + 1)
                        v_r[k] <= digit_base[k];
                    u_r0 <= u_in; c_r0 <= corr_booth_comb;
                    meta[0] <= {1'b1, req_funct3 != 3'b000, req_tag, req_rob}; // valid=1
                end else begin
                    meta[0] <= {1'b0, 1'b0, req_tag, req_rob};                 // valid=0
                end
                // level 1: register the top of the comb tree, shift meta and
                // the correction pair in lockstep with the z sum
                z_r[0] <= zc0;
                z_r[1] <= zc1;
                u_r1 <= u_r0; c_r1 <= c_r0;
                meta[1] <= meta[0];
            end
        end
    end else begin : g_bad
        // unsupported MUL_LAT: fail loudly instead of building an undocumented
        // latency variant (tie the WB outputs so elaboration stays clean).
        assign wb_valid = 1'b0;
        assign wb_tag   = '0;
        assign wb_rob   = '0;
        assign wb_data  = 32'b0;
`ifndef SYNTHESIS
        initial $fatal(1, "mul: MUL_LAT must be 2 or >= 4 for this implementation");
`endif
    end
    endgenerate
endmodule
