module  fire_detect(
    input              video_clk,
    input              rst,
    input      [23:0]  read_data,     // {R[23:16], G[15:8], B[7:0]}
    input              hs,
    input              vs,
    input              de,
    output             res,
    // 新增视频输出接口
    output     [23:0]  video_out,     // 标注后的视频输出
    output             hs_out,
    output             vs_out,
    output             de_out
);

// -------------------------------
// 参数配置
// -------------------------------
// 帧参数（可根据输入视频分辨率调整）
parameter integer FRAME_WIDTH  = 16'd640; // 水平像素数
parameter integer FRAME_HEIGHT = 16'd480; // 垂直像素数
localparam integer FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;

parameter [7:0]  THRESH_R   = 8'd120; // R亮度下限
parameter [7:0]  THRESH_RB  = 8'd50;  // R-B 差值下限
// 面积阈值：直接使用像素数量
parameter integer AREA_THRESHOLD = 19'd614; // 火焰像素数量阈值

// -------------------------------
// 像素寄存与对齐
// -------------------------------
reg  [7:0] data_R;//synthesis keep
reg  [7:0] data_G;//synthesis keep
reg  [7:0] data_B;//synthesis keep
reg        de_d0, de_d1, de_d2, de_d3;//synthesis keep
reg        vs_d0, vs_d1, vs_d2, vs_d3;
reg        hs_d0, hs_d1, hs_d2, hs_d3;
wire       flage_data_ready; //synthesis keep

assign flage_data_ready = de_d1;

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        data_R  <= 8'd0;
        data_G  <= 8'd0;
        data_B  <= 8'd0;
        de_d0   <= 1'b0;
        de_d1   <= 1'b0;
        de_d2   <= 1'b0;
        de_d3   <= 1'b0;
        vs_d0   <= 1'b0;
        vs_d1   <= 1'b0;
        vs_d2   <= 1'b0;
        vs_d3   <= 1'b0;
        hs_d0   <= 1'b0;
        hs_d1   <= 1'b0;
        hs_d2   <= 1'b0;
        hs_d3   <= 1'b0;
    end else begin
        // 输入握手信号打拍
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

        // 提取RGB数据（与de对齐打一拍）
        if (de) begin
            data_R <= read_data[23:16];
            data_G <= read_data[15:8];
            data_B <= read_data[7:0];
        end
    end
end

// -------------------------------
// 阈值法：像素级火焰判定
// 条件：R足够大，R>G，G>B，且(R-B)大于阈值，同时可选略微加强R对G的优势
// -------------------------------
reg THRESH_is_flame_per_data;//synthesis keep
always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        THRESH_is_flame_per_data <= 1'b0;
    end else begin
        if (flage_data_ready) begin
            // 轻量优化：要求 R 比 G 至少大约 G>>3（~12.5%），避免弱火/噪声
            // 添加额外的约束条件以进一步减少误报：
            // 1. R分量至少占整个像素亮度的较大比例，防止受环境光影响
            // 2. G和B之间的差值不能太小，确保颜色饱和度
            // 3. R分量远大于B分量，火焰特有的颜色特征
            // 4. RGB总和达到一定值，排除过暗区域
            THRESH_is_flame_per_data <= (
                  (data_R > THRESH_R)
               && (data_R > data_G)
               && (data_G > data_B)
               && ((data_R - data_B) > THRESH_RB)
               && (data_R > (data_G + (data_G[7:3])))
               // 要求R分量在整个RGB值中占比显著，增强对典型火焰色的识别
               && (data_R > ((data_R + data_G + data_B) >> 2)) // R>(RGB总和)/4
               // 要求绿色和蓝色之间有明显差异，增强颜色特异性
               && ((data_G - data_B) > (THRESH_RB >> 2))
               // 要求R远大于B，强化火焰颜色特征
               && (data_R > (data_B << 2)) // R > 4*B
               // 要求整体亮度不能太低，排除暗区噪声
               && ((data_R + data_G + data_B) > 8'd100)
            );
        end
        // 移除else分支，保持火焰检测信号状态不被清零
    end
end

// -------------------------------
// 帧级统计：累计有效像素与火焰像素，按面积比例产生帧告警
// -------------------------------
reg [18:0] THRESH_is_flame;   //synthesis keep
reg        fire_detect_r;     // 输出寄存

wire vs_falling = (~vs_d0 & vs_d1); //synthesis keep

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        THRESH_is_flame <= 19'd0;
        fire_detect_r   <= 1'b0;
    end else begin
        // 帧开始：结算上一帧，并清零计数
        if (vs_falling) begin
            // 直接比较火焰像素数量与阈值
            fire_detect_r  <= (THRESH_is_flame > AREA_THRESHOLD);
            THRESH_is_flame <= 19'd0;
        end else begin
            // 帧内累计火焰像素
            if (flage_data_ready && THRESH_is_flame_per_data) begin
                THRESH_is_flame <= THRESH_is_flame + 1'b1;
            end
        end
    end
end

assign res = fire_detect_r;

// -------------------------------
// 视频输出：火焰标注
// -------------------------------
reg [23:0] video_data_reg;
reg [23:0] video_data_delay1;
reg [23:0] video_data_delay2;
reg        is_flame_delay; // 延迟火焰检测信号以对齐

// 延迟原始视频数据以对齐火焰检测结果 - 无条件延迟，保持流水线连续
always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        video_data_delay1 <= 24'd0;
        video_data_delay2 <= 24'd0;
        is_flame_delay <= 1'b0;
    end else begin
        // 无条件传递，包括消隐期
        video_data_delay1 <= read_data;
        video_data_delay2 <= video_data_delay1;
        is_flame_delay <= THRESH_is_flame_per_data;
    end
end

// 火焰标注：检测到火焰像素时显示为红色
always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        video_data_reg <= 24'd0;
    end else begin
        // 根据延迟后的de信号控制输出
        if (is_flame_delay && de_d2) begin
            // 火焰像素标记为亮红色(纯红)
            video_data_reg <= 24'hFF0000;
        end else begin
            // 非火焰像素保持原样
            video_data_reg <= video_data_delay2;
        end
    end
end

//额外延迟一拍与instruction_detect对齐时序
reg [23:0]video_data_d;
always @(posedge video_clk) begin
    video_data_d<=video_data_reg;
end

// 输出信号分配
assign video_out = video_data_d;
assign hs_out = hs_d3;
assign vs_out = vs_d3;
assign de_out = de_d3;

//assign video_out = video_data_reg;
//assign hs_out = hs_d2;
//assign vs_out = vs_d2;
//assign de_out = de_d2;

endmodule
