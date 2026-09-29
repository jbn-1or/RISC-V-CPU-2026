// verilog/cpu_pkg.sv —— 跨人接口契约。任何改动必须双人评审（PR）。
// 文件名必须与 package 名一致，否则 Verilator 报 DECLFILENAME 警告。
// 详见 references/分工方案.md 附录 A。
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
    } decoded_t;

    // ---- 内部微协议载荷：valid 由发送方寄存，ready 由接收方生成 ----
    typedef struct packed {
        logic     valid;
        decoded_t insn;
    } fetch_out_t;               // IF -> ID

    // ---- 写回事件：执行单元 -> ROB ----
    typedef struct packed {
        logic        valid;
        logic [5:0]  prf_tag;    // 目的物理寄存器号（PRF_NUM=64 时 6 位）
        logic [31:0] result;
    } writeback_t;

endpackage
