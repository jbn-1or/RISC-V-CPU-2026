// verilog/cpu_pkg.sv —— 跨人接口契约。任何改动必须双人评审（PR）。
// 文件名必须与 package 名一致，否则 Verilator 报 DECLFILENAME 警告。
// 详见 references/teamplan.md（§2 接口契约与内部微协议）。
package cpu_pkg;

    // ---- 参数：报告要求的参数化集中放这里 ----
    parameter int ISSUE_WIDTH = 2;      // 发射宽度
    parameter int ROB_DEPTH   = 32;     // ROB 深度（E2：64 可参数化，实测默认 32 更优）
    parameter int PRF_NUM     = 64;     // 物理寄存器个数（E3：128 可参数化，实测默认 64 更优）
    parameter int IQ_DEPTH    = 16;     // 发射队列深度
    // M4: 写回同拍唤醒/操作数旁路（WB->IQ 同拍 CAM 命中即选中，操作数从
    // 写回总线直取）——省掉依赖链的 1 拍唤醒延迟；0 = 关闭（回归基线对照）。
    parameter int WB_BYPASS   = 1;

    // ---- 增补参数（docs/design.md §3.4）----
    parameter int DECODE_WIDTH = 2;     // 译码/重命名/提交宽度
    parameter int LDQ_DEPTH    = 8;     // 在飞 load 上限
    parameter int STQ_DEPTH    = 8;     // store 缓冲深度
    parameter int MUL_LAT      = 4;     // 乘法流水级数
    parameter int DIV_LAT_MAX  = 32;    // 除法迭代上限（radix-2，运行期提前退出）
    parameter int LINE_BYTES   = 32;    // 行大小（16 或 32 B：4/8 × AXI 字）
    parameter int IC_LINES     = 128;   // I$ 组内行数（总行 = ×ASSOC）
    parameter int DC_LINES     = 1024;  // D$ 组内行数（E6：32KB；须为 2 的幂）
    parameter int ASSOC        = 1;     // 相联度（1=直接映射）
    parameter int MSHR_N       = 2;     // D$ 未命中合并项
    parameter int AXI_MAX_RD   = 8;     // 在飞 AXI 读上限（≤ 从机队列 16 − 裕量）
    parameter int AXI_MAX_WR   = 8;     // 在飞 AXI 写上限
    parameter int BHT_ENTRIES  = 256;
    parameter int BTB_ENTRIES  = 128;
    parameter int RAS_DEPTH    = 16;
    // gshare GHR width: BHT index = pc[index] ^ ghr. 0 = plain pc-indexed BHT.
    // History folded into the index is min(BP_GHR_BITS, log2(BHT_ENTRIES));
    // raising BP_GHR_BITS beyond log2(BHT_ENTRIES) adds no distinguishing bits.
    parameter int BP_GHR_BITS  = 8;

    // ---- 通用常量 ----
    localparam logic [31:0] EXIT_ADDR = 32'h8000_0000;  // 退出 MMIO 地址
    localparam logic [4:0]  ZERO_REG  = 5'd0;           // x0

    // ---- AXI 请求源标记（响应路由用）----
    typedef enum logic [1:0] {
        MRF_IC = 2'd0,  // 取指/ICache refill
        MRF_DC = 2'd1,  // DCache refill（字索引走 idx）
        MRF_LS = 2'd2   // 保留名（当前 M3 设计所有读均经 D$；此值暂无生产者）
    } mrf_e;

    // ---- 指令大类 ----
    typedef enum logic [3:0] {
        OP_LUI, OP_AUIPC, OP_JAL, OP_JALR, OP_BR,
        OP_LOAD, OP_STORE, OP_ALU, OP_MUL, OP_DIV, OP_NOP
    } op_e;

    // ---- 执行单元分类（发射队列按此选择发射端口）----
    typedef enum logic [2:0] { FU_ALU, FU_MUL, FU_DIV, FU_LSU, FU_BR } fu_e;

    // ---- A 的 decoder 产出 == B 的消费格式，字段只增不删 ----
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
        logic        is_branch;  // 控制流指令（预测/冲刷用）：条件分支与 JALR 置 1
        logic        is_ret;     // 返回指令（JALR 且 rs1∈{x1,x5} 且 rd=x0）：RAS 弹栈/RAS 预测
        logic        is_exit;    // 退出写，必须按序提交（译码期恒 0；退出在运行期地址判定）
        logic        is_fuse;    // DIV/REM 同源融合标记（解码期成对检测，见 design §6.4.3）
        logic [2:0]  funct3;     // 原始 funct3：ALU 子操作 / 分支条件类型 / load-store 宽度与符号
        logic [6:0]  funct7;     // 原始 funct7：区分 add-sub、srl-sra 等（op_e 已区分 M 扩展大类）
        logic        illegal;    // 未实现/保留编码（CSR/FENCE/ECALL/EBREAK 等）置位，仅自检用
    } decoded_t;

    // ---- 内部微协议载荷：valid 由发送方寄存，ready 由接收方生成 ----
    typedef struct packed {
        logic     valid;
        decoded_t insn;
    } fetch_out_t;               // IF -> ID

    // ---- 写回事件：执行单元 -> ROB ----
    typedef struct packed {
        logic        valid;
        logic [$clog2(PRF_NUM)-1:0] prf_tag;  // 目的物理寄存器号，位宽随 PRF_NUM 参数化
        logic [$clog2(ROB_DEPTH)-1:0] rob;    // 来源 ROB 号：由 ROB 按号标 complete
        logic [31:0] result;
    } writeback_t;

    // ---- 冲刷广播：BRU/解析 -> 全局（每拍至多 1 次，design §4.3）----
    typedef struct packed {
        logic        valid;   // 本拍发生误预测冲刷
        logic [31:0] pc;      // 重定向 PC（taken→目标，not-taken→pc+4）
        logic [$clog2(ROB_DEPTH)-1:0] rob; // 肇事分支 ROB 号（冲刷严格年幼于它）
        logic [5:0]  bsf;     // 该分支之前 FE 已译码的分支计数（模 64），供 FE 截断幼年指令
    } flush_t;

    // ---- 访存请求：B（AGU/LSQ）-> A（Cache/AXI），valid 由 B 寄存、ready 由 A 生成 ----
    typedef struct packed {
        logic        is_store;               // 0=load，1=store
        logic [31:0] addr;                   // 字节地址（自然对齐）；SB/SH 靠 wstrb 掩码
        logic [31:0] wdata;                  // store 写数据（load 时忽略）
        logic [3:0]  wstrb;                  // store 字节掩码（SW=4'hf）；load 时忽略
        logic [2:0]  funct3;                  // 宽度/符号扩展语义，同指令 funct3
        logic [$clog2(ROB_DEPTH)-1:0] rob;   // 来源 ROB 号：响应配对 + flush 后丢弃过期响应
    } mem_req_t;

    // ---- 访存响应：A -> B。miss 由 A 的 MSHR 内部处理，B 不感知 miss/重试：
    //      resp.valid 只在数据真正就绪时才拉高，B 侧纯 valid/ready 等待。
    //      响应可能乱序返回，B 用 rob 号与在飞请求配对；flush 后 A 仍会完成已收下的
    //      请求（已发出的 AXI 不能撤回），B 按 rob 号丢弃过期响应 ----
    typedef struct packed {
        logic        valid;
        logic        is_store;               // 与对应请求配对
        logic [$clog2(ROB_DEPTH)-1:0] rob;   // 响应对应的请求来源
        logic [31:0] rdata;                  // load 数据（store 响应时忽略）
    } mem_resp_t;

    // ==== M2 增补（docs/design.md §4.2/§5.1/§6；纯新增，不动既有字段）====

    // FE→rename 2 路流元素（= IFB 表项内容，design §5.1）
    typedef struct packed {
        logic        valid;
        decoded_t    insn;
        logic [5:0]  bsf;          // 该指令之前 FE 已译码分支数（mod 64）
        logic        pred_taken;   // BP 方向/返回猜测
        logic [31:0] pred_target;  // 预测目标（RAS/BTB，无则 0）
        logic [$clog2(BHT_ENTRIES)-1:0] bix;  // gshare BHT 索引（取指时算好，随指令到 BRU 训练；位宽随 BHT_ENTRIES）
    } fe2rn_t;

    // ROB 表项（design §6.2.1，字段一致）
    typedef struct packed {
        logic       valid;
        logic [4:0] rd;
        logic [$clog2(PRF_NUM)-1:0] pdst;
        logic [$clog2(PRF_NUM)-1:0] old_pdst;
        logic       is_load;
        logic       is_store;
        logic       is_branch;
        logic       is_jalr;
        logic       done;
        logic       flushed_dep;
    } rob_entry_t;

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
        logic [5:0]  bsf;
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
        logic [5:0]  bsf;
        logic        pred_taken;
        logic [31:0] pred_target;
        logic [$clog2(BHT_ENTRIES)-1:0] bix;
        // M8 (§16.4): stores may issue on address (rs1) alone; this tells the
        // LSU whether the rs2 *value* carried alongside is already valid, or
        // must be filled later by writeback-bus CAM on ps2.
        logic        rs2_ready;
    } issue_t;

    // 发射端口编号（2×ALU + BRU/MUL/DIV/LSU）
    typedef enum logic [2:0] {
        IUP_ALU0, IUP_ALU1, IUP_BRU, IUP_MUL, IUP_DIV, IUP_LSU
    } iup_e;

    // 冲刷环距谓词（design §4.3）：rob 号 i 是否严格年轻于冲刷点 frob。
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

    // 非缓存地址判定（design §7.5/§7.6）：addr[31:28] != 0 → 绕过 D$（含退出 MMIO）。
    // 单点定义，供 dcache（load 侧）与 lsu_a（store 侧）共用，避免两处副本漂移。
    function automatic logic is_uncached(input logic [31:0] addr);
        is_uncached = (addr[31:28] != 4'd0);
    endfunction

endpackage
