# Issue 2: 硬编码数值（"魔术数字"）问题

## 优先级：中（代码可维护性）

## 问题摘要
项目中存在多处硬编码的数值常量，这些常量与视频分辨率和帧大小相关。使用硬编码值会降低代码的可维护性和可移植性，当需要更改分辨率或帧大小时，需要在多个位置手动修改。

## 已发现的硬编码值

### 1. 图像宽度 (640)
**位置：** `src/top.v`, 行 120
```verilog
sd_card_bmp  sd_card_bmp_m0(
    .clk                        (sd_card_clk              ),
    .rst                        (~rst_n ),
    .key                        (key1                     ),
    .state_code                 (state_code               ),
    .bmp_width                  (16'd640                  ),  //image width
    ...
);
```

### 2. 帧大小 - 读操作 (307200)
**位置：** `src/top.v`, 行 228
```verilog
frame_read_write frame_read_write_m0(
    ...
    .read_len                   (24'd307200         ), //frame size//24'd786432
    ...
);
```

### 3. 帧大小 - 写操作 (307200)
**位置：** `src/top.v`, 行 246
```verilog
frame_read_write frame_read_write_m0(
    ...
    .write_len                  (24'd307200       ), //frame size
    ...
);
```

## 问题分析

### 数值关系
- **640** = 图像宽度
- **307200** = 640 × 480 = 图像宽度 × 图像高度（像素总数）

这些值显然是为 **640×480 VGA分辨率** 硬编码的。注释中提到的 `24'd786432` 是另一个可能的帧大小（可能对应 1024×768）。

### 潜在问题

1. **难以维护** - 更改分辨率需要在多处修改
2. **容易出错** - 手动计算和修改可能导致不一致
3. **可读性差** - 数值307200的含义不够直观
4. **不灵活** - 无法通过参数轻松切换不同分辨率

## 建议的解决方案

### 方案1：使用模块参数（推荐）

在 `top.v` 模块中添加参数定义：

```verilog
module top(
    // ... 端口定义 ...
);

// 现有参数
parameter MEM_DATA_BITS         = 32  ;
parameter ADDR_BITS             = 21  ;
parameter BUSRT_BITS            = 10  ;

// 新增视频参数
parameter VIDEO_WIDTH           = 640 ;     // 视频宽度
parameter VIDEO_HEIGHT          = 480 ;     // 视频高度
parameter FRAME_SIZE            = VIDEO_WIDTH * VIDEO_HEIGHT;  // 帧大小（像素数）

// ... 其余代码 ...
```

然后在模块实例化中使用这些参数：

```verilog
sd_card_bmp  sd_card_bmp_m0(
    .clk                        (sd_card_clk              ),
    .rst                        (~rst_n                   ),
    .key                        (key1                     ),
    .state_code                 (state_code               ),
    .bmp_width                  (VIDEO_WIDTH[15:0]        ),  // 使用参数
    ...
);

frame_read_write frame_read_write_m0(
    ...
    .read_len                   (FRAME_SIZE[23:0]         ), // 使用参数
    ...
    .write_len                  (FRAME_SIZE[23:0]         ), // 使用参数
    ...
);
```

### 方案2：使用 `define 宏（备选）

在单独的头文件（如 `video_params.vh`）中定义：

```verilog
`ifndef VIDEO_PARAMS_VH
`define VIDEO_PARAMS_VH

`define VIDEO_WIDTH     640
`define VIDEO_HEIGHT    480
`define FRAME_SIZE      (`VIDEO_WIDTH * `VIDEO_HEIGHT)

`endif
```

然后在 `top.v` 中引用：

```verilog
`include "video_params.vh"

module top(...);
    ...
    .bmp_width                  (16'd`VIDEO_WIDTH         ),
    .read_len                   (24'd`FRAME_SIZE          ),
    .write_len                  (24'd`FRAME_SIZE          ),
    ...
endmodule
```

## 实施步骤

1. 在 `top.v` 模块头部添加视频分辨率参数
2. 计算帧大小参数（宽度 × 高度）
3. 替换所有硬编码的 `16'd640` 为参数
4. 替换所有硬编码的 `24'd307200` 为参数
5. 验证综合和仿真结果
6. 更新文档说明如何修改分辨率

## 额外建议

如果项目未来需要支持多种分辨率，可以考虑：

1. 创建分辨率配置包文件
2. 使用 `localparam` 为常用分辨率定义别名：
   ```verilog
   localparam VGA_WIDTH  = 640;
   localparam VGA_HEIGHT = 480;
   localparam SVGA_WIDTH = 800;
   localparam SVGA_HEIGHT = 600;
   localparam XGA_WIDTH  = 1024;
   localparam XGA_HEIGHT = 768;
   ```

## 影响范围

修改这些硬编码值的影响应该是局部的：
- **主要影响：** `top.v` 模块的实例化部分
- **次要影响：** 可能需要检查 `sd_card_bmp` 和 `frame_read_write` 模块是否对这些值有内部依赖
- **无影响：** FIFO和底层存储控制器（它们基于数据流工作，不依赖具体分辨率）

## 建议的GitHub Issue标题

**"重构建议：使用参数替换硬编码的视频分辨率和帧大小常量"**

## 标签建议
- `enhancement` - 功能改进
- `refactoring` - 代码重构
- `maintainability` - 可维护性

## 参考文件

- `src/top.v` - 包含所有硬编码值的顶层模块
