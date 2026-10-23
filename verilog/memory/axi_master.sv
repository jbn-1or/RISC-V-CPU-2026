// AXI4-Lite master arbitrator (design.md §7.4).
// Sources (IC$ refill / D$ refill / LSU direct read) are shaped into an ordered
// read queue; responses return strictly in request order (slave serves the AR
// queue in order). Write pushes complete strictly in push order (slave B queue).
// rready/bready constant 1 (the exit result is captured at the B handshake
// in the simulator, so the master must always be able to receive it).
module axi_master (
    input  wire        clock,
    input  wire        reset,
    input  wire        rd_push_valid,
    input  wire [31:0] rd_push_addr,
    input  wire cpu_pkg::mrf_e  rd_push_src,
    input  wire [4:0]  rd_push_idx,      // aux tag: I$ word index / D$ {mshr slot, word[2:0]}
    output wire        rd_push_ready,
    output wire        rd_rsp_valid,
    output wire [1:0]  rd_rsp_src,
    output wire [4:0]  rd_rsp_idx,
    output wire [1:0]  rd_rsp_err,
    output wire [31:0] rd_rsp_data,
    input  wire        rd_rsp_ready,
    input  wire        wr_push_valid,
    input  wire [31:0] wr_push_addr,
    input  wire [31:0] wr_push_data,
    input  wire [3:0]  wr_push_strb,
    input  wire [3:0]  wr_push_tag,      // store identity, returned with B
    output wire        wr_push_ready,
    output wire        wr_rsp_valid,
    output wire [3:0]  wr_rsp_tag,
    output wire [31:0] araddr,
    output wire        arvalid,
    input  wire        arready,
    input  wire [31:0] rdata,
    input  wire [1:0]  rresp,
    input  wire        rvalid,
    output wire        rready,
    output wire [31:0] awaddr,
    output wire        awvalid,
    input  wire        awready,
    output wire [31:0] wdata,
    output wire [3:0]  wstrb,
    output wire        wvalid,
    input  wire        wready,
    input  wire        bvalid,
    output wire        bready
);
    localparam logic [4:0] WR_CAP = cpu_pkg::AXI_MAX_WR[4:0];
`ifndef SYNTHESIS
    initial if (cpu_pkg::AXI_MAX_WR + 1 > 16)
        $fatal(1, "axi_master: write-tag FIFO depth 16 too small for AXI_MAX_WR");
`endif

    // =============================== read side ===============================
    // rdQ (accepted, not issued) -> ar fire -> infl (issued) -> rsp skid FIFO
    logic [38:0] rdq_mem [0:cpu_pkg::AXI_MAX_RD-1];   // {addr, idx[4:0], src[1:0]}
    logic [2:0]  rdq_tail;
    logic [4:0]  rdq_cnt;
    logic rdq_fire;

    logic [6:0]  infl_mem [0:cpu_pkg::AXI_MAX_RD-1];   // {idx[4:0], src[1:0]}
    logic [2:0]  infl_tail;
    logic [2:0]  infl_head;
    logic [4:0]  infl_cnt;

    logic [40:0] rsp_mem [0:7];               // {data, err, idx[4:0], src[1:0]}
    logic [2:0]  rsp_head, rsp_tail;
    logic [3:0]  rsp_cnt;
    logic [2:0]  rdq_head;
    logic r_pop, rsp_pop;
    wire [38:0] rdq_head_val = rdq_mem[rdq_head];
    wire [40:0] rsp_head_val = rsp_mem[rsp_head];

    wire [31:0] rd_usage32 = {27'b0, rdq_cnt} + {27'b0, infl_cnt} + {28'b0, rsp_cnt};
    assign rd_push_ready = !reset && $unsigned(rd_usage32) < cpu_pkg::AXI_MAX_RD;
    wire rd_push = rd_push_valid && rd_push_ready;

    assign rd_rsp_valid = (rsp_cnt != 4'd0);
    assign rd_rsp_src   = rsp_head_val[1:0];
    assign rd_rsp_idx   = rsp_head_val[6:2];
    assign rd_rsp_err   = rsp_head_val[8:7];
    assign rd_rsp_data  = rsp_head_val[40:9];
    assign rready = 1'b1;
    assign bready = 1'b1;
    assign r_pop  = rvalid;
    assign rsp_pop = rd_rsp_valid && rd_rsp_ready;

    // issue AR directly from the rdQ head (head only moves on fire)
    assign arvalid = !reset && (rdq_cnt != 5'd0) &&
                     (infl_cnt < cpu_pkg::AXI_MAX_RD[4:0]);
    assign araddr  = rdq_head_val[38:7];
    assign rdq_fire = arvalid && arready;
    wire [6:0]  infl_wdata = rdq_head_val[6:0];  // queue entry's {idx, src}

    // ============================== write side ==============================
    logic [71:0] wrq_mem [0:cpu_pkg::AXI_MAX_WR-1]; // {addr, data, strb, tag}
    logic [2:0]  wrq_head, wrq_tail;
    logic [4:0]  wrq_cnt;
    wire wr_accept = wr_push_valid && wr_push_ready;

    // issue stage: one entry parked; AW/W handshakes tracked independently
    logic        iss_valid;
    logic [31:0] iss_addr, iss_data;
    logic [3:0]  iss_strb;
    logic        aw_fire_d, w_fire_d;
    logic [4:0]  bwait_cnt;

    // B ordering FIFO: tags of pair-completed writes, in issue order
    // (depth 16 >= AXI_MAX_WR+1 outstanding writes; 4-bit pointers fit it)
    logic [3:0]  tq_mem [0:15];
    logic [3:0]  tq_head, tq_tail;

    wire [71:0] wrq_head_val = wrq_mem[wrq_head];
    // Complete the current pair and replace it at the same edge. AW and W
    // remain independent: a channel that already fired stays deasserted
    // until the other channel also finishes, keeping stalled payload stable.
    wire iss_room = (!iss_valid || pair_done) && (bwait_cnt < WR_CAP);
    wire direct_write = iss_room && (wrq_cnt == 0) && wr_accept;
    wire iss_load = iss_room && ((wrq_cnt != 0) || wr_accept);
    wire wrq_push = wr_accept && !direct_write;
    wire wrq_pop = iss_load && (wrq_cnt != 0);
    wire [71:0] iss_payload = (wrq_cnt != 0) ? wrq_head_val :
        {wr_push_addr, wr_push_data, wr_push_strb, wr_push_tag};

    wire [31:0] wr_usage32 = {27'b0, wrq_cnt} + {27'b0, bwait_cnt} + {31'b0, iss_valid};
    assign wr_push_ready = !reset && $unsigned(wr_usage32) < cpu_pkg::AXI_MAX_WR;

    assign awvalid = !reset && iss_valid && !aw_fire_d;
    assign wvalid  = !reset && iss_valid && !w_fire_d;
    assign awaddr  = iss_addr;
    assign wdata   = iss_data;
    assign wstrb   = iss_strb;
    wire aw_fire = awvalid && awready;
    wire w_fire  = wvalid  && wready;
    wire pair_done = iss_valid && (aw_fire_d || aw_fire) &&
                                  (w_fire_d || w_fire);

    wire [3:0] tq_head_val = tq_mem[tq_head];
    assign wr_rsp_valid = bvalid;
    assign wr_rsp_tag   = tq_head_val;

    // ================================ core ff ================================

    wire [38:0] rdq_wdata = {rd_push_addr, rd_push_idx, rd_push_src};
    wire [71:0] wrq_wdata = {wr_push_addr, wr_push_data, wr_push_strb, wr_push_tag};
    always_ff @(posedge clock) begin
        if (reset) begin
            rdq_head <= '0; rdq_tail <= '0; rdq_cnt <= '0;
            infl_head <= '0; infl_tail <= '0; infl_cnt <= '0;
            rsp_head <= '0; rsp_tail <= '0; rsp_cnt <= '0;
            wrq_head <= '0; wrq_tail <= '0; wrq_cnt <= '0;
            iss_valid <= 1'b0; aw_fire_d <= 1'b0; w_fire_d <= 1'b0;
            bwait_cnt <= '0;
            tq_head <= '0; tq_tail <= '0;
        end else begin
            // ---- read queue ----
            if (rd_push) begin
                rdq_mem[rdq_tail] <= rdq_wdata;
                rdq_tail <= rdq_tail + 3'd1;
            end
            if (rdq_fire) rdq_head <= rdq_head + 3'd1;
            case ({rd_push, rdq_fire})
                2'b10: rdq_cnt <= rdq_cnt + 5'd1;
                2'b01: rdq_cnt <= rdq_cnt - 5'd1;
                default: ;
            endcase
            // ---- infl: push at AR fire, pop at R valid ----
            if (rdq_fire) begin
                infl_mem[infl_tail] <= infl_wdata;
                infl_tail <= infl_tail + 3'd1;
            end
            if (r_pop) infl_head <= infl_head + 3'd1;
            case ({rdq_fire, r_pop})
                2'b10: infl_cnt <= infl_cnt + 5'd1;
                2'b01: infl_cnt <= infl_cnt - 5'd1;
                default: ;
            endcase
            // ---- response skid ----
            if (r_pop) begin
                rsp_mem[rsp_tail] <= {rdata, rresp[1:0], infl_mem[infl_head]};
                rsp_tail <= rsp_tail + 3'd1;
            end
            if (rsp_pop) rsp_head <= rsp_head + 3'd1;
            case ({r_pop, rsp_pop})
                2'b10: rsp_cnt <= rsp_cnt + 4'd1;
                2'b01: rsp_cnt <= rsp_cnt - 4'd1;
                default: ;
            endcase
            // ---- write queue ----
            if (wrq_push) begin
                wrq_mem[wrq_tail] <= wrq_wdata;
                wrq_tail <= wrq_tail + 3'd1;
            end
            if (wrq_pop) wrq_head <= wrq_head + 3'd1;
            case ({wrq_push, wrq_pop})
                2'b10: wrq_cnt <= wrq_cnt + 5'd1;
                2'b01: wrq_cnt <= wrq_cnt - 5'd1;
                default: ;
            endcase
            // ---- write issue stage ----
            if (iss_load) begin
                iss_valid <= 1'b1;
                iss_addr  <= iss_payload[71:40];
                iss_data  <= iss_payload[39:8];
                iss_strb  <= iss_payload[7:4];
                aw_fire_d <= 1'b0;
                w_fire_d  <= 1'b0;
                tq_mem[tq_tail] <= iss_payload[3:0];
                tq_tail <= tq_tail + 4'd1;
            end else if (iss_valid) begin
                if (aw_fire) aw_fire_d <= 1'b1;
                if (w_fire)  w_fire_d  <= 1'b1;
                if (pair_done) iss_valid <= 1'b0;
            end
            if (bvalid) tq_head <= tq_head + 4'd1;
            // B accounting: single combined update
            if (pair_done || bvalid)
                bwait_cnt <= bwait_cnt - (bvalid ? 5'd1 : 5'd0) + (pair_done ? 5'd1 : 5'd0);
        end
    end
endmodule
