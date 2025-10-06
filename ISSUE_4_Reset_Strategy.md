# Issue 4: 复位策略审查

## 优先级：中（设计健壮性）

## 问题摘要
项目中存在复位信号的极性不一致问题，以及可能缺少跨时钟域复位的同步释放机制。需要审查和统一复位策略以确保设计的健壮性。

## 复位信号分析

### 顶层模块的复位信号

**位置：** `src/top.v`

顶层模块使用 **低电平有效** 的复位信号：
```verilog
// 行 3
input rst_n,  // 低电平有效复位
```

### 子模块的复位连接

在 `top.v` 中，不同子模块接收到的复位信号极性**不一致**：

#### 1. 接收低电平有效复位的模块

```verilog
// seg_scan 模块 - 行 144
seg_scan seg_scan_m0(
    .clk                        (clk                      ),
    .rst_n                      (rst_n                    ),  // ← 低电平有效
    ...
);

// hdmi_tx 模块 - 行 191
u3_hdmi_tx(
    .PXLCLK_I(video_clk),
    .RST_N (rst_n),                                             // ← 低电平有效
    ...
);
```

#### 2. 接收高电平有效复位的模块（~rst_n）

```verilog
// sd_card_bmp 模块 - 行 117
sd_card_bmp sd_card_bmp_m0(
    .clk                        (sd_card_clk              ),
    .rst                        (~rst_n ),                      // ← 高电平有效
    ...
);

// video_timing_data 模块 - 行 160
video_timing_data video_timing_data_m0(
    .video_clk                  (video_clk                ),
    .rst                        (~rst_n    ),                   // ← 高电平有效
    ...
);

// video_delay 模块 - 行 173
video_delay video_delay_m0(
    .video_clk                  (video_clk                ),
    .rst                        (~rst_n    ),                   // ← 高电平有效
    ...
);

// frame_read_write 模块 - 行 209
frame_read_write frame_read_write_m0(
    .mem_clk                    (ext_mem_clk),
    .rst                        (~rst_n),                       // ← 高电平有效
    ...
);

// sdram 模块 - 行 255
sdram U3(
    .Clk                (ext_mem_clk),
    .Rst                (~rst_n),                               // ← 高电平有效
    ...
);
```

## 子模块的复位实现

### frame_fifo_read 和 frame_fifo_write

这两个模块使用 **异步复位，高电平有效**：

```verilog
// frame_fifo_read.v, 行 83
always@(posedge mem_clk or posedge rst)
begin
    if(rst == 1'b1)
        // 复位逻辑
    else
        // 正常逻辑
end
```

### FIFO IP核的复位

异步FIFO模块（`afifo_16_32_256.v`）实现了 **异步复位，同步释放** 机制：

```verilog
// al_ip/afifo_16_32_256.v, 行 71-86
//Asynchronous reset synchronous release on the write side
always @(posedge clkw or posedge rst)
begin
    if (rst) begin
        asy_w_rst0 <= 1'b1;
        asy_w_rst1 <= 1'b1;
    end
    else begin
        asy_w_rst0 <= 1'b0;
        asy_w_rst1 <= asy_w_rst0;  // 两级同步器
    end
end

// 读时钟域也有类似的同步释放机制
```

这是 **良好的设计实践**，避免了复位恢复时的亚稳态问题。

## 问题分析

### 1. 复位极性不一致 ⚠️

**问题：** 顶层模块使用 `rst_n`（低电平有效），但传递给子模块时：
- 有些模块直接使用 `rst_n`
- 大多数模块使用 `~rst_n`（取反为高电平有效）

**风险：**
- 代码可读性降低
- 容易在添加新模块时出错
- 维护困难

### 2. 异步复位风格 ✓

**现状：** 大部分模块使用异步复位（`always @(posedge clk or posedge rst)`）

**优点：**
- 可以在任何时候复位系统，不依赖时钟
- FPGA全局复位网络支持

**缺点（如果处理不当）：**
- 复位释放时可能产生亚稳态
- 跨时钟域复位传播可能不一致

### 3. 跨时钟域复位同步 ⚠️

**问题：** 在 `top.v` 中，同一个 `rst_n` 信号被直接（或取反后）传递给工作在不同时钟域的模块：

- `sd_card_clk` 域：`sd_card_bmp`
- `video_clk` 域：`video_timing_data`, `video_delay`
- `ext_mem_clk` 域：`frame_read_write`, `sdram`
- 无时钟域：`seg_scan`（使用输入时钟 `clk`）

**风险：**
- 复位信号在不同时钟域中释放的时间可能不同
- 可能导致亚稳态和初始化问题
- 不同模块可能在不同时钟周期退出复位状态

### 4. 部分模块已有保护 ✓

**FIFO IP核** 已经实现了异步复位同步释放，这是好的实践。

## 建议的解决方案

### 方案1：统一复位极性并实现同步复位释放（推荐）

#### 步骤1：在顶层模块为每个时钟域创建同步复位

```verilog
module top(
    input clk,
    input rst_n,  // 保持低电平有效的输入
    ...
);

// 为每个时钟域生成同步复位（高电平有效）
reg [1:0] rst_sync_sd_card;
reg [1:0] rst_sync_video;
reg [1:0] rst_sync_ext_mem;
reg [1:0] rst_sync_sys;

wire rst_sd_card;
wire rst_video;
wire rst_ext_mem;
wire rst_sys;

// SD卡时钟域复位同步器
always @(posedge sd_card_clk or negedge rst_n) begin
    if (!rst_n) begin
        rst_sync_sd_card <= 2'b11;
    end else begin
        rst_sync_sd_card <= {rst_sync_sd_card[0], 1'b0};
    end
end
assign rst_sd_card = rst_sync_sd_card[1];

// 视频时钟域复位同步器
always @(posedge video_clk or negedge rst_n) begin
    if (!rst_n) begin
        rst_sync_video <= 2'b11;
    end else begin
        rst_sync_video <= {rst_sync_video[0], 1'b0};
    end
end
assign rst_video = rst_sync_video[1];

// 外部存储时钟域复位同步器
always @(posedge ext_mem_clk or negedge rst_n) begin
    if (!rst_n) begin
        rst_sync_ext_mem <= 2'b11;
    end else begin
        rst_sync_ext_mem <= {rst_sync_ext_mem[0], 1'b0};
    end
end
assign rst_ext_mem = rst_sync_ext_mem[1];

// 系统时钟域复位同步器
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rst_sync_sys <= 2'b11;
    end else begin
        rst_sync_sys <= {rst_sync_sys[0], 1'b0};
    end
end
assign rst_sys = rst_sync_sys[1];
```

#### 步骤2：使用同步后的复位信号

```verilog
sd_card_bmp sd_card_bmp_m0(
    .clk                        (sd_card_clk              ),
    .rst                        (rst_sd_card              ),  // 使用同步复位
    ...
);

video_timing_data video_timing_data_m0(
    .video_clk                  (video_clk                ),
    .rst                        (rst_video                ),  // 使用同步复位
    ...
);

frame_read_write frame_read_write_m0(
    .mem_clk                    (ext_mem_clk              ),
    .rst                        (rst_ext_mem              ),  // 使用同步复位
    ...
);
```

### 方案2：最小化改动 - 仅添加注释和文档

如果不想修改现有设计，至少应该：

1. 在代码中添加清晰的注释，说明复位策略
2. 文档化每个模块的复位极性
3. 为将来的维护者提供指导

```verilog
// 复位策略说明：
// - 顶层输入：rst_n（低电平有效）
// - 内部转换：~rst_n（高电平有效）用于大多数模块
// - 异步复位：所有时序逻辑使用异步复位
// - 注意：不同时钟域使用相同的复位源，依赖IP核的内部同步
```

### 方案3：创建复位管理模块（高级）

创建一个专门的复位管理模块：

```verilog
module reset_manager (
    input  wire clk_in,          // 输入时钟
    input  wire rst_n_in,        // 异步复位输入（低电平有效）
    
    input  wire sd_card_clk,
    input  wire video_clk,
    input  wire ext_mem_clk,
    
    output wire rst_sd_card,     // 同步复位输出（高电平有效）
    output wire rst_video,
    output wire rst_ext_mem,
    output wire rst_sys
);
    // 实现各时钟域的复位同步器
endmodule
```

## 时序约束建议

无论采用哪种方案，都应该在SDC约束文件中添加：

```tcl
# 设置异步复位路径为false path（如果使用异步复位同步释放）
set_false_path -from [get_ports rst_n] -to [get_registers *rst_sync*]

# 或者设置最大延迟
set_max_delay -from [get_ports rst_n] -to [get_registers *rst_sync*[0]] 10.0
```

## 实施优先级

1. **高优先级：** 为跨时钟域的复位添加同步器（方案1）
2. **中优先级：** 统一复位极性命名
3. **低优先级：** 创建复位管理模块（方案3）

## 影响范围

- **主要修改：** `src/top.v`
- **可能需要修改：** 子模块如果需要更改端口名称
- **测试建议：** 重点测试上电复位和运行时复位

## 参考资料

推荐阅读关于FPGA复位最佳实践：
- Xilinx WP272: "Get Smart About Reset"
- Altera/Intel: "Recommended Design Practices"

## 建议的GitHub Issue标题

**"设计改进：统一复位策略并实现跨时钟域复位同步"**

## 标签建议
- `enhancement` - 功能改进
- `reliability` - 可靠性
- `best-practices` - 最佳实践

## 参考文件

- `src/top.v` - 复位信号分配
- `src/frame_fifo_read.v` - 异步复位实现示例
- `src/frame_fifo_write.v` - 异步复位实现示例
- `al_ip/afifo_16_32_256.v` - 异步复位同步释放实现示例（良好实践）
