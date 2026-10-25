// Shared configuration, pipeline payloads and address/age predicates.
// Module responsibilities and timing contracts: docs/architecture.md.
package cpu_pkg;

    // ---- Backend configuration ----
    // Supported widths: 1 or 2. Fetch/writeback retain two physical lanes;
    // ISSUE_WIDTH bounds IQ grants, DECODE_WIDTH bounds rename and retirement.
    parameter int ISSUE_WIDTH = 2;
    parameter int ROB_DEPTH   = 32;
    parameter int PRF_NUM     = 64;
    parameter int IQ_DEPTH    = 8;
    // Wake/select in the writeback cycle; operands bypass directly from BA/BB.
    parameter int WB_BYPASS   = 1;
    parameter int EARLY_REDIRECT = 0;  // registered recovery isolates issue from fetch

    parameter int DECODE_WIDTH = 2;     // 译码/重命名/提交宽度
    parameter int LDQ_DEPTH    = 8;
    parameter int STQ_DEPTH    = 16;
    parameter int MUL_LAT      = 4;     // 乘法流水级数

    // ---- Memory: 1/2-way I$/D$, fixed total capacity at each line count ----
    parameter int LINE_BYTES   = 32;    // 行大小（16 或 32 B：4/8 × AXI 字）
    parameter int IC_LINES     = 64;    // total I$ lines, across all ways
    parameter int DC_LINES     = 512;   // D$ 16 KiB; power of two
    parameter int ASSOC        = 1;     // 1=direct mapped, 2=two-way round robin
    parameter int MSHR_N       = 2;     // D$ 未命中合并项
    parameter int AXI_MAX_RD   = 8;     // 在飞 AXI 读上限（≤ 从机队列 16 − 裕量）
    parameter int AXI_MAX_WR   = 8;     // 在飞 AXI 写上限
    // ---- Branch prediction ----
    parameter int BHT_ENTRIES  = 128;
    parameter int BTB_ENTRIES  = 64;
    parameter int RAS_DEPTH    = 16;
    // gshare GHR width: BHT index = pc[index] ^ ghr. 0 = plain pc-indexed BHT.
    // History folded into the index is min(BP_GHR_BITS, log2(BHT_ENTRIES));
    // raising BP_GHR_BITS beyond log2(BHT_ENTRIES) adds no distinguishing bits.
    parameter int BP_GHR_BITS  = 8;

    // ---- 通用常量 ----
    localparam logic [4:0]  ZERO_REG  = 5'd0;           // x0

    // ---- AXI 请求源标记（响应路由用）----
    typedef enum logic [1:0] {
        MRF_IC = 2'd0,  // 取指/ICache refill
        MRF_DC = 2'd1,  // DCache refill（字索引走 idx）
        MRF_LS = 2'd2   // 保留；当前所有数据读（含 uncached）均经 D$
    } mrf_e;

    // ---- 指令大类 ----
    typedef enum logic [3:0] {
        OP_LUI, OP_AUIPC, OP_JAL, OP_JALR, OP_BR,
        OP_LOAD, OP_STORE, OP_ALU, OP_MUL, OP_DIV, OP_NOP
    } op_e;

    // ---- 执行单元分类（发射队列按此选择发射端口）----
    typedef enum logic [2:0] { FU_ALU, FU_MUL, FU_DIV, FU_LSU, FU_BR } fu_e;

    // ---- Decoder output, carried through rename and issue ----
    typedef struct packed {
        logic [31:0] pc;         // 本条指令的 pc（auipc/jal/jalr 需要）
        logic [31:0] imm;        // 已经扩展好的立即数
        logic [4:0]  rd;
        logic [4:0]  rs1;
        logic [4:0]  rs2;
        op_e         op;
        fu_e         fu;
        logic        uses_rs1;   // 是否读 rs1（重命名/记分牌用）
        logic        uses_rs2;
        logic        uses_imm;   // OP_ALU 的 B 端口取 imm（I 型算术置 1）
        logic        is_ret;     // 返回指令（JALR 且 rs1∈{x1,x5} 且 rd=x0）：RAS 弹栈/RAS 预测
        logic [2:0]  funct3;     // 原始 funct3：ALU 子操作 / 分支条件类型 / load-store 宽度与符号
        logic [6:0]  funct7;     // 原始 funct7：区分 add-sub、srl-sra 等（op_e 已区分 M 扩展大类）
    } decoded_t;

    // ---- 写回事件：执行单元 -> ROB ----
    typedef struct packed {
        logic        valid;
        logic [$clog2(PRF_NUM)-1:0] prf_tag;  // 目的物理寄存器号，位宽随 PRF_NUM 参数化
        logic [$clog2(ROB_DEPTH)-1:0] rob;    // 来源 ROB 号：由 ROB 按号标 complete
        logic [31:0] result;
    } writeback_t;

    // ---- Registered recovery broadcast: BRU -> ROB/IQ/LSQ ----
    typedef struct packed {
        logic        valid;   // 本拍发生误预测冲刷
        logic [31:0] pc;      // 重定向 PC（taken→目标，not-taken→pc+4）
        logic [$clog2(ROB_DEPTH)-1:0] rob; // 肇事分支 ROB 号（冲刷严格年幼于它）
    } flush_t;

    // ---- LSQ -> memory_subsystem: separate load and store valid/ready channels ----
    // Selection may fall through combinationally. A stalled selection is latched;
    // speculative loads can be withdrawn on flush. Retired stores are irrevocable.
    typedef struct packed {
        logic        is_store;               // 0=load，1=store
        logic [31:0] addr;                   // 字节地址（自然对齐）；SB/SH 靠 wstrb 掩码
        logic [31:0] wdata;                  // store 写数据（load 时忽略）
        logic [3:0]  wstrb;                  // store 字节掩码（SW=4'hf）；load 时忽略
        logic [2:0]  funct3;                  // 宽度/符号扩展语义，同指令 funct3
        logic [$clog2(ROB_DEPTH)-1:0] rob;   // 来源 ROB 号：响应配对 + flush 后丢弃过期响应
    } mem_req_t;

    // ---- memory_subsystem -> LSQ: data, store completion or load replay ----
    // resp_replay is a separate qualifier: retry the SENT load from WAIT.
    // Responses have no ready input here; LSQ consumes them immediately. D$ and
    // MSHR kill bits suppress flushed waiters before a ROB number can be reused.
    typedef struct packed {
        logic        valid;
        logic        is_store;               // 与对应请求配对
        logic [$clog2(ROB_DEPTH)-1:0] rob;   // 响应对应的请求来源
        logic [31:0] rdata;                  // load 数据（store 响应时忽略）
    } mem_resp_t;

    // ---- Frontend -> rename: two IFB entries, accepted as a prefix ----
    typedef struct packed {
        decoded_t    insn;
        logic        pred_taken;   // BP 方向/返回猜测
        logic [31:0] pred_target;  // 预测目标（RAS/BTB，无则 0）
        logic [$clog2(BHT_ENTRIES)-1:0] bix;  // gshare BHT 索引（取指时算好，随指令到 BRU 训练；位宽随 BHT_ENTRIES）
    } fe2rn_t;

    // rename 分派载荷（rename→rob/iq，拍内原子）
    typedef struct packed {
        decoded_t    insn;
        logic [$clog2(PRF_NUM)-1:0] ps1;
        logic [$clog2(PRF_NUM)-1:0] ps2;
        logic        rs1_ready;
        logic        rs2_ready;
        logic [$clog2(PRF_NUM)-1:0] pdst;
        logic [$clog2(PRF_NUM)-1:0] old_pdst;
        logic [$clog2(ROB_DEPTH)-1:0] rob;
        logic        pred_taken;
        logic [31:0] pred_target;
        logic [$clog2(BHT_ENTRIES)-1:0] bix;
    } renamed_t;

    // IQ→执行端口发射载荷（操作数值由顶层读 PRF 后并入，不入此结构）
    typedef struct packed {
        decoded_t    insn;
        logic [$clog2(PRF_NUM)-1:0] ps1;
        logic [$clog2(PRF_NUM)-1:0] ps2;
        logic [$clog2(PRF_NUM)-1:0] pdst;
        logic [$clog2(ROB_DEPTH)-1:0] rob;
        logic        pred_taken;
        logic [31:0] pred_target;
        logic [$clog2(BHT_ENTRIES)-1:0] bix;
        // Stores may issue on address (rs1) alone; this tells the
        // LSU whether the rs2 *value* carried alongside is already valid, or
        // must be filled later by writeback-bus CAM on ps2.
        logic        rs2_ready;
    } issue_t;

    // 发射端口编号（2×ALU + BRU/MUL/DIV/LSU）
    typedef enum logic [2:0] {
        IUP_ALU0, IUP_ALU1, IUP_BRU, IUP_MUL, IUP_DIV, IUP_LSU
    } iup_e;

    // 冲刷环距谓词：rob 号 i 是否严格年轻于冲刷点 frob。
    // dtail = (ROB tail - frob) mod ROB_DEPTH，由 ROB 单点计算后广播，避免
    // ROB/IQ/LSU 各自重复推导而漂移。位宽随 ROB_DEPTH 派生（RB+1 位域）：
    // 0 = 无幼年项；ROB_DEPTH = 满窗（frob 恰为满 ROB 头部，幼年项为其余
    // ROB_DEPTH-1 项）；1..ROB_DEPTH-1 = 正常窗宽。
    localparam int RB = $clog2(ROB_DEPTH);   // rob 号位宽
    function automatic logic flush_younger(input logic [RB-1:0] i,
                                           input logic [RB-1:0] frob,
                                           input logic [RB:0] dtail);
        logic [RB-1:0] d;
        d = i - frob;
        flush_younger = (d != {RB{1'b0}}) && ({1'b0, d} < dtail);
    endfunction

    // 非缓存地址判定：addr[31:28] != 0 → 绕过 D$（含退出 MMIO）。
    // 单点定义，供 dcache（load 侧）与 memory_subsystem（store 侧）共用，避免两处副本漂移。
    function automatic logic is_uncached(input logic [31:0] addr);
        is_uncached = (addr[31:28] != 4'd0);
    endfunction

endpackage
