// M0 骨架：端口严格按 README 模板，暂时把所有请求置为无效。
// 目的：先验证工具链（make build / make run / make test）能跑通，功能后续逐个里程碑补。
module student_top (
    input  wire        clock,
    input  wire        reset,     // 高电平复位，启动保持 5 周期

    // AXI4-Lite 读地址通道 (AR)
    output wire [31:0] araddr,
    output wire        arvalid,
    input  wire        arready,

    // AXI4-Lite 读数据通道 (R)
    input  wire [31:0] rdata,
    input  wire [1:0]  rresp,
    input  wire        rvalid,
    output wire        rready,

    // AXI4-Lite 写地址通道 (AW)
    output wire [31:0] awaddr,
    output wire        awvalid,
    input  wire        awready,

    // AXI4-Lite 写数据通道 (W)
    output wire [31:0] wdata,
    output wire [3:0]  wstrb,
    output wire        wvalid,
    input  wire        wready,

    // AXI4-Lite 写响应通道 (B)
    input  wire [1:0]  bresp,
    input  wire        bvalid,
    output wire        bready
);
    // M0：CPU 逻辑还没实现，所有请求都保持无效，因此仿真会一直跑到周期上限。
    assign araddr  = 32'h0;
    assign arvalid = 1'b0;
    assign rready  = 1'b0;

    assign awaddr  = 32'h0;
    assign awvalid = 1'b0;

    assign wdata   = 32'h0;
    assign wstrb   = 4'h0;
    assign wvalid  = 1'b0;

    assign bready  = 1'b0;
endmodule
