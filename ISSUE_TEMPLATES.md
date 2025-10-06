# Quick Reference: Suggested GitHub Issues

This document provides ready-to-use GitHub Issue templates based on the code review.

## Issue Templates

### Issue #1: Parameterize Video Configuration (Medium Priority)

**Title:** 重构建议：使用参数替换硬编码的视频分辨率和帧大小常量

**Labels:** `enhancement`, `refactoring`, `maintainability`

**Description:**

当前项目中存在多处硬编码的视频相关数值常量，降低了代码的可维护性和可移植性。

#### 发现的硬编码值

1. `src/top.v:120` - `16'd640` (图像宽度)
2. `src/top.v:228` - `24'd307200` (帧大小 = 640×480)
3. `src/top.v:246` - `24'd307200` (帧大小 = 640×480)

#### 建议的解决方案

在 `top.v` 模块中添加参数定义：

```verilog
parameter VIDEO_WIDTH  = 640;
parameter VIDEO_HEIGHT = 480;
parameter FRAME_SIZE   = VIDEO_WIDTH * VIDEO_HEIGHT;
```

然后在模块实例化中使用这些参数：

```verilog
.bmp_width(VIDEO_WIDTH[15:0])
.read_len(FRAME_SIZE[23:0])
.write_len(FRAME_SIZE[23:0])
```

#### 好处

- 更易维护：修改分辨率只需更改一处参数
- 更易理解：参数名称清晰表达含义
- 更灵活：支持不同分辨率配置

#### 详细信息

参见代码审查文档：`ISSUE_2_Magic_Numbers.md`

---

### Issue #2: Improve Reset Strategy (Medium Priority)

**Title:** 设计改进：统一复位策略并实现跨时钟域复位同步

**Labels:** `enhancement`, `reliability`, `best-practices`

**Description:**

项目中存在复位信号极性不一致和跨时钟域复位缺少同步的问题。

#### 发现的问题

1. **复位极性不一致**
   - 顶层输入：`rst_n`（低电平有效）
   - 某些模块接收 `rst_n`（低电平）
   - 大多数模块接收 `~rst_n`（高电平）

2. **跨时钟域复位缺少同步**
   - 同一个 `rst_n` 信号被传递给工作在不同时钟域的模块
   - 可能导致复位释放时的亚稳态问题

#### 建议的解决方案

为每个时钟域创建同步复位：

```verilog
// SD卡时钟域复位同步器
reg [1:0] rst_sync_sd_card;
always @(posedge sd_card_clk or negedge rst_n) begin
    if (!rst_n)
        rst_sync_sd_card <= 2'b11;
    else
        rst_sync_sd_card <= {rst_sync_sd_card[0], 1'b0};
end
wire rst_sd_card = rst_sync_sd_card[1];

// 为 video_clk 和 ext_mem_clk 创建类似的同步器
```

#### 好处

- 避免亚稳态问题
- 统一复位策略
- 提高设计健壮性

#### 详细信息

参见代码审查文档：`ISSUE_4_Reset_Strategy.md`

---

### Issue #3: Handle Unconnected Module Ports (Low Priority)

**Title:** 代码整洁：连接或明确标注 frame_read_write 模块的未使用端口

**Labels:** `good first issue`, `code-quality`, `documentation`

**Description:**

在 `top.v` 模块中，`frame_read_write_m0` 实例存在两个未连接的输出端口。

#### 未连接的端口

1. `src/top.v:222` - `.read_finish()` 
2. `src/top.v:240` - `.write_finish()`

#### 建议的解决方案

**方案1：** 连接并使用（推荐用于调试）

```verilog
wire video_read_finish;
wire sd_card_write_finish;

.read_finish(video_read_finish)
.write_finish(sd_card_write_finish)
```

**方案2：** 明确标记为未使用

```verilog
wire _unused_read_finish;
wire _unused_write_finish;

.read_finish(_unused_read_finish)
.write_finish(_unused_write_finish)
```

#### 好处

- 提高代码可读性
- 明确设计意图
- 便于未来维护

#### 详细信息

参见代码审查文档：`ISSUE_3_Unconnected_Ports.md`

---

### Issue #4: Enhance CDC Documentation (Low Priority - Optional)

**Title:** 文档改进：为CDC路径添加注释和时序约束

**Labels:** `documentation`, `constraints`

**Description:**

项目的CDC处理实现良好，但可以通过增强文档和约束来进一步提高可维护性。

#### 当前CDC实现（已经很好）

- ✓ 异步FIFO（带Gray码转换）
- ✓ 控制信号三级同步器
- ✓ 异步复位同步释放

#### 建议的改进

1. **添加代码注释**
   - 明确标注所有CDC路径
   - 说明同步器的作用

2. **添加时序约束**
   ```tcl
   set_false_path -from [get_ports rst_n] -to [get_registers *rst_sync*]
   ```

3. **使用属性标注**
   ```verilog
   (* ASYNC_REG = "TRUE" *)
   reg [2:0] sync_reg;
   ```

#### 好处

- 防止工具误优化同步器
- 提高代码可维护性
- 便于审查和验证

#### 详细信息

参见代码审查文档：`ISSUE_1_CDC_Analysis.md`

---

## Implementation Priority

建议按以下优先级实施：

1. **Issue #2** (Reset Strategy) - 中优先级，影响设计健壮性
2. **Issue #1** (Magic Numbers) - 中优先级，影响可维护性
3. **Issue #3** (Unconnected Ports) - 低优先级，适合新贡献者
4. **Issue #4** (CDC Documentation) - 低优先级，可选改进

## Notes

- **不建议创建**原审查指令中要求的"关键风险：CDC缺失"Issue，因为CDC实现已经很好
- 所有Issue都提供了详细的解决方案和实施步骤
- 每个Issue都可以独立实施，互不影响

## Review Documents

完整的审查文档：

- `CODE_REVIEW_SUMMARY.md` - 总结报告
- `ISSUE_1_CDC_Analysis.md` - CDC详细分析
- `ISSUE_2_Magic_Numbers.md` - 硬编码值问题
- `ISSUE_3_Unconnected_Ports.md` - 未连接端口
- `ISSUE_4_Reset_Strategy.md` - 复位策略
- `审查完成报告.md` - 中文总结报告
