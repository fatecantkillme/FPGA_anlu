module m_synchronization_header
#(
	parameter DATA_WIDTH = 24                       // Video data one clock data width
)
(
    input   video_clk,
    input                       rst,
	
	input[DATA_WIDTH - 1:0]     read_data,          // Read data
	input                      hs,                 // horizontal synchronization
	input                      vs,                 // vertical synchronization
	input                      de,                 // video valid
    
    output[DATA_WIDTH - 1:0]    video_data,
    output                      video_data_en               
 );

// 行计数器
reg [15:0] line_count;

wire [15:0] tx_line_num;
wire [15:0] half_tx_line_num;
assign tx_line_num=2*(line_count-16'd34);
assign half_tx_line_num=tx_line_num+16'd1;

// 检测下降沿
reg hs_dly, vs_dly;
wire hs_falling, vs_falling;


always @(posedge video_clk) begin
    hs_dly <= hs;
    vs_dly <= vs;
end

assign hs_falling = hs_dly & ~hs;
assign vs_falling = vs_dly & ~vs;

// 行计数器逻辑
always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        line_count <= 16'd0;
    end else if (vs_falling) begin
        line_count <= 16'd0;
    end else if (hs_falling) begin
        line_count <= line_count + 1'b1;
    end
end

reg [DATA_WIDTH - 1:0] out_data;
reg                    out_en;

//除去每帧前0-33的无用行计数
wire line_count_en;
assign line_count_en = (line_count >= 16'd34) && (line_count <= 16'd513);

// 每行像素计数器
reg [15:0] pixel_count;//第一个像素是1

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        pixel_count <= 16'd0;
    end else if (hs_falling) begin
        pixel_count <= 16'd0;
    end else if (de) begin
        pixel_count <= pixel_count + 1'b1;
    end
end

//检测是否到达半行
wire half_line_en;
assign half_line_en =(pixel_count>=16'd320);


//延迟三拍，以塞入半行定位信号
reg [DATA_WIDTH - 1:0]     read_data_d1;
reg [DATA_WIDTH - 1:0]     read_data_d2;
reg [DATA_WIDTH - 1:0]     read_data_d3;
reg                        de_d1;
reg                        de_d2;
reg                        de_d3;
reg                        half_line_en_d1;
reg                        half_line_en_d2;
reg                        half_line_en_d3;

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        half_line_en_d1<=1'b0;
    end 
    else begin
    half_line_en_d1<=half_line_en;
    half_line_en_d2<=half_line_en_d1;
    half_line_en_d3<=half_line_en_d2;
    end
end

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        read_data_d1 <= 24'd0;
        de_d1        <=1'b0;
    end 
    else if (de) begin
        read_data_d1 <= read_data;
        read_data_d2 <= read_data_d1;
        read_data_d3 <= read_data_d2;
        de_d1        <=1'b1;
        de_d2        <=de_d1;
        de_d3        <=de_d2;
    end 
    else
    begin
    read_data_d1<=24'd0;
    read_data_d2 <= read_data_d1;
    read_data_d3 <= read_data_d2;
    de_d1<=1'b0;
    de_d2        <=de_d1;
    de_d3        <=de_d2;
    end
end



assign video_data=out_data;
assign video_data_en=out_en;

//reg h_en;
wire h_en_d0;
reg h_en_d1;
reg h_en_d2;

wire f_en_d0;
reg f_en_d1;
reg f_en_d2;
assign f_en_d0=(hs_falling&&line_count_en);//一行定位信号
assign h_en_d0=((pixel_count==16'd320)&&line_count_en);//半行定位信号

always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        f_en_d1<=1'd0;
        f_en_d2<=1'd0;
        h_en_d1<=1'd0;
        h_en_d2<=1'd0;
    end 
    else 
    begin
        f_en_d1<=f_en_d0;
        f_en_d2<=f_en_d1;
        h_en_d1<=h_en_d0;
        h_en_d2<=h_en_d1;
    end
end


//输出逻辑
always @(posedge video_clk or posedge rst) begin
    if (rst) begin
        out_data <= 24'd0;
        out_en   <= 1'b0;
    end 
    //行首定位信息
    else if (f_en_d0) begin
        out_data <= 24'hff00ff;
        out_en   <= 1'b1;
    end
    else if (f_en_d1) begin
        out_data <= {8'h00,tx_line_num};
        out_en   <= 1'b1;
    end
    else if (f_en_d2) begin
        out_data <= 24'h00ff00;
        out_en   <= 1'b1;
    end 
    //半行定位信息
    else if (h_en_d0) begin
        out_data <= 24'hff00ff;
        out_en   <= 1'b1;
    end
    else if (h_en_d1) begin
        out_data <= {8'h00,tx_line_num+16'd1};
        out_en   <= 1'b1;
    end
    else if (h_en_d2) begin
        out_data <= 24'h00ff00;
        out_en   <= 1'b1;
    end
    //数据
    else if (de&(!half_line_en)) begin
        out_data <= read_data;
        out_en   <= 1'b1;
    end
    else if (de_d3&&(half_line_en_d3))begin
        out_data <= read_data_d3;
        out_en   <= 1'b1;
    end
    
    else
    begin
        out_data <= 24'd0;
        out_en   <= 1'b0;
    end
end


endmodule
