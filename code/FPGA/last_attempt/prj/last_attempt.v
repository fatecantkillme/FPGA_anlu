`timescale 1ns / 1ps

`define UDP_LOOP_BACK
//虽然实际上loopback已经物是人非

module last_attempt( input               m_rst_key,//KEY4
        input               clk_50, 
        input[3:0]               state_key,//状态选择乒乓开关
        input                 key_bg_capture,//背景捕获按键（用于闯入检测）//KEY2
        
        //以太网引脚
        input               phy1_rgmii_rx_clk,
        input               phy1_rgmii_rx_ctl,
        input [3:0]         phy1_rgmii_rx_data,
                                
        output wire         phy1_rgmii_tx_clk,
        output wire         phy1_rgmii_tx_ctl,
        output wire [3:0]   phy1_rgmii_tx_data,
        
        //模块1：led引脚
        output            [3:0] led_data , 
        output            [15:0] dled,
        
        //模块2：hdmi引脚
        output			HDMI_CLK_P,
	    output			HDMI_D2_P,
	    output			HDMI_D1_P,
	    output			HDMI_D0_P,
        
        //模块3：tf卡引脚
        input  sd_bmp_find,//KEY3
        input  sd_miso , 
        output sd_clk  , 
        output sd_cs   , 
        output sd_mosi ,
        
        //模块四：ov5640
        input                 cam_pclk     ,  
        input                 cam_vsync    ,  
        input                 cam_href     ,  
        input   [7:0]         cam_data     ,  
        output                cam_rst_n    ,  
        output                cam_pwdn     ,  
        output                cam_scl      ,  
        inout                 cam_sda      ,
        
        output                buzzer  
        );
//部分以太网参数
parameter  DEVICE             = "EG4";//"PH1","EG4"
parameter  LOCAL_UDP_PORT_NUM = 16'h0001;       
parameter  LOCAL_IP_ADDRESS   = 32'hc0a8f001;       
parameter  LOCAL_MAC_ADDRESS  = 48'h0123456789ab;
parameter  DST_UDP_PORT_NUM   = 16'h0002;       
parameter  DST_IP_ADDRESS     = 32'hc0a8f002;
//部分SDRAM参数
parameter MEM_DATA_BITS         = 32  ;            //external memory user interface data width
parameter ADDR_BITS             = 21  ;            //external memory user interface address width
parameter BUSRT_BITS            = 10  ;            //external memory user interface burst width
//部分OV5640参数
parameter  V_CMOS_DISP = 11'd480;                 
parameter  H_CMOS_DISP = 11'd640;                 	
parameter  TOTAL_H_PIXEL = H_CMOS_DISP + 12'd1216;
parameter  TOTAL_V_PIXEL = V_CMOS_DISP + 12'd504;  


wire rst_key_stable;
reg rst_key=1'b1;
reg [12:0] m_rst_key_cnt;

assign rst_key_stable=m_rst_key;
//50us防抖
always@(posedge clk_50)
    begin
        if(rst_key_stable!=rst_key)
        begin
            m_rst_key_cnt<=m_rst_key_cnt+1'b1;
            if(m_rst_key_cnt==13'd5000)
            begin
                rst_key<=rst_key_stable;
                m_rst_key_cnt<=13'b0;
            end
        end
        else
        begin
            m_rst_key_cnt<=13'b0;
        end
    end
    
wire [3:0]   led;
wire         app_rx_data_valid; 
wire [7:0]   app_rx_data;       
wire [15:0]  app_rx_data_length;
wire [15:0]  app_rx_port_num;

wire         udp_tx_ready;
wire         app_tx_ack;
wire         app_tx_data_request;
wire         app_tx_data_valid; 
wire [7:0]   app_tx_data;       
wire  [15:0] udp_data_length;

wire  [7:0]  tpg_data           ;
wire         tpg_data_valid     ;
wire  [15:0] tpg_data_udp_length;

//temac signals
wire        tx_stop;
wire [7:0]  tx_ifg_val;
wire        pause_req;
wire [15:0] pause_val;
wire [47:0] pause_source_addr;
wire [47:0] unicast_address;
wire [19:0] mac_cfg_vector;  

wire        temac_tx_ready;
wire        temac_tx_valid;
wire [7:0]  temac_tx_data; 
wire        temac_tx_sof;
wire        temac_tx_eof;
            
wire        temac_rx_ready;
wire        temac_rx_valid;
wire [7:0]  temac_rx_data; 
wire        temac_rx_sof;
wire        temac_rx_eof;

wire        rx_correct_frame;//synthesis keep
wire        rx_error_frame;//synthesis keep
wire [1:0]  TRI_speed;

assign TRI_speed = 2'b10;//千兆2'b10 百兆2'b01 十兆2'b00

wire        rx_clk_int; 
wire        rx_clk_en_int;
wire        tx_clk_int; 
wire        tx_clk_en_int;

wire        temac_clk;//synthesis keep
wire        udp_clk;  //synthesis keep
wire        temac_clk90;
wire        clk_125_out;
wire        clk_12_5_out;
wire        clk_1_25_out;
wire        rx_valid;  //synthesis keep
wire [7:0]  rx_data;   //synthesis keep 
wire [7:0]  tx_data;    
wire        tx_valid;   
wire        tx_rdy;         
wire        tx_collision;   
wire        tx_retransmit;

wire        reset,reset_reg;
wire        clk_25_out;
reg [7:0]   phy_reset_cnt='d0;
reg [7:0]   soft_reset_cnt=8'hff;

always @(posedge clk_25_out or negedge rst_key)
begin
    if(~rst_key)
        phy_reset_cnt<='d0;
    else if(phy_reset_cnt < 255)
        phy_reset_cnt<= phy_reset_cnt+1;
    else
        phy_reset_cnt<=phy_reset_cnt;
end

assign  reset = ~rst_key || reset_reg || (soft_reset_cnt != 'd0);
assign  phy_reset = phy_reset_cnt[7];
wire abcdsfg ;//synthesis keep = 1
assign abcdsfg = 1;

always @(posedge udp_clk or negedge rst_key)
begin
    if(~rst_key)
        soft_reset_cnt<=8'hff;
    else if(soft_reset_cnt > 0)
        soft_reset_cnt<= soft_reset_cnt-1;
    else
        soft_reset_cnt<=soft_reset_cnt;
end

//============================================================
// 参数配置逻辑
//============================================================
//需配置的客户端接口（初始默认值）
assign  tx_stop    = 1'b0;
assign  tx_ifg_val = 8'h00;
assign  pause_req  = 1'b0;
assign  pause_val  = 16'h0;
assign  pause_source_addr = 48'h5af1f2f3f4f5;
// assign  unicast_address   = 48'hab8967452301;
assign  unicast_address   = {   LOCAL_MAC_ADDRESS[7:0],
                                LOCAL_MAC_ADDRESS[15:8],
                                LOCAL_MAC_ADDRESS[23:16],
                                LOCAL_MAC_ADDRESS[31:24],
                                LOCAL_MAC_ADDRESS[39:32],
                                LOCAL_MAC_ADDRESS[47:40]
                            };


assign  mac_cfg_vector    = {1'b0,2'b00,TRI_speed,8'b00000010,7'b0000010}; //地址过滤模式、流控配置、速度配置、接收器配置、发送器配置

//
//----------------------------------------------------------------
//乒乓开关选择模块
wire [3:0] state_stable;
reg [3:0] state=4'b0;
reg [12:0] m_stable_cnt;

assign state_stable=state_key;
//50us防抖
always@(posedge clk_50 or posedge reset)
begin
    if(reset)
    begin
        m_stable_cnt<=13'b0;
        state<=4'b0;
    end
    
    else
    begin
        if(state_stable!=state)
        begin
            m_stable_cnt<=m_stable_cnt+1'b1;
            if(m_stable_cnt==13'd5000)
            begin
                state<=state_stable;
                m_stable_cnt<=13'b0;
            end
        end
        else
        begin
            m_stable_cnt<=13'b0;
        end
    end
end

//state[3]==1'0:收状态；state[3]=1'b1:发状态
//state[3:2]=2'b00:收udp控制led;state[3:2]=2'b01:收udp显示bmp
//state[3:2]=2'b10:发摄像头数据 ;state[3:2]=2'b11:发tf卡数据
//state[1:0]用于控制图片处理功能，想使用这些功能请先处于state[3:2]=2'b10
//state[1]火焰检测;state[0]闯入检测;高有效
//根据状态进行连线

reg rx_led_valid_50;
reg rx_bmp_valid_50;

reg state_udp_tx_50;
wire state_udp_tx;
always @(posedge clk_50 or posedge reset) 
begin
    if(reset) begin
        state_udp_tx_50<=1'b0;
        rx_led_valid_50<=1'b0;
        rx_bmp_valid_50<=1'b0;
    end
    else if(state[3]==1'b1) begin
        state_udp_tx_50<=1'b1;
        rx_led_valid_50<=1'b0;
        rx_bmp_valid_50<=1'b0;
    end
    else begin
        state_udp_tx_50<=1'b0;
        rx_led_valid_50<=~state[2];
        rx_bmp_valid_50<=state[2];
    end
end

//收发ip转换
reg [31:0]  input_local_ip_address;
always @(posedge udp_clk or posedge reset) 
begin
    if(reset) 
        input_local_ip_address = 32'hc0a8f001;
    else
    begin
    if (state_udp_tx== 1'b1)
        input_local_ip_address = LOCAL_IP_ADDRESS;
    else
        input_local_ip_address = 32'hc0a8f001;
    end
end
//wire [31:0]  input_local_ip_address;
//assign input_local_ip_address = LOCAL_IP_ADDRESS;


//assign rx_led_valid=app_rx_data_valid&(state[3:2]==2'b00);
//assign rx_bmp_valid=app_rx_data_valid&(state[3:2]==2'b01);

//sdram输入数据的多路选择
wire frame_read_write_write_clk;
wire frame_read_write_write_req;
wire frame_read_write_write_req_ack;
wire frame_read_write_write_en;
wire[31:0] frame_read_write_write_data;

//udp发送数据的多路选择
wire [23:0] selected_video_data;//synthesis keep
wire        selected_hs;//synthesis keep
wire        selected_vs;//synthesis keep
wire        selected_de;//synthesis keep


//把state信息由clk50时钟域转换到udp_clk时钟域
reg frame_read_write_write_selection_50;
reg        fire_en_50,  intr_en_50;    
always @(posedge clk_50 or posedge reset) begin
    if (reset) begin
        fire_en_50 <= 1'b0;
        intr_en_50 <= 1'b0;
        frame_read_write_write_selection_50<=1'b0;
    end
    else if (state[3:2] == 2'b10) begin
        fire_en_50 <= state[1];
        intr_en_50 <= state[0];
        frame_read_write_write_selection_50<=1'b1;
    end
    else begin
        fire_en_50 <= 1'b0;
        intr_en_50 <= 1'b0;
        frame_read_write_write_selection_50<=1'b0;
    end
end

reg rx_led_valid_r1 , rx_led_valid_r2;
reg rx_bmp_valid_r1 , rx_bmp_valid_r2;

reg state_udp_tx_r1 , state_udp_tx_r2;
reg frame_read_write_write_selection_r1 , frame_read_write_write_selection_r2;
reg [1:0] en_udp_r1, en_udp_r2;   // 两级同步
always @(posedge udp_clk or posedge reset) begin
    if (reset) begin
        en_udp_r1 <= 2'b0;
        en_udp_r2 <= 2'b0;
        
        frame_read_write_write_selection_r1<=1'b0;
        frame_read_write_write_selection_r2<=1'b0;
        
        state_udp_tx_r1<=1'b0;
        state_udp_tx_r2<=1'b0;
        
        rx_led_valid_r1<=1'b0;
        rx_led_valid_r2<=1'b0;
        rx_bmp_valid_r1<=1'b0;
        rx_bmp_valid_r2<=1'b0;
    end
    else begin
        rx_led_valid_r1<=rx_led_valid_50;
        rx_led_valid_r2<=rx_led_valid_r1;
        rx_bmp_valid_r1<=rx_bmp_valid_50;
        rx_bmp_valid_r2<=rx_bmp_valid_r1;
    
        state_udp_tx_r1<=state_udp_tx_50;
        state_udp_tx_r2<=state_udp_tx_r1;
    
        frame_read_write_write_selection_r1<=frame_read_write_write_selection_50;
        frame_read_write_write_selection_r2<=frame_read_write_write_selection_r1;
    
        en_udp_r1 <= {fire_en_50, intr_en_50};  // 打第一拍
        en_udp_r2 <= en_udp_r1;                 // 打第二拍
    end
end

wire fire_detect_en   = en_udp_r2[1];
wire intrusion_detect_en = en_udp_r2[0];
wire frame_read_write_write_selection=frame_read_write_write_selection_r2;
assign state_udp_tx=state_udp_tx_r2;

//udp接收数据的多路选择
wire rx_led_valid=app_rx_data_valid&rx_led_valid_r2;
wire rx_bmp_valid=app_rx_data_valid&rx_bmp_valid_r2;

//-----------------------------------------------------

//-----------------------------------------------------
//led模块

led u0_led(
       .udp_rx_clk                 (udp_clk                ),
       .reset                      (rst_key                  ), 
       .app_rx_data_valid          (rx_led_valid              ), 
       .app_rx_data                (app_rx_data            ), 
       .app_rx_data_length         (app_rx_data_length     ) ,
       .dled                       (dled)       ,
       .led_data_1                 (led_data)
 );
//-----------------------------------------------------

//-----------------------------------------------------
//udp_to_hdmi图片显示模块
wire pixel_clk_5x;
wire pixel_clk;
clk_wize u0_clk_wize (
  .refclk(clk_50),
  .reset(1'b0),
  .clk0_out(pixel_clk_5x),
  .clk1_out(pixel_clk   )
);

wire VGA_EN;
wire  dis_en;
wire [11:0] VGA_D;
// // app
app u1_app (
    .sys_clk                    (pixel_clk                ),
    .udp_rx_clk                 (udp_clk                ),
    .udp_tx_clk                 (udp_clk                ),
    .reset                      (rst_key                  ), 
    .app_rx_data_valid          (rx_bmp_valid           ), 
    .app_rx_data                (app_rx_data            ), 
    .app_rx_data_length         (app_rx_data_length     ), 
    .app_rx_port_num            (app_rx_port_num        ),
    .VGA_HSYNC	                (VGA_HSYNC              ),
	.VGA_VSYNC 	                (VGA_VSYNC              ),
	.VGA_D                      (VGA_D                  ),
    .rd_en                      (rd_en                  ),
    .VGA_EN                     (VGA_EN)
);      

    	wire [7:0]	VGA_R;
		wire [7:0]	VGA_G;
		wire [7:0]	VGA_B;

assign VGA_R = {VGA_D[11:8],4'b0};	
assign VGA_G = {VGA_D[7:4],4'b0};
assign VGA_B = {VGA_D[3:0],4'b0};
hdmi_tx #(.FAMILY("EG4"))	//EF2、EF3、EG4、AL3、PH1

 u2_hdmi_tx
	(
		.PXLCLK_I(pixel_clk),
		.PXLCLK_5X_I(pixel_clk_5x),

		.RST_N (rst_key),
		
		//VGA
		.VGA_HS (VGA_HSYNC ),
		.VGA_VS (VGA_VSYNC ),
		.VGA_DE (VGA_EN ),
		.VGA_RGB({VGA_R,VGA_G,VGA_B}),

		//HDMI
		.HDMI_CLK_P(HDMI_CLK_P),
		.HDMI_D2_P (HDMI_D2_P ),
		.HDMI_D1_P (HDMI_D1_P ),
		.HDMI_D0_P (HDMI_D0_P )	
		
	);

//-----------------------------------------------------
wire                            sd_card_clk;       //SD card controller clock
wire                            ext_mem_clk;       //external memory clock
wire                            ext_mem_clk_sft;
sys_pll tf0_sys_pll(
	.refclk                     (clk_50),
	.clk0_out                   (sd_card_clk),
	.clk1_out                   (ext_mem_clk),
    .clk2_out					(ext_mem_clk_sft),
    .reset						(1'b0)
    );
//-----------------------------------------------------
//tf卡读取模块
wire rst_n;
assign  rst_n =rst_key;

wire                            sd_card_write_en;
wire[31:0]                      sd_card_write_data;
wire                            sd_card_write_req;
wire                            sd_card_write_req_ack;

wire[3:0]                       state_code;
//SD card BMP file read
sd_card_bmp  sd_card_bmp_m0(
	.clk                        (sd_card_clk              ),
	.rst                        (~rst_n ),
	.key                        (sd_bmp_find              ),
	.state_code                 (state_code               ),
	.bmp_width                  (16'd640                 	),  //image width
	.write_req                  (sd_card_write_req        ),
	.write_req_ack              (sd_card_write_req_ack    ),
	.write_en                   (sd_card_write_en         ),
	.write_data                 (sd_card_write_data       ),
	.SD_nCS                     (sd_cs                    ),
	.SD_DCLK                    (sd_clk                  ),
	.SD_MOSI                    (sd_mosi                  ),
	.SD_MISO                    (sd_miso                  )
);
//-----------------------------------------------------

//-----------------------------------------------------
//ov5640摄像头模块
wire cmos_frame_vsync;
wire cmos_frame_href;
wire cmos_frame_valid;
wire [15:0] cmos_wr_data;

wire Sdr_init_done;
//ov5640 驱动
ov5640_dri u_ov5640_dri(
    .clk               (clk_50),
    .rst_n             (rst_n),

    .cam_pclk          (cam_pclk ),
    .cam_vsync         (cam_vsync),
    .cam_href          (cam_href ),
    .cam_data          (cam_data ),
    .cam_rst_n         (cam_rst_n),
    .cam_pwdn          (cam_pwdn ),
    .cam_scl           (cam_scl  ),
    .cam_sda           (cam_sda  ),
    
    .capture_start     (Sdr_init_done),
    .cmos_h_pixel      (H_CMOS_DISP),
    .cmos_v_pixel      (V_CMOS_DISP),
    .total_h_pixel     (TOTAL_H_PIXEL),
    .total_v_pixel     (TOTAL_V_PIXEL),
    .cmos_frame_vsync  (cmos_frame_vsync),
    .cmos_frame_href   (cmos_frame_href),
    .cmos_frame_valid  (cmos_frame_valid),
    .cmos_frame_data   (cmos_wr_data)
    );  

wire                            cam_write_en;
wire[31:0]                      cam_write_data;
wire                            cam_write_req;
wire                            cam_write_req_ack;

ov5640_delay u_ov5640_delay(
    .clk               (cam_pclk),
    .rst_n             (rst_n),
    .cmos_frame_vsync  (cmos_frame_vsync),
    .cmos_frame_href   (cmos_frame_href),
    .cmos_frame_valid  (cmos_frame_valid),
    .cmos_wr_data   (cmos_wr_data),
    
    .cam_write_req(cam_write_req),
    .cam_write_req_ack(cam_write_req_ack),
    .cam_write_en(cam_write_en),
    .cam_write_data(cam_write_data)
);
//-----------------------------------------------------

//-----------------------------------------------------
//sdr和frame_fifo

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS - 1 : 0]Sdr_rd_dout;

wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS - 1 : 0]App_wr_din;
wire [3:0] App_wr_dm;

//wire Sdr_init_done;//定义前移，防出错
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire                            video_read_req;//synthesis keep
wire                            video_read_req_ack;//synthesis keep
wire                            video_read_en;
wire[31:0]                      video_read_data;


//sdram输入数据的多路选择
assign frame_read_write_write_clk= (frame_read_write_write_selection) ? cam_pclk      : sd_card_clk ;
assign frame_read_write_write_req= (frame_read_write_write_selection) ? cam_write_req : sd_card_write_req ;
assign frame_read_write_write_en=  (frame_read_write_write_selection) ? cam_write_en  : sd_card_write_en ;
assign frame_read_write_write_data=(frame_read_write_write_selection) ? cam_write_data: sd_card_write_data ;

assign cam_write_req_ack    =(frame_read_write_write_selection) ? frame_read_write_write_req_ack : 1'b0;
assign sd_card_write_req_ack=(frame_read_write_write_selection) ? 1'b0 : frame_read_write_write_req_ack;


frame_read_write frame_read_write_m0(
    .mem_clk					(ext_mem_clk),
    .rst						(~rst_n),
    .Sdr_init_done				(Sdr_init_done),
    .Sdr_init_ref_vld			(Sdr_init_ref_vld),
    .Sdr_busy					(Sdr_busy),
    
    .App_rd_en					(App_rd_en),
    .App_rd_addr				(App_rd_addr),
    .Sdr_rd_en					(Sdr_rd_en),
    .Sdr_rd_dout				(Sdr_rd_dout),
    
    .read_clk                   (udp_clk           ),
	.read_req                   (video_read_req           ),
	.read_req_ack               (video_read_req_ack       ),
	.read_finish                (                   ),
	.read_addr_0                (24'd0              ), //first frame base address is 0
	.read_addr_1                (24'd0              ),
	.read_addr_2                (24'd0              ),
	.read_addr_3                (24'd0              ),
	.read_addr_index            (2'd0               ), //use only read_addr_0
	.read_len                   (24'd307200         ), //frame size//24'd786432
	.read_en                    (video_read_en            ),
	.read_data                  (video_read_data          ),
    
    .App_wr_en					(App_wr_en),
    .App_wr_addr				(App_wr_addr),
    .App_wr_din					(App_wr_din),
    .App_wr_dm					(App_wr_dm),
    
    .write_clk                  (frame_read_write_write_clk       ),
	.write_req                  (frame_read_write_write_req        ),
	.write_req_ack              (frame_read_write_write_req_ack    ),
	.write_finish               (                 ),
	.write_addr_0               (24'd0            ),
	.write_addr_1               (24'd0            ),
	.write_addr_2               (24'd0            ),
	.write_addr_3               (24'd0            ),
	.write_addr_index           (2'd0             ), //use only write_addr_0
	.write_len                  (24'd307200       ), //frame size
	.write_en                   (frame_read_write_write_en         ),
	.write_data                 (frame_read_write_write_data       )
);

sdram U3
(
.Clk				(ext_mem_clk),
.Clk_sft			(ext_mem_clk_sft),
.Rst				(~(rst_n)),
    
.Sdr_init_done		(Sdr_init_done),
.Sdr_init_ref_vld	(Sdr_init_ref_vld),
.Sdr_busy			(Sdr_busy),
    
.App_wr_en			(App_wr_en),
.App_wr_addr		(App_wr_addr),  	
.App_wr_dm			(App_wr_dm),
.App_wr_din			(App_wr_din),
    
.App_rd_en			(App_rd_en),//data_req
.App_rd_addr		(App_rd_addr),
.Sdr_rd_en			(Sdr_rd_en),//data_valid
.Sdr_rd_dout		(Sdr_rd_dout)
);
//-----------------------------------------------------

//-----------------------------------------------------
//udp发送时读fifo的时序控制
wire  [11:0] udp_wrusedw;//synthesis keep
wire m_udp_wrusedw;
assign m_udp_wrusedw=((!state_udp_tx)||(udp_wrusedw>=12'd2000));//触发门限低于2048,因为计数器到m_video_en有数十拍延时

wire hs_0;
wire vs_0;
wire de_0;
video_timing_data video_timing_data_m0
(
	.video_clk                  (udp_clk                ),
	.rst                        (~rst_n    ),
	.read_req                   (video_read_req           ),
	.read_req_ack               (video_read_req_ack       ),
	//.read_en                    (video_read_en            ),
	//.read_data                  (video_read_data          ),
	.hs                         (hs_0                       ),
	.vs                         (vs_0                       ),
	.de                         (de_0                         ),
	//.vout_data                  (vout_data                )
    .m_udp_wrusedw              (m_udp_wrusedw              )
);

wire[23:0]                      vout_data;//synthesis keep
wire hs;//synthesis keep
wire vs;//synthesis keep
wire de;//synthesis keep


video_delay video_delay_m0
(
    .video_clk                  (udp_clk                ),
	.rst                        (~rst_n    ),
    .read_en					(video_read_en),
    .read_data					(video_read_data[31:8]),
    .hs                         (hs_0                       ),
	.vs                         (vs_0                       ),
	.de                         (de_0                         ),
    
	.hs_r                       (hs                       ),
	.vs_r                       (vs                       ),
	.de_r                       (de                       ),
	.vout_data					(vout_data)
);
//----------------------------------------------------

//----------------------------------------------------
//两个视频实时检测功能模块

wire fire_detected;//synthesis keep
// fire_detect模块的视频输出信号
wire [23:0] fire_video_out;//synthesis keep
wire        fire_hs_out;//synthesis keep
wire        fire_vs_out;//synthesis keep
wire        fire_de_out;//synthesis keep

wire intrusion_detected;//synthesis keep
// intrusion_detect模块的视频输出信号
wire [23:0] intrusion_video_out;//synthesis keep
wire        intrusion_hs_out;//synthesis keep
wire        intrusion_vs_out;//synthesis keep
wire        intrusion_de_out;//synthesis keep


//判断是否有火焰触发
reg finded_fire;
always @(posedge udp_clk or posedge reset) begin
    if (reset) begin
        finded_fire <= 1'b0;
    end
    else if(fire_detect_en&&fire_detected) begin
        finded_fire <= 1'b1;
    end
    else if(!fire_detect_en) begin
        finded_fire <= 1'b0;
    end
    else begin
        finded_fire <= finded_fire;
    end
end

//判断是否有闯入触发
reg finded_intrusion;
always @(posedge udp_clk or posedge reset) begin
    if (reset) begin
        finded_intrusion <= 1'b0;
    end
    else if(intrusion_detect_en&&intrusion_detected) begin
        finded_intrusion <= 1'b1;
    end
    else if(!fire_detect_en) begin
        finded_intrusion <= 1'b0;
    end
    else begin
        finded_intrusion <= finded_intrusion;
    end
end
//assign buzzer=~finded_intrusion;

assign selected_video_data = intrusion_detect_en ? intrusion_video_out : 
                             (fire_detect_en ? fire_video_out : vout_data);
                             
assign selected_hs = intrusion_detect_en ? intrusion_hs_out : 
                     (fire_detect_en ? fire_hs_out : hs);
assign selected_vs = intrusion_detect_en ? intrusion_vs_out : 
                     (fire_detect_en ? fire_vs_out : vs);
assign selected_de = intrusion_detect_en ? intrusion_de_out : 
                     (fire_detect_en ? fire_de_out : de);


            
fire_detect m_fire_detect
(
    .video_clk                  (udp_clk),
    .rst                        (~rst_n),
    .read_data                  (vout_data),
    .hs                         (hs),
    .vs                         (vs),
    .de                         (de),
    .res                        (fire_detected),
    // 新增视频输出接口
    .video_out                  (fire_video_out),
    .hs_out                     (fire_hs_out),
    .vs_out                     (fire_vs_out),
    .de_out                     (fire_de_out)
);

intrusion_detect m_intrusion_detect
(
    .video_clk                  (udp_clk),
    .rst                        (~rst_n),
    .read_data                  (vout_data),
    .hs                         (hs),
    .vs                         (vs),
    .de                         (de),
    .bg_capture                 (key_bg_capture),
    .res                        (intrusion_detected),
    // 视频输出接口
    .video_out                  (intrusion_video_out),
    .hs_out                     (intrusion_hs_out),
    .vs_out                     (intrusion_vs_out),
    .de_out                     (intrusion_de_out)
);


//----------------------------------------------------

//----------------------------------------------------
//分频驱动蜂鸣器，提示闯入
reg [14:0] buzz_cnt;
reg buzz_clk;
always @(posedge clk_50 or posedge reset) begin
    if (reset) begin
        buzz_cnt <= 15'd0;
        buzz_clk <=1'd0;
    end
    else if(buzz_cnt>15'd24999) begin
        buzz_cnt<=15'd0;
        buzz_clk <=~buzz_clk;
    end
    else begin
        buzz_cnt <=buzz_cnt+15'd1;
    end
end

assign buzzer=(buzz_clk||(!finded_intrusion));
//----------------------------------------------------

//----------------------------------------------------
//定位信号添加模块
wire [23:0] image_data;//synthesis keep
wire image_data_en;

wire        m_video_en;//synthesis keep

m_synchronization_header m_video_to_udp
(
    .video_clk                  (udp_clk                ),
	.rst                        (~rst_n    ),
    
    .read_data                  (selected_video_data),
    .hs                         (selected_hs),
    .vs                         (selected_vs),
    .de                         (selected_de),
    
    .video_data                  (image_data),
    .video_data_en               (image_data_en)
);

assign m_video_en=fire_detect_en ? (image_data_en&&finded_fire): image_data_en ;

//-----------------------------------------------------


//-----------------------------------------------------
//udp模块
clk_gen_rst_gen#(
    .DEVICE         (DEVICE     )
)u_clk_gen(
    .reset                (~rst_key         ),//~key1 
    .clk_in         (clk_50     ),
    .rst_out        (reset_reg  ),
    .clk_125_out0   (temac_clk  ),
    .clk_125_out1   (clk_125_out),
    .clk_125_out2   (temac_clk90),
    .clk_12_5_out   (clk_12_5_out),
    .clk_1_25_out   (clk_1_25_out),
    .clk_25_out     (clk_25_out )
);


udp_data_tpg u1_udp_data_tpg(
    .clk                (udp_clk            ),
    .reset              (~rst_key           ),

    .tpg_data           (tpg_data           ),//数据输出
    .tpg_data_valid     (tpg_data_valid     ),//数据有效信号
    .tpg_data_udp_length(tpg_data_udp_length),//数据长度（包含帧头）
    .tpg_data_done      (tpg_data_done      ),
    
    .tpg_data_enable    (phy_reset          ),
    .tpg_data_header0   (16'haabb           ),//帧头0
    .tpg_data_header1   (16'hccdd           ),//帧头1
    .tpg_data_type      (16'ha8b8           ),//数据帧类垿
    .tpg_data_length    (16'h00ff           ),//数据长度500
    .tpg_data_num       (16'h000a           ),//产生的帧个数10
    .tpg_data_ifg       (8'd130             )
);

// assign image_data = (Sdr_rd_dout[23:16] * 76 +Sdr_rd_dout[23:16] * 150 +Sdr_rd_dout[7:0] * 30 ) >>8;

//------------------------------------------------------------
//udp_loopback
//------------------------------------------------------------
udp_loopback#(
    .DEVICE(DEVICE)
)
 u2_udp_loopback
 (
    .app_rx_clk                 (udp_clk                ),
    .app_tx_clk                 (udp_clk                ),
    .reset                      (reset                ),//reset
    .udp_wrusedw                   (udp_wrusedw),
    `ifdef UDP_LOOP_BACK    
    .app_rx_data                (image_data        ),
    .app_rx_data_valid          (m_video_en       ),
    .app_rx_data_length         (16'd969    ),//在我们的设计下必须为3的倍数，969为半行960+定位3
    `else   
    .app_rx_data                (tpg_data               ),
    .app_rx_data_valid          (tpg_data_valid         ),
    .app_rx_data_length         (tpg_data_udp_length    ),
    `endif              
    .full_flag                  (full_flag),
    .udp_tx_ready               (udp_tx_ready           ),
    .app_tx_ack                 (app_tx_ack             ),
    .app_tx_data                (app_tx_data            ),
    .app_tx_data_request        (app_tx_data_request    ),
    .app_tx_data_valid          (app_tx_data_valid      ),
    .udp_data_length            (udp_data_length        )   
);

    
udp_ip_protocol_stack #
(
    .DEVICE                     (DEVICE                 ),
    .LOCAL_UDP_PORT_NUM         (LOCAL_UDP_PORT_NUM     ),
    .LOCAL_IP_ADDRESS           (LOCAL_IP_ADDRESS       ),
    .LOCAL_MAC_ADDRESS          (LOCAL_MAC_ADDRESS      )
)   
u3_udp_ip_protocol_stack    
(   
    .udp_rx_clk                 (udp_clk                ),
    .udp_tx_clk                 (udp_clk                ),
    .reset                      (reset                 ), 
    .udp2app_tx_ready           (udp_tx_ready           ), 
    .udp2app_tx_ack             (app_tx_ack             ), 
    .app_tx_request             (app_tx_data_request    ), 
    .app_tx_data_valid          (app_tx_data_valid      ), 
    .app_tx_data                (app_tx_data            ), 
    .app_tx_data_length         (udp_data_length        ), 
    .app_tx_dst_port            (DST_UDP_PORT_NUM       ), 
    .ip_tx_dst_address          (DST_IP_ADDRESS         ), 
    
    .input_local_udp_port_num      (input_local_udp_port_num      ),
    .input_local_udp_port_num_valid(input_local_udp_port_num_valid),
    
    .input_local_ip_address     (input_local_ip_address     ),
    .input_local_ip_address_valid(input_local_ip_address_valid),
    
    .app_rx_data_valid          (app_rx_data_valid      ), 
    .app_rx_data                (app_rx_data            ), 
    .app_rx_data_length         (app_rx_data_length     ), 
    .app_rx_port_num            (app_rx_port_num        ), 
    .temac_rx_ready             (temac_rx_ready         ),//output
    .temac_rx_valid             (!temac_rx_valid        ),//input
    .temac_rx_data              (temac_rx_data          ),//input
    .temac_rx_sof               (temac_rx_sof           ),//input
    .temac_rx_eof               (temac_rx_eof           ),//input
    .temac_tx_ready             (temac_tx_ready         ),//input
    .temac_tx_valid             (temac_tx_valid         ),//output
    .temac_tx_data              (temac_tx_data          ),//output
    .temac_tx_sof               (temac_tx_sof           ),//output
    .temac_tx_eof               (temac_tx_eof           ),//output
`ifdef DEBUG_UDP
    .udp_debug_out              (udp_debug_out          ),
`endif
    .ip_rx_error                (                       ), 
    .arp_request_no_reply_error (                       )
);
wire phy1_rgmii_rx_clk_0;
wire phy1_rgmii_rx_clk_90;

//rx_pll u_rx_pll(
//	.refclk		(phy1_rgmii_rx_clk),
//    .reset       (1'b0),
//    .clk0_out	(phy1_rgmii_rx_clk_0),
//	.clk1_out	(phy1_rgmii_rx_clk_90)
//);
//------------------------------------------------------------  
//TEMAC
//------------------------------------------------------------  
temac_block#(
    .DEVICE               (DEVICE                   )
)  
u4_trimac_block
(
    .reset                (reset                   ),
    .gtx_clk              (clk_125_out                ),//input   125M
    .gtx_clk_90           (temac_clk90                ),//input   125M
    .rx_clk               (rx_clk_int               ),//output  125M 25M    2.5M
    .rx_clk_en            (rx_clk_en_int            ),//output  1    12.5M  1.25M
    .rx_data              (rx_data                  ),
    .rx_data_valid        (rx_valid                 ),
    .rx_correct_frame     (rx_correct_frame         ),
    .rx_error_frame       (rx_error_frame           ),
    .rx_status_vector     (                         ),
    .rx_status_vld        (                         ),
//  .tri_speed            (tri_speed                ),//output
    .tx_clk               (tx_clk_int               ),//output  125M
    .tx_clk_en            (tx_clk_en_int            ),//output  1    12.5M  1.25M 占空比不对
    .tx_data              (tx_data                  ),
    .tx_data_en           (tx_valid                 ),
    .tx_rdy               (tx_rdy                   ),//temac_tx_ready
    .tx_stop              (tx_stop                  ),//input
    .tx_collision         (tx_collision             ),
    .tx_retransmit        (tx_retransmit            ),
    .tx_ifg_val           (tx_ifg_val               ),//input
    .tx_status_vector     (                         ),
    .tx_status_vld        (                         ),
    .pause_req            (pause_req                ),//input
    .pause_val            (pause_val                ),//input
    .pause_source_addr    (pause_source_addr        ),//input
    .unicast_address      (unicast_address          ),//input
    .mac_cfg_vector       (mac_cfg_vector           ),//input
    .rgmii_txd            (phy1_rgmii_tx_data       ),
    .rgmii_tx_ctl         (phy1_rgmii_tx_ctl        ),
    .rgmii_txc            (phy1_rgmii_tx_clk        ),
    .rgmii_rxd            (phy1_rgmii_rx_data       ),
    .rgmii_rx_ctl         (phy1_rgmii_rx_ctl        ),
    .rgmii_rxc            (phy1_rgmii_rx_clk        ),
    .inband_link_status   (                         ),
    .inband_clock_speed   (                         ),
    .inband_duplex_status (                         )
);

udp_clk_gen#(
    .DEVICE               (DEVICE                   )
)           
u5_temac_clk_gen(           
    .reset                (~rst_key                 ),//~key1 
    .tri_speed            (TRI_speed                ),
    .clk_125_in           (clk_125_out              ),//125M  
    .clk_12_5_in          (clk_12_5_out             ),//12.5M 
    .clk_1_25_in          (clk_1_25_out             ),//1.25M 
    .udp_clk_out          (udp_clk                  )
);

tx_client_fifo #
(
    .DEVICE               (DEVICE                   )
)
u6_tx_fifo
(
    .rd_clk               (tx_clk_int               ),
    .rd_sreset            (reset                   ),
    .rd_enable            (tx_clk_en_int            ),
    .tx_data              (tx_data                  ),
    .tx_data_valid        (tx_valid                 ),
    .tx_ack               (tx_rdy                   ),
    .tx_collision         (tx_collision             ),
    .tx_retransmit        (tx_retransmit            ),
    .overflow             (                         ),
                            
    .wr_clk               (udp_clk                  ),
    .wr_sreset            (reset                   ),
    .wr_data              (temac_tx_data            ),
    .wr_sof_n             (temac_tx_sof             ),
    .wr_eof_n             (temac_tx_eof             ),
    .wr_src_rdy_n         (temac_tx_valid           ),
    .wr_dst_rdy_n         (temac_tx_ready           ),//temac_tx_ready
    .wr_fifo_status       (                         )
);

rx_client_fifo# 
(
    .DEVICE               (DEVICE                   )
)                           
u7_rx_fifo                  
(                           
    .wr_clk               (rx_clk_int               ),
    .wr_enable            (rx_clk_en_int            ),
    .wr_sreset            (reset                    ),
    .rx_data              (rx_data                  ),
    .rx_data_valid        (rx_valid                 ),
    .rx_good_frame        (rx_correct_frame         ),
    .rx_bad_frame         (rx_error_frame           ),
    .overflow             (                         ),
    .rd_clk               (udp_clk                  ),
    .rd_sreset            (reset                   ),
    .rd_data_out          (temac_rx_data            ),//output reg [7:0] rd_data_out,
    .rd_sof_n             (temac_rx_sof             ),//output reg       rd_sof_n,
    .rd_eof_n             (temac_rx_eof             ),//output           rd_eof_n,
    .rd_src_rdy_n         (temac_rx_valid           ),//output reg       rd_src_rdy_n,
    .rd_dst_rdy_n         (temac_rx_ready           ),//input            rd_dst_rdy_n,
    .rx_fifo_status       (                         )
);


endmodule

