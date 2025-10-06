# Issue 3: 未连接的模块端口

## 优先级：低（代码整洁性）

## 问题摘要
在 `top.v` 模块中，`frame_read_write_m0` 实例存在两个未连接的输出端口。虽然这不会导致功能错误，但会降低代码的可读性，并可能掩盖潜在的设计意图缺失。

## 已发现的未连接端口

### 1. read_finish 端口
**位置：** `src/top.v`, 行 222
```verilog
frame_read_write frame_read_write_m0(
    ...
    .read_clk                   (video_clk           ),
    .read_req                   (video_read_req           ),
    .read_req_ack               (video_read_req_ack       ),
    .read_finish                (                   ),     // ← 未连接
    .read_addr_0                (24'd0              ),
    ...
);
```

### 2. write_finish 端口
**位置：** `src/top.v`, 行 240
```verilog
frame_read_write frame_read_write_m0(
    ...
    .write_clk                  (sd_card_clk        ),
    .write_req                  (sd_card_write_req        ),
    .write_req_ack              (sd_card_write_req_ack    ),
    .write_finish               (                 ),       // ← 未连接
    .write_addr_0               (24'd0            ),
    ...
);
```

## 端口定义分析

根据 `frame_read_write.v` 模块定义：

```verilog
// src/frame_read_write.v, 行 33-35
input                            read_req,          // data read module read request
output                           read_req_ack,      // data read module read request response
output                           read_finish,       // data read module read request finish

// src/frame_read_write.v, 行 59-61
input                            write_req,         // data write module write request
output                           write_req_ack,     // data write module write request response
output                           write_finish,      // data write module write request finish
```

这些是**完成指示信号**，用于通知上层模块数据传输已完成。

## 问题分析

### 可能的原因

1. **设计意图：** 当前设计可能使用 `req/ack` 握手机制已经足够，不需要额外的完成信号
2. **未来功能：** 这些端口可能是为未来功能预留的
3. **遗留代码：** 可能是从其他项目复制过来但尚未使用的接口

### 潜在风险

虽然未连接的输出端口通常不会导致功能问题，但存在以下风险：

1. **可读性降低** - 代码审查者可能会困惑为何定义了但不使用
2. **设计意图不明** - 不清楚是有意忽略还是遗漏连接
3. **综合工具警告** - 某些综合工具可能会对未使用的信号发出警告
4. **未来维护困难** - 其他开发者可能误以为这些信号无用而删除相关逻辑

### 当前握手机制

项目当前使用的是 `req/ack` 握手：
- `read_req` → `read_req_ack`
- `write_req` → `write_req_ack`

根据 `frame_fifo_read.v` 和 `frame_fifo_write.v` 的实现：
- `finish` 信号在状态机到达 `S_END` 状态时置高
- `ack` 信号在状态机到达 `S_ACK` 状态时置高

两者的区别：
- **ack** - 表示请求已被接受，数据传输**开始**
- **finish** - 表示数据传输**完成**

## 建议的解决方案

### 方案1：连接并使用finish信号（推荐）

如果设计需要知道传输何时完成，应该连接这些信号：

```verilog
// 添加wire声明
wire video_read_finish;
wire sd_card_write_finish;

// 连接端口
frame_read_write frame_read_write_m0(
    ...
    .read_finish                (video_read_finish        ),
    ...
    .write_finish               (sd_card_write_finish     ),
    ...
);

// 可以将这些信号用于状态监控、LED指示或其他调试目的
```

### 方案2：明确注释为未使用（次选）

如果确认不需要这些信号，应该添加明确的注释：

```verilog
frame_read_write frame_read_write_m0(
    ...
    .read_finish                (  /* unused */          ),
    ...
    .write_finish               (  /* unused */          ),
    ...
);
```

### 方案3：使用本地wire连接但不使用（最佳实践）

这是FPGA设计中常见的做法，消除警告但保持设计清晰：

```verilog
// 声明但不使用的wire
wire _unused_read_finish;
wire _unused_write_finish;

frame_read_write frame_read_write_m0(
    ...
    .read_finish                (_unused_read_finish      ),
    ...
    .write_finish               (_unused_write_finish     ),
    ...
);
```

## 可能的使用场景

`finish` 信号可以用于：

1. **状态监控** - 在顶层模块追踪数据传输完成状态
2. **LED指示** - 显示SD卡读取或视频帧传输完成
3. **性能统计** - 测量帧传输时间
4. **错误处理** - 检测传输超时（如果在预期时间内未完成）
5. **调试支持** - 将完成信号连接到ILA（集成逻辑分析仪）

## 实施步骤

如果选择方案1（连接并使用）：

1. 在 `top.v` 中添加wire声明
2. 连接 `read_finish` 和 `write_finish` 端口
3. 决定如何使用这些信号（LED、监控等）
4. 更新相关文档

如果选择方案3（连接但标记为未使用）：

1. 添加带 `_unused_` 前缀的wire声明
2. 连接端口到这些wire
3. 添加注释说明为何不使用

## 影响范围

修改影响非常小：
- **仅影响：** `top.v` 模块
- **无功能影响：** 不改变现有功能
- **综合结果：** 未使用的信号会被优化掉，不影响资源使用

## 建议的GitHub Issue标题

**"代码整洁：连接或明确标注 frame_read_write 模块的未使用端口"**

## 标签建议
- `good first issue` - 适合新贡献者
- `code-quality` - 代码质量
- `documentation` - 文档（如果选择添加注释）

## 参考文件

- `src/top.v` - 包含未连接端口的顶层模块
- `src/frame_read_write.v` - 模块定义
- `src/frame_fifo_read.v` - read_finish信号的实现
- `src/frame_fifo_write.v` - write_finish信号的实现
