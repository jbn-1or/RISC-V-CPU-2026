// Small writeback skid FIFO (design §4.4): absorbs pipelined FU results
// (MUL/DIV) so a briefly busy result bus never drops a beat.
module wb_skid #(
    parameter int DEPTH = 4
) (
    input  wire        clock,
    input  wire        reset,
    input  cpu_pkg::writeback_t in,
    output wire        in_ready,
    output cpu_pkg::writeback_t out,
    input  wire        out_accept,
    output wire [2:0]  level           // occupancy; lets producers with no
                                       // backpressure keep beats lossless
);
    cpu_pkg::writeback_t mem [0:DEPTH-1];
    logic [1:0] head_q, tail_q;
    logic [2:0] cnt_q;

    assign in_ready = (cnt_q < 3'd4);
    assign level    = cnt_q;

    cpu_pkg::writeback_t out_c;
    always_comb begin
        out_c = mem[head_q];
        if (cnt_q == 3'd0) out_c.valid = 1'b0;
    end
    assign out = out_c;

    always_ff @(posedge clock) begin
        if (reset) begin
            head_q <= 2'd0; tail_q <= 2'd0; cnt_q <= 3'd0;
        end else begin
            if (in.valid && in_ready) begin
                mem[tail_q] <= in;
                tail_q <= tail_q + 2'd1;
            end
            if (out_c.valid && out_accept)
                head_q <= head_q + 2'd1;
            cnt_q <= cnt_q + ((in.valid && in_ready) ? 3'd1 : 3'd0) -
                              ((out_c.valid && out_accept) ? 3'd1 : 3'd0);
        end
    end
endmodule
