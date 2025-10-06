# Issue 1: 跨时钟域（CDC）处理审查报告

## 优先级：高（关键风险）

## 问题摘要
本项目包含多个时钟域之间的信号传递，需要确认CDC（Clock Domain Crossing）保护措施是否完善。

## 已识别的时钟域

项目中存在三个主要时钟域：

1. **sd_card_clk** - 来自 `sys_pll`，用于SD卡控制器
2. **video_clk** - 来自 `video_pll`，用于视频像素时钟
3. **ext_mem_clk** - 来自 `sys_pll`，用于外部存储器控制器

这些时钟域在 `top.v` 中定义：
```verilog
// 位置: src/top.v, 行 99-112
sys_pll sys_pll_m0(
    .refclk(clk),
    .clk0_out(sd_card_clk),
    .clk1_out(ext_mem_clk),
    .clk2_out(ext_mem_clk_sft),
    .reset(1'b0)
);

video_pll video_pll_m0(
    .refclk(clk),
    .clk0_out(video_clk),
    .clk1_out(hdmi_5x_clk),
    .reset(1'b0)
);
```

## CDC处理分析

### 1. frame_read_write 模块的CDC处理

`frame_read_write` 模块在 `top.v` 中实例化，涉及跨时钟域通信：
- 读时钟：`video_clk` (行 219)
- 写时钟：`sd_card_clk` (行 237)
- 存储控制器时钟：`ext_mem_clk` (行 208)

**位置：** `src/top.v`, 行 207-249

### 2. 异步FIFO的CDC保护 ✓

**良好实践：** 项目使用了带有Gray码转换的异步FIFO模块

在 `frame_read_write.v` 中实例化的FIFO：
- **写FIFO** (`wfifo_32_32_512`)：位于行 89-102
  - 写时钟：`write_clk` (sd_card_clk)
  - 读时钟：`mem_clk` (ext_mem_clk)
  
- **读FIFO** (`rfifo_32_32_512`)：位于行 138-151
  - 写时钟：`mem_clk` (ext_mem_clk)
  - 读时钟：`read_clk` (video_clk)

FIFO IP核实现（`al_ip/afifo_16_32_256.v`）包含：
- Gray码编码器和解码器（行 262-278）
- 双级同步器用于跨时钟域传递地址指针（行 264, 265）
- 异步复位同步释放机制（行 71-100）

### 3. 控制信号的CDC保护 ✓

**良好实践：** 控制信号使用了多级同步器

在 `frame_fifo_read.v` 和 `frame_fifo_write.v` 中：
- 使用**三级触发器链**同步 `read_req` / `write_req` 信号
- 位置：`frame_fifo_read.v` 行 53-55, 87-99
- 位置：`frame_fifo_write.v` 行 51-53, 84-96

示例代码：
```verilog
// frame_fifo_read.v
reg read_req_d0;  // 第一级
reg read_req_d1;  // 第二级
reg read_req_d2;  // 第三级

always@(posedge mem_clk or posedge rst) begin
    if(rst == 1'b1) begin
        read_req_d0 <= 1'b0;
        read_req_d1 <= 1'b0;
        read_req_d2 <= 1'b0;
    end else begin
        read_req_d0 <= read_req;
        read_req_d1 <= read_req_d0;
        read_req_d2 <= read_req_d1;
    end
end
```

同样，`read_len` 和 `read_addr_index` 也使用双级同步器进行同步。

## 结论

经过详细审查，项目的CDC处理**总体上是可靠的**：

### ✓ 已实现的CDC保护措施：

1. **异步FIFO** - 使用Gray码转换器和双级同步器处理数据流
2. **控制信号同步** - 使用三级触发器链同步握手信号（read_req, write_req, read_req_ack, write_req_ack）
3. **参数同步** - 使用双级触发器链同步配置参数（read_len, write_len, addr_index等）
4. **异步复位同步释放** - FIFO模块实现了异步复位同步释放机制

### 潜在改进建议：

1. **添加约束文件** - 建议为跨时钟域路径添加适当的时序约束（set_false_path或set_max_delay）
2. **文档化CDC路径** - 建议在代码中添加注释，明确标注所有CDC路径
3. **一致性检查** - 确保所有同步器都使用 `(* ASYNC_REG = "TRUE" *)` 或类似的属性标注，防止工具优化

## 建议的GitHub Issue标题

**不建议创建高优先级Issue**，因为当前CDC实现已经相对完善。

如果需要改进，可以创建：
**"代码改进：增强CDC路径的文档和约束"**（低优先级）

## 参考文件

- `src/top.v` - 顶层模块，时钟域定义
- `src/frame_read_write.v` - 跨时钟域数据传输模块
- `src/frame_fifo_read.v` - 读FIFO控制，包含同步器
- `src/frame_fifo_write.v` - 写FIFO控制，包含同步器
- `al_ip/afifo_16_32_256.v` - 异步FIFO IP核实现
