// Branch predictor unit test (size-generic): BHT direction
// training/saturation, BTB hit/tag/eviction/target reconstruction, dual lookup
// ports, and RAS push/pop/underflow/overflow behavior. All structural sizes are
// read from cpu_pkg so the test tracks BTB_ENTRIES / RAS_DEPTH knobs.
`timescale 1ns/1ps
module tb_bp;
    import cpu_pkg::*;
    logic clock = 0, reset = 1;
    always #5 clock = ~clock;

    localparam int BI  = (BTB_ENTRIES > 1) ? $clog2(BTB_ENTRIES) : 1;
    localparam int BHI = (BHT_ENTRIES > 1) ? $clog2(BHT_ENTRIES) : 1;
    localparam int RD  = RAS_DEPTH;
    // two pcs with the same BTB index, different tag
    localparam [31:0] pA = 32'h0000_0100;
    localparam [31:0] pB = pA + (32'd1 << (BI + 2));
    // a different BTB index (bit 2 differs)
    localparam [31:0] pC = pA + 32'd4;

    logic [31:0] lk0_pc = 0, lk1_pc = 0;
    wire        lk0_dir, lk0_hit, lk1_dir, lk1_hit;
    wire [31:0] lk0_target, lk1_target;

    logic        up_valid = 0;
    logic [31:0] up_pc = 0;
    logic        up_taken = 0;
    logic [BHI-1:0] up_ix = 0;
    logic        up_mispred = 0;

    logic        btb_upd_valid = 0;
    logic [31:0] btb_upd_pc = 0, btb_upd_target = 0;

    logic        s0_v = 0, s0_ret = 0, s0_link = 0;
    logic [31:0] s0_pc = 0;
    logic        s1_v = 0, s1_ret = 0, s1_link = 0;
    logic [31:0] s1_pc = 0;
    logic        s0_cond = 0, s0_pt = 0, s1_cond = 0, s1_pt = 0;
    wire         s0_hit, s1_hit;
    wire [31:0]  s0_top, s1_top;
    wire [BHI-1:0] lk0_ix, lk1_ix;

    bp u (.clock, .reset,
        .lk0_pc, .lk0_dir, .lk0_hit, .lk0_target,
        .lk1_pc, .lk1_dir, .lk1_hit, .lk1_target,
        .up_valid, .up_pc, .up_taken, .up_ix, .up_mispred,
        .btb_upd_valid, .btb_upd_pc, .btb_upd_target,
        .s0_v, .s0_ret, .s0_link, .s0_pc, .s0_hit, .s0_top,
        .s1_v, .s1_ret, .s1_link, .s1_pc, .s1_hit, .s1_top,
        .s0_cond, .s0_pt, .s1_cond, .s1_pt, .lk0_ix, .lk1_ix);

    int errors = 0;
    task automatic chk(input logic cond, input string msg);
        if (!cond) begin
            errors = errors + 1;
            $display("[tb_bp] FAIL: %s", msg);
        end
    endtask
    task automatic step(input int n);
        repeat (n) @(negedge clock);
    endtask
    // let combinational logic settle after driving inputs in the same timestep
    task automatic settle();
        #1;
    endtask

    // one-cycle BHT training pulse. up_ix is set to the pc index so the gshare
    // and bimodal components stay equal (ghr holds 0 here): the tournament then
    // never switches away from bimodal and the direction table trains plainly.
    task automatic bht_up(input logic [31:0] pc, input logic taken);
        up_pc = pc; up_ix = pc[BHI+1:2];
        up_taken = taken; up_valid = 1;
        step(1);
        up_valid = 0;
        step(1);
    endtask

    task automatic btb_up(input logic [31:0] pc, input logic [31:0] tgt);
        btb_upd_pc = pc; btb_upd_target = tgt; btb_upd_valid = 1;
        step(1);
        btb_upd_valid = 0;
        step(1);
    endtask

    initial begin
        repeat (5) @(negedge clock);
        reset = 0;
        step(1);

        // ---------------- BHT: direction, saturation, aliasing ----------------
        lk0_pc = 32'h0000_0100;   // [8:2] = 65
        lk1_pc = 32'h0000_0200;   // [8:2] = 0
        step(1);
        chk(!lk0_dir && !lk1_dir, "BHT reset direction must be not-taken");

        bht_up(32'h0000_0100, 1'b1);              // 01 -> 10
        chk(lk0_dir, "BHT taken #1 -> dir=1");
        bht_up(32'h0000_0100, 1'b1);              // 10 -> 11
        chk(lk0_dir, "BHT taken #2 -> dir=1");
        bht_up(32'h0000_0100, 1'b0);              // 11 -> 10
        chk(lk0_dir, "BHT not-taken #1 -> dir=1");
        bht_up(32'h0000_0100, 1'b0);              // 10 -> 01
        chk(!lk0_dir, "BHT not-taken #2 -> dir=0");
        bht_up(32'h0000_0100, 1'b0);              // 01 -> 00
        bht_up(32'h0000_0100, 1'b0);              // 00 -> 00 (saturated)
        chk(!lk0_dir, "BHT not-taken saturation -> dir=0");

        // aliasing: bit 12 does not participate in the BHT index
        bht_up(32'h0000_1104, 1'b1);
        lk0_pc = 32'h0000_0104;
        step(1);
        chk(lk0_dir, "BHT index aliasing (pc[8:2])");

        // dual ports: port1 sees the same table
        lk1_pc = 32'h0000_1104;
        step(1);
        chk(lk1_dir, "BHT lookup port 1");

        // ---------------- BTB: hit, tag, eviction, target ----------------
        lk0_pc = pA; lk1_pc = pC;
        step(1);
        chk(!lk0_hit && !lk1_hit, "BTB must be empty after reset");

        btb_up(pA, 32'h0000_2abc);
        chk(lk0_hit && (lk0_target == 32'h0000_2abc), "BTB hit + target");
        chk(!lk1_hit, "BTB other index must miss");

        // same index, different tag -> miss
        lk0_pc = pB;
        step(1);
        chk(!lk0_hit, "BTB tag mismatch must miss");

        // retrain the colliding index -> previous entry evicted
        btb_up(pB, 32'h0000_3000);
        chk(lk0_hit && (lk0_target == 32'h0000_3000), "BTB retrain hit");
        lk0_pc = pA;
        step(1);
        chk(!lk0_hit, "BTB colliding entry must be evicted");

        // bit 0 of the stored target is always cleared on reconstruction
        btb_up(32'h0000_0108, 32'h0000_4001);
        lk0_pc = 32'h0000_0108;
        step(1);
        chk(lk0_hit && (lk0_target == 32'h0000_4000), "BTB target bit0 clear");

        // dual ports are independent (distinct indices 1 and 2)
        btb_up(32'h0000_0004, 32'h0000_5000);
        btb_up(32'h0000_0008, 32'h0000_6000);
        lk0_pc = 32'h0000_0004; lk1_pc = 32'h0000_0008;
        step(1);
        chk(lk0_hit && lk1_hit, "BTB dual-port hit");
        chk((lk0_target == 32'h0000_5000) && (lk1_target == 32'h0000_6000),
            "BTB dual-port targets");

        // ---------------- RAS: push/pop, LIFO, underflow, overflow ----------
        step(1);
        s0_v = 1; s0_ret = 1;   // pop on empty
        step(1);
        chk(!s0_hit, "RAS pop on empty must miss");
        s0_ret = 0; s0_v = 0;
        step(1);

        s0_v = 1; s0_link = 1; s0_pc = 32'h10;   // push 0x14
        step(1);
        s0_pc = 32'h20;                          // push 0x24
        step(1);
        s0_link = 0; s0_ret = 1;                 // pop -> 0x24
        settle();
        chk(s0_hit && (s0_top == 32'h24), "RAS LIFO top");
        step(1);
        chk(s0_hit && (s0_top == 32'h14), "RAS second pop");
        step(1);
        chk(!s0_hit, "RAS pop after empty");
        s0_v = 0; s0_ret = 0;
        step(1);

        // same-cycle two pops: s1 sees the stack after s0
        s0_v = 1; s0_link = 1; s0_pc = 32'h30;   // push 0x34
        step(1);
        s0_pc = 32'h40;                          // push 0x44
        step(1);
        s0_link = 0;
        s0_ret = 1; s1_v = 1; s1_ret = 1;
        settle();
        chk(s0_hit && (s0_top == 32'h44), "RAS dual pop s0");
        chk(s1_hit && (s1_top == 32'h34), "RAS dual pop s1 (post-s0 view)");
        step(1);
        s0_ret = 0; s0_v = 0; s1_ret = 0; s1_v = 0;
        settle();
        chk(!s0_hit && !s1_hit, "RAS empty after dual pop");
        step(1);

        // overflow: depth RD, pushes beyond the top are dropped (documented)
        for (int i = 0; i < RD + 2; i = i + 1) begin
            s0_v = 1; s0_link = 1; s0_pc = 32'h1000 + (i << 2);
            step(1);
        end
        s0_link = 0; s0_ret = 1;
        settle();
        chk(s0_hit && (s0_top == (32'h1000 + ((RD - 1) << 2) + 32'd4)),
            "RAS overflow keeps newest top");
        step(1);
        for (int i = 0; i < RD - 2; i = i + 1) begin
            chk(s0_hit, "RAS pop while non-empty");
            step(1);
        end
        chk(s0_hit && (s0_top == 32'h1004), "RAS oldest kept entry (push 0)");
        step(1);
        chk(!s0_hit, "RAS bottom-drop: entries of push RD/RD+1 never present");
        s0_ret = 0; s0_v = 0;
        step(1);

        // Restore the fetch-time history from PC-index XOR carried index.
        // Check externally through lookup indices, including indirect-branch
        // recovery which must restore history without shifting an outcome.
        if (BP_GHR_BITS > 0) begin
            for (int trial = 0; trial < 16; trial++) begin
                logic [BHI-1:0] history, expected;
                localparam int GW = (BP_GHR_BITS > 1) ? BP_GHR_BITS : 2;
                localparam int GH = (GW < BHI) ? GW : BHI;
                history = BHI'((trial * 37 + 3) & ((1 << GH)-1));
                up_pc = 32'h2a4 + 32'(trial * 12);
                up_ix = BHI'(up_pc >> 2) ^ history;
                up_valid = 1'(trial & 1);
                up_taken = 1'((trial >> 1) & 1);
                expected = up_valid ? BHI'(((history << 1) | BHI'(up_taken)) & ((1 << GW)-1))
                                    : history;
                up_mispred = 1;
                step(1);
                up_mispred = 0; up_valid = 0;
                settle();
                chk((lk0_ix ^ BHI'(lk0_pc >> 2)) == expected,
                    $sformatf("GHR recovery port0 trial=%0d", trial));
                chk((lk1_ix ^ BHI'(lk1_pc >> 2)) == expected,
                    $sformatf("GHR recovery port1 trial=%0d", trial));
            end
        end

        // ---------------- report ----------------
        if (errors == 0) $display("[tb_bp] ALL OK");
        else             $fatal(1, "[tb_bp] FAILED: %0d error(s)", errors);
        $finish;
    end
endmodule
