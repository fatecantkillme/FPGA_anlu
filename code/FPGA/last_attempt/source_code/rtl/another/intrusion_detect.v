module intrusion_detect(
    input              video_clk,
    input              rst,
    input      [23:0]  read_data,     // {R[23:16], G[15:8], B[7:0]}
    input              hs,
    input              vs,
    input              de,
    input              bg_capture,    // 背景捕获触发信号（按键）
    output             res,           // 闯入检测结果
    // 视频输出接口
    output     [23:0]  video_out,     // 标注后的视频输出
    output             hs_out,
    output             vs_out,
    output             de_out
);

// -------------------------------
// 参数配置
// -------------------------------
parameter integer FRAME_WIDTH  = 16'd640;  // 水平像素数
parameter integer FRAME_HEIGHT = 16'd480;  // 垂直像素数

// 背景差分阈值（灰度差异）
parameter [7:0]  DIFF_THRESHOLD = 8'd40;   // 像素差异阈值（增大以减少误检）
// 面积阈值：检测到的运动像素数量
parameter integer AREA_THRESHOLD = 19'd3000; // 运动区域面积阈值（约1%画面）

// 滑动平均参数（背景更新速率）
parameter [3:0]  BG_ALPHA = 4'd4;          // 背景更新权重 (1/16)

// -------------------------------
// 信号延迟与对齐
// -------------------------------
reg        de_d0, de_d1, de_d2, de_d3;
reg        vs_d0, vs_d1, vs_d2, vs_d3;
reg        hs_d0, hs_d1, hs_d2, hs_d3;
wire       vs_falling = (~vs_d0 & vs_d1);

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        de_d0 <= 1'b0;
        de_d1 <= 1'b0;
        de_d2 <= 1'b0;
        de_d3 <= 1'b0;
        vs_d0 <= 1'b0;
        vs_d1 <= 1'b0;
        vs_d2 <= 1'b0;
        vs_d3 <= 1'b0;
        hs_d0 <= 1'b0;
        hs_d1 <= 1'b0;
        hs_d2 <= 1'b0;
        hs_d3 <= 1'b0;
    end else begin
        de_d0 <= de;
        de_d1 <= de_d0;
        de_d2 <= de_d1;
        de_d3 <= de_d2;
        vs_d0 <= vs;
        vs_d1 <= vs_d0;
        vs_d2 <= vs_d1;
        vs_d3 <= vs_d2;
        hs_d0 <= hs;
        hs_d1 <= hs_d0;
        hs_d2 <= hs_d1;
        hs_d3 <= hs_d2;
    end
end

// -------------------------------
// RGB转灰度
// -------------------------------
reg  [7:0] gray_current;  // 当前帧灰度值
reg  [7:0] gray_d1;       // 灰度延迟1拍
reg  [7:0] gray_d2;       // 灰度延迟2拍（用于梯度计算）

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        gray_current <= 8'd0;
        gray_d1 <= 8'd0;
        gray_d2 <= 8'd0;
    end else begin
        if (de) begin
            // Y = 0.299*R + 0.587*G + 0.114*B
            // 近似: Y = (R*77 + G*150 + B*29) >> 8
            gray_current <= (read_data[23:16] * 77 + read_data[15:8] * 150 + read_data[7:0] * 29) >> 8;
        end
        gray_d1 <= gray_current;
        gray_d2 <= gray_d1;
    end
end

// -------------------------------
// 背景建模（滑动平均 + 多帧平均）
// -------------------------------
reg  [7:0]  bg_model;     // 背景模型（灰度）
reg  [7:0]  bg_model_prev;// 前一像素的背景（用于梯度计算）
reg  [4:0]  bg_frame_cnt; // 背景建模帧计数器（建模16帧）
reg         bg_ready;     // 背景模型就绪标志
reg         bg_capture_d0, bg_capture_d1;
wire        bg_capture_trigger = bg_capture_d0 & ~bg_capture_d1;

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        bg_capture_d0 <= 1'b0;
        bg_capture_d1 <= 1'b0;
    end else begin
        bg_capture_d0 <= bg_capture;
        bg_capture_d1 <= bg_capture_d0;
    end
end

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        bg_model <= 8'd0;
        bg_model_prev <= 8'd0;
        bg_frame_cnt <= 5'd0;
        bg_ready <= 1'b0;
    end else begin
        // 背景捕获触发：重新建模
        if (bg_capture_trigger) begin
            bg_ready <= 1'b0;
            bg_frame_cnt <= 5'd0;
        end
        // 帧开始：检查是否完成背景建模
        else if (vs_falling && !bg_ready) begin
            if (bg_frame_cnt >= 5'd16) begin
                // 已完成16帧采集，标记就绪
                bg_ready <= 1'b1;
            end else begin
                bg_frame_cnt <= bg_frame_cnt + 1'b1;
            end
        end
        // 多帧平均建模或背景更新
        else if (de_d0) begin
            // 保存前一像素背景用于梯度计算
            bg_model_prev <= bg_model;
            
            if (!bg_ready) begin
                // 多帧平均建模：逐渐累积背景
                // 使用滑动平均：BG = BG * (7/8) + Current * (1/8)
                bg_model <= bg_model - (bg_model >> 3) + (gray_current >> 3);
            end else begin
                // 背景就绪后，更慢速更新适应缓慢变化
                // BG_new = BG_old * (15/16) + Current * (1/16)
                bg_model <= bg_model - (bg_model >> BG_ALPHA) + (gray_current >> BG_ALPHA);
            end
        end
    end
end

// -------------------------------
// 背景差分与自适应二值化
// -------------------------------
reg [7:0]  diff_abs;      // 绝对差值
reg [7:0]  bg_gradient;   // 背景梯度（水平方向）
reg [7:0]  adaptive_threshold;  // 自适应阈值
reg        is_motion;     // 运动像素标记

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        diff_abs <= 8'd0;
        bg_gradient <= 8'd0;
        adaptive_threshold <= 8'd0;
        is_motion <= 1'b0;
    end else begin
        if (de_d1 && bg_ready) begin
            // 计算背景梯度（水平方向）
            bg_gradient <= (bg_model > bg_model_prev) ? 
                           (bg_model - bg_model_prev) : 
                           (bg_model_prev - bg_model);
            
            // 计算绝对差值
            diff_abs <= (gray_d1 > bg_model) ? (gray_d1 - bg_model) : (bg_model - gray_d1);
            
            // 自适应阈值计算
            // 1. 基于背景亮度的调整
            // 2. 基于背景梯度的调整（强边缘区域增大阈值）
            if (bg_gradient > 8'd30) begin
                // 背景有强梯度（边缘），大幅增加阈值
                adaptive_threshold <= DIFF_THRESHOLD + (DIFF_THRESHOLD >> 1) + (bg_gradient >> 2);
            end else if (bg_model > 8'd200) begin
                // 高亮度区域，增加阈值
                adaptive_threshold <= DIFF_THRESHOLD + (DIFF_THRESHOLD >> 1);
            end else if (bg_model > 8'd128) begin
                // 中亮度区域，小幅增加阈值
                adaptive_threshold <= DIFF_THRESHOLD + (DIFF_THRESHOLD >> 2);
            end else begin
                // 低亮度区域，使用基础阈值
                adaptive_threshold <= DIFF_THRESHOLD;
            end
            
            // 二值化：使用自适应阈值
            is_motion <= (diff_abs > adaptive_threshold);
        end else begin
            is_motion <= 1'b0;
        end
    end
end

// -------------------------------
// 简易形态学滤波（增强版：要求更多邻域支持）
// 使用行缓存实现3x3窗口
// -------------------------------
reg [FRAME_WIDTH-1:0] motion_line1;  // 上一行运动标记
reg [FRAME_WIDTH-1:0] motion_line2;  // 当前行运动标记
reg [10:0] col_cnt;  // 列计数器
reg        is_motion_filtered;
reg [3:0]  neighbor_cnt;  // 邻域运动像素计数

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        col_cnt <= 11'd0;
        motion_line1 <= {FRAME_WIDTH{1'b0}};
        motion_line2 <= {FRAME_WIDTH{1'b0}};
        is_motion_filtered <= 1'b0;
        neighbor_cnt <= 4'd0;
    end else begin
        if (de_d2) begin
            // 更新列计数
            if (col_cnt < FRAME_WIDTH - 1) begin
                col_cnt <= col_cnt + 1'b1;
            end else begin
                col_cnt <= 11'd0;
                // 行结束：移动行缓存
                motion_line1 <= motion_line2;
                motion_line2 <= {FRAME_WIDTH{1'b0}};
            end
            
            // 存储当前运动标记
            motion_line2[col_cnt] <= is_motion;
            
            // 增强型形态学滤波：统计3×3窗口中运动像素数量
            // 要求至少4个以上邻域像素为运动才判定为真实运动
            if (col_cnt > 0 && col_cnt < FRAME_WIDTH - 1) begin
                // 计算邻域运动像素数
                neighbor_cnt <= 
                    (motion_line1[col_cnt-1] ? 4'd1 : 4'd0) +
                    (motion_line1[col_cnt]   ? 4'd1 : 4'd0) +
                    (motion_line1[col_cnt+1] ? 4'd1 : 4'd0) +
                    (motion_line2[col_cnt-1] ? 4'd1 : 4'd0) +
                    (is_motion               ? 4'd1 : 4'd0);
                
                // 要求当前像素为运动且邻域至少有3个运动像素（共4个）
                is_motion_filtered <= is_motion && (neighbor_cnt >= 4'd3);
            end else begin
                is_motion_filtered <= 1'b0;  // 边缘不检测
            end
        end
    end
end

// -------------------------------
// 帧级统计：运动区域面积
// -------------------------------
reg [18:0] motion_pixel_cnt;   // 运动像素计数
reg        intrusion_detected; // 闯入检测结果

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        motion_pixel_cnt <= 19'd0;
        intrusion_detected <= 1'b0;
    end else begin
        // 帧开始：结算上一帧
        if (vs_falling) begin
            intrusion_detected <= (motion_pixel_cnt > AREA_THRESHOLD) && bg_ready;
            motion_pixel_cnt <= 19'd0;
        end else begin
            // 帧内累计运动像素
            if (de_d3 && is_motion_filtered && bg_ready) begin
                motion_pixel_cnt <= motion_pixel_cnt + 1'b1;
            end
        end
    end
end

assign res = intrusion_detected;

// -------------------------------
// 视频输出：运动标注
// -------------------------------
reg [23:0] video_data_delay1;
reg [23:0] video_data_delay2;
reg [23:0] video_data_delay3;
reg [23:0] video_data_reg;
reg        is_motion_delay;

// 延迟原始视频数据以对齐
always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        video_data_delay1 <= 24'd0;
        video_data_delay2 <= 24'd0;
        video_data_delay3 <= 24'd0;
        is_motion_delay <= 1'b0;
    end else begin
        video_data_delay1 <= read_data;
        video_data_delay2 <= video_data_delay1;
        video_data_delay3 <= video_data_delay2;
        is_motion_delay <= is_motion_filtered;
    end
end

// 运动标注：检测到运动时显示为绿色
always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        video_data_reg <= 24'd0;
    end else begin
        if (is_motion_delay && de_d3 && bg_ready) begin
            // 运动像素标记为绿色
            video_data_reg <= 24'h00FF00;
        end else if (!bg_ready && de_d3) begin
            // 背景建模中显示蓝色提示
            video_data_reg <= {8'd0, 8'd0, video_data_delay3[7:0]};
        end else begin
            // 非运动像素保持原样
            video_data_reg <= video_data_delay3;
        end
    end
end

// 输出信号分配
assign video_out = video_data_reg;
assign hs_out = hs_d3;
assign vs_out = vs_d3;
assign de_out = de_d3;

endmodule
