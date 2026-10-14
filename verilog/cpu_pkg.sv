// verilog/cpu_pkg.sv —— 跨人接口契约。任何改动必须双人评审（PR）。
// 文件名必须与 package 名一致，否则 Verilator 报 DECLFILENAME 警告。
// 详见 references/teamplan.md（§2 接口契约与内部微协议）。
package cpu_pkg;

    // ---- 参数：报告要求的参数化集中放这里 ----
    parameter int ISSUE_WIDTH = 2;      // 发射宽度
    parameter int ROB_DEPTH   = 32;     // ROB 深度
    parameter int PRF_NUM     = 64;     // 物理寄存器个数
    parameter int IQ_DEPTH    = 16;     // 发射队列深度

    // ---- 通用常量 ----
    localparam logic [31:0] EXIT_ADDR = 32'h8000_0000;  // 退出 MMIO 地址
    localparam logic [4:0]  ZERO_REG  = 5'd0;           // x0

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
        logic        is_branch;  // 控制流指令（预测/冲刷用）
        logic        is_exit;    // 退出写，必须按序提交
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
        logic [31:0] result;
    } writeback_t;

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

endpackage
