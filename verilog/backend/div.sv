// Iterative divider: top-aligned restoring division with
// early exit from leading zeros; spec-defined div/rem boundary values.
// One request produces one result; a cached quotient/remainder serves repeated operands.
module div (
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
    localparam logic [2:0] S_IDLE = 3'd0, S_PREP = 3'd1, S_STEP = 3'd2,
        S_FIX = 3'd3, S_EMIT = 3'd4, S_FAST = 3'd5;

    logic [2:0] state;
    logic signed_d, remainder_d;
    logic [31:0] ub_d, ash_d, acc_d, q_d, a_d, b_d;
    logic [6:0]  step_d;
    logic [$clog2(cpu_pkg::PRF_NUM)-1:0] tag_d;
    logic [$clog2(cpu_pkg::ROB_DEPTH)-1:0] rob_d;
    logic [31:0] qout_d, rout_d;

    // ---- div/rem pair cache (design-style local optimization) ----
    // A follow-up div/rem with identical operands and signedness reuses the
    // previous quotient/remainder instead of iterating again (rem+div pairs
    // from the same expression). Pure function of (a, b, signedness): the
    // entry is only trusted when all three match, so it can never return a
    // wrong value; it is not cleared on flush and never checked against rob.
    logic        cv_q;
    logic [31:0] ca_q, cb_q, cq_q, cr_q;
    logic        cs_q;
    wire new_signed = (req_funct3[0] == 1'b0);
    wire cache_hit = cv_q &&
                     (req_a == ca_q) && (req_b == cb_q) && (new_signed == cs_q);


    // preparation is combinational on registered a/b
    logic an_d, sn_d;
    wire [31:0] neg_a_r = -a_d;
    wire [31:0] neg_b_r = -b_d;
    wire [31:0] ua_c = signed_d ? (an_d ? neg_a_r : a_d) : a_d;
    wire [31:0] ub_c = signed_d ? (sn_d ? neg_b_r : b_d) : b_d;

    // msb index: last set bit (loop upward; highest wins)
    function automatic logic [4:0] msb32(input logic [31:0] v);
        msb32 = 5'd0;
        for (int i = 0; i < 32; i = i + 1)
            if (v[i]) msb32 = i[4:0];
    endfunction

    wire [4:0] e_c = msb32(ua_c);

    // STEP-cycle comb (next state values)
    wire bitv = ash_d[31];
    wire [31:0] acc_c = {acc_d[30:0], bitv};
    wire geqb = (acc_c >= ub_d);
    wire [31:0] acc_n = geqb ? (acc_c - ub_d) : acc_c;
    wire [31:0] q_n = {q_d[30:0], geqb};
    wire [31:0] ash_n = {ash_d[30:0], 1'b0};

    // sign fix on magnitudes (applied at S_FIX, one cycle after last STEP)
    wire qneg_c = signed_d && (an_d != sn_d);
    wire [31:0] qout_c = signed_d ? (qneg_c ? (32'b0 - q_d) : q_d) : q_d;
    wire [31:0] rout_c = signed_d ? (an_d ? (32'b0 - acc_d) : acc_d) : acc_d;

    // PREP special cases: division by zero, signed overflow and zero dividend.
    wire b_zero_p = (b_d == 32'b0);
    wire ovf_p    = signed_d && (a_d == 32'h80000000) && (b_d == 32'hffffffff);
    wire a_zero_p = (a_d == 32'b0);
    wire [31:0] qspec_c = b_zero_p ? 32'hffffffff :
                    (ovf_p    ? 32'h80000000 : 32'b0);
    wire [31:0] rspec_c = b_zero_p ? a_d : 32'b0;

    assign req_ready = (state == S_IDLE);
    assign wb_valid = !reset && (state == S_EMIT);
    assign wb_tag = tag_d;
    assign wb_rob = rob_d;
    assign wb_data = remainder_d ? rout_d : qout_d;

    always_ff @(posedge clock) begin
        if (reset) begin
            state <= S_IDLE;
            cv_q  <= 1'b0;
        end else begin
            case (state)
                S_IDLE: if (req_valid && cache_hit) begin
                    // fast path: reuse cached quotient/remainder
                    qout_d <= cq_q;
                    rout_d <= cr_q;
                    remainder_d <= (req_funct3[1] == 1'b1);
                    tag_d <= req_tag;
                    rob_d <= req_rob;
                    state  <= S_FAST;
                end else if (req_valid) begin
                    a_d <= req_a; b_d <= req_b;
                    signed_d <= (req_funct3[0] == 1'b0);
                    remainder_d   <= (req_funct3[1] == 1'b1); // f3 110/111 -> REM family
                    tag_d <= req_tag;
                    rob_d <= req_rob;
                    an_d <= (req_funct3[0] == 1'b0) && req_a[31];
                    sn_d <= (req_funct3[0] == 1'b0) && req_b[31];
                    state <= S_PREP;
                end
                S_PREP: begin
                    if (b_zero_p || ovf_p) begin
                        qout_d <= qspec_c;
                        rout_d <= rspec_c;
                        cv_q <= 1'b1; ca_q <= a_d; cb_q <= b_d; cs_q <= signed_d;
                        cq_q <= qspec_c; cr_q <= rspec_c;
                        state  <= S_EMIT;
                    end else if (a_zero_p) begin
                        qout_d <= 32'b0;
                        rout_d <= 32'b0;
                        cv_q <= 1'b1; ca_q <= a_d; cb_q <= b_d; cs_q <= signed_d;
                        cq_q <= 32'b0; cr_q <= 32'b0;
                        state  <= S_EMIT;
                    end else begin
                        ub_d   <= ub_c;
                        ash_d  <= ua_c << (5'd31 - e_c);
                        acc_d  <= 32'b0;
                        q_d    <= 32'b0;
                        step_d <= {1'b0, e_c} + 7'd1;  // iterate bits e..0
                        state  <= S_STEP;
                    end
                end
                S_STEP: begin
                    acc_d <= acc_n;
                    q_d   <= q_n;
                    ash_d <= ash_n;
                    if (step_d == 7'd1) state <= S_FIX;
                    else step_d <= step_d - 7'd1;
                end
                S_FIX: begin
                    qout_d <= qout_c;
                    rout_d <= rout_c;
                    cv_q <= 1'b1; ca_q <= a_d; cb_q <= b_d; cs_q <= signed_d;
                    cq_q <= qout_c; cr_q <= rout_c;
                    state  <= S_EMIT;
                end
                S_FAST:  state <= S_EMIT;
                S_EMIT: state <= S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
