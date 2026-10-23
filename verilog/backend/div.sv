// Iterative divider: top-aligned restoring division with
// early exit from leading zeros; spec-defined div/rem boundary values.
// Optional DIV/REM same-source fusion emits both results (two wb beats).
module div (
    input  wire        clock,
    input  wire        reset,
    input  wire        req_valid,
    input  wire [31:0] req_a,
    input  wire [31:0] req_b,
    input  wire [2:0]  req_f3a,     // first op (slot order from dispatch)
    input  wire [2:0]  req_f3b,     // second op (fused only)
    input  wire        req_fused,
    input  wire [$clog2(cpu_pkg::PRF_NUM)-1:0] req_tag_a,
    input  wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] req_rob_a,
    input  wire [$clog2(cpu_pkg::PRF_NUM)-1:0] req_tag_b,
    input  wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] req_rob_b,
    output wire        req_ready,
    output wire        wb_valid,
    output wire [$clog2(cpu_pkg::PRF_NUM)-1:0] wb_tag,
    output wire [$clog2(cpu_pkg::ROB_DEPTH)-1:0] wb_rob,
    output wire [31:0] wb_data
);
    localparam logic [2:0] S_IDLE = 3'd0, S_PREP = 3'd1, S_STEP = 3'd2,
        S_FIX = 3'd3, S_EMIT0 = 3'd4, S_EMIT1 = 3'd5, S_FAST = 3'd6;

    logic [2:0] state;
    logic signed_d, fused_d, rema_d, remb_d;
    logic [31:0] ub_d, ash_d, acc_d, q_d, a_d, b_d;
    logic [6:0]  step_d;
    logic [$clog2(cpu_pkg::PRF_NUM)-1:0] taga_d, tagb_d;
    logic [$clog2(cpu_pkg::ROB_DEPTH)-1:0] roba_d, robb_d;
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
    wire new_signed = (req_f3a[0] == 1'b0);
    wire cache_hit = cv_q && !req_fused &&
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

    // PREP special cases (b=0 / signed overflow / a=0 / divisor bigger)
    wire b_zero_p = (b_d == 32'b0);
    wire ovf_p    = signed_d && (a_d == 32'h80000000) && (b_d == 32'hffffffff);
    wire a_zero_p = (a_d == 32'b0);
    wire [31:0] qspec_c = b_zero_p ? 32'hffffffff :
                    (ovf_p    ? 32'h80000000 : 32'b0);
    wire [31:0] rspec_c = b_zero_p ? a_d : 32'b0;

    // emissione per leg
    wire [31:0] resa_c = rema_d ? rout_d : qout_d;
    wire [31:0] resb_c = remb_d ? rout_d : qout_d;

    assign req_ready = (state == S_IDLE);
    assign wb_valid  = !reset &&
        ((state == S_EMIT0) || (fused_d && (state == S_EMIT1)));
    assign wb_tag  = (state == S_EMIT1) ? tagb_d : taga_d;
    assign wb_rob  = (state == S_EMIT1) ? robb_d : roba_d;
    assign wb_data = (state == S_EMIT1) ? resb_c : resa_c;

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
                    rema_d <= (req_f3a[1] == 1'b1);
                    fused_d <= 1'b0;
                    taga_d <= req_tag_a;
                    roba_d <= req_rob_a;
                    state  <= S_FAST;
                end else if (req_valid) begin
                    a_d <= req_a; b_d <= req_b;
                    signed_d <= (req_f3a[0] == 1'b0);
                    fused_d  <= req_fused;
                    rema_d   <= (req_f3a[1] == 1'b1); // f3 110/111 -> REM family
                    remb_d   <= (req_f3b[1] == 1'b1);
                    taga_d <= req_tag_a; tagb_d <= req_tag_b;
                    roba_d <= req_rob_a; robb_d <= req_rob_b;
                    an_d <= (req_f3a[0] == 1'b0) && req_a[31];
                    sn_d <= (req_f3a[0] == 1'b0) && req_b[31];
                    state <= S_PREP;
                end
                S_PREP: begin
                    if (b_zero_p || ovf_p) begin
                        qout_d <= qspec_c;
                        rout_d <= rspec_c;
                        cv_q <= 1'b1; ca_q <= a_d; cb_q <= b_d; cs_q <= signed_d;
                        cq_q <= qspec_c; cr_q <= rspec_c;
                        state  <= S_EMIT0;
                    end else if (a_zero_p) begin
                        qout_d <= 32'b0;
                        rout_d <= 32'b0;
                        cv_q <= 1'b1; ca_q <= a_d; cb_q <= b_d; cs_q <= signed_d;
                        cq_q <= 32'b0; cr_q <= 32'b0;
                        state  <= S_EMIT0;
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
                    state  <= S_EMIT0;
                end
                S_FAST:  state <= S_EMIT0;
                S_EMIT0: state <= fused_d ? S_EMIT1 : S_IDLE;
                S_EMIT1: state <= S_IDLE;
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
