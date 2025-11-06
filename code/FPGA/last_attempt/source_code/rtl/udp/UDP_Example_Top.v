`timescale 1ns / 1ps
//********************************************************************** 
// -------------------------------------------------------------------
// >>>>>>>>>>>>>>>>>>>>>>>Copyright Notice<<<<<<<<<<<<<<<<<<<<<<<<<<<< 
// ------------------------------------------------------------------- 
//             /\ --------------- 
//            /  \ ------------- 
//           / /\ \ -----------
//          / /  \ \ ---------
//         / /    \ \ ------- 
//        / /      \ \ ----- `
//       / /_ _ _   \ \ --- 
//      /_ _ _ _ _\  \_\ -
//*********************************************************************** 
// Author: suluyang 
// Email:luyang.su@anlogic.com 
// Date:2020/11/17 
// Description: 
// 2022/03/10:  修改时钟结构
//              简化约束
//              添加 soft fifo 
//              添加 debug 功能
// 2023/02/16 :add dynamic_local_ip_address port
// 
// web：www.anlogic.com 
//------------------------------------------------------------------- 
//*********************************************************************/
    `define UDP_LOOP_BACK
    

//  `define DEBUG_UDP
module UDP_Example_Top(
      input  clk_50, 
      input  sys_rst_n,
      input  sd_reset_rd,
      input  key_frame,
      input  sd_miso , 
      output sd_clk  , 
      output sd_cs   , 
      output sd_mosi ,   
      input               phy1_rgmii_rx_clk,
      input               phy1_rgmii_rx_ctl,
      input [3:0]         phy1_rgmii_rx_data,
      output wire         phy1_rgmii_tx_clk,
      output wire         phy1_rgmii_tx_ctl,
      output wire [3:0]   phy1_rgmii_tx_data,     
      output [2:0]        led
);
parameter  DEVICE             = "EG4";//"PH1","EG4"
parameter  LOCAL_UDP_PORT_NUM = 16'h0001;       
parameter  LOCAL_IP_ADDRESS   = 32'hc0a8f001;       
parameter  LOCAL_MAC_ADDRESS  = 48'h0123456789ab;
parameter  DST_UDP_PORT_NUM   = 16'h0002;       
parameter  DST_IP_ADDRESS     = 32'hc0a8f002;

parameter MEM_DATA_BITS         = 32  ;            //external memory user interface data width
parameter ADDR_BITS             = 21  ;            //external memory user interface address width
parameter BUSRT_BITS            = 10  ;            //external memory user interface burst width
/*------------------------------*/
/*------------------------------*/
wire               key1 = sys_rst_n;
wire         app_rx_data_valid;//synthesis keep 
wire [7:0]   app_rx_data;//synthesis keep       
wire [15:0]  app_rx_data_length;//synthesis keep
wire [15:0]  app_rx_port_num;

wire         udp_tx_ready;//synthesis keep
wire         app_tx_ack;//synthesis keep
wire         app_tx_data_request;//synthesis keep
wire         app_tx_data_valid;//synthesis keep 
wire [7:0]   app_tx_data;//synthesis keep       
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

wire        temac_tx_ready;//synthesis keep
wire        temac_tx_valid;//synthesis keep
wire [7:0]  temac_tx_data;//synthesis keep 
wire        temac_tx_sof;
wire        temac_tx_eof;
            
wire        temac_rx_ready;
wire        temac_rx_valid;//synthesis keep
wire [7:0]  temac_rx_data;//synthesis keep 
wire        temac_rx_sof;
wire        temac_rx_eof;

wire        rx_correct_frame;
wire        rx_error_frame;
wire [1:0]  TRI_speed;

assign TRI_speed = 2'b10;//千兆2'b10 百兆2'b01 十兆2'b00

wire        rx_clk_int; 
wire        rx_clk_en_int;
wire        tx_clk_int; 
wire        tx_clk_en_int;

wire        temac_clk;//synthesis keep
wire        udp_clk;  //synthesis keep
wire        temac_clk90;//synthesis keep
wire        clk_125_out;
wire        clk_12_5_out;
wire        clk_1_25_out;
wire        rx_valid;//synthesis keep   
wire [7:0]  rx_data;//synthesis keep    
wire [7:0]  tx_data; //synthesis keep   
wire        tx_valid; //synthesis keep  
wire        tx_rdy;         
wire        tx_collision;   
wire        tx_retransmit;

wire        reset,reset_reg;
wire        clk_50_out;
reg [7:0]   phy_reset_cnt='d0;
reg [7:0]   soft_reset_cnt=8'hff;
reg sys_rst_n_1,sys_rst_n_2;
wire  key2;
assign key2 =sys_rst_n_2;
//wire locked;
//wire clk_50m ,clk_50m_180deg /* synthesis syn_keep=1 */;
assign  reset = ~key1 || reset_reg || (soft_reset_cnt != 'd0);

wire abcdsfg ;//synthesis keep = 1
assign abcdsfg = 1;


    always @(posedge clk_50 or negedge sys_rst_n)           
        begin                                        
            if(!sys_rst_n)  begin
sys_rst_n_1 <= 1'b0;
sys_rst_n_2 <= 1'b0;
            end                             
                                                   
            else begin
sys_rst_n_1 <= sys_rst_n;
sys_rst_n_2 <= sys_rst_n_1;
            end                                                                 
        end                                          
wire rst_n/* synthesis syn_keep=1 */;
assign  rst_n = sys_rst_n ;    

wire  [11:0] udp_wrusedw;//synthesis keep

//------------------------------------------------------------------
wire                            sd_card_clk;       //SD card controller clock
wire                            ext_mem_clk;       //external memory clock
wire                            ext_mem_clk_sft;
sys_pll sys_pll_m0(
	.refclk                     (clk_50),
	.clk0_out                   (sd_card_clk),
	.clk1_out                   (ext_mem_clk),
    .clk2_out					(ext_mem_clk_sft),
    .reset						(1'b0)
    );
    
wire                            sd_card_write_en;
wire[31:0]                      sd_card_write_data;
wire                            sd_card_write_req;
wire                            sd_card_write_req_ack;

wire[3:0]                       state_code;

//SD card BMP file read
sd_card_bmp  sd_card_bmp_m0(
	.clk                        (sd_card_clk              ),
	.rst                        (~rst_n ),
	.key                        (sd_reset_rd              ),
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

wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS - 1 : 0]Sdr_rd_dout;

wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS - 1 : 0]App_wr_din;
wire [3:0] App_wr_dm;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire                            video_read_req;//synthesis keep
wire                            video_read_req_ack;//synthesis keep
wire                            video_read_en;
wire[31:0]                      video_read_data;

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
    
    .write_clk                  (sd_card_clk        ),
	.write_req                  (sd_card_write_req        ),
	.write_req_ack              (sd_card_write_req_ack    ),
	.write_finish               (                 ),
	.write_addr_0               (24'd0            ),
	.write_addr_1               (24'd0            ),
	.write_addr_2               (24'd0            ),
	.write_addr_3               (24'd0            ),
	.write_addr_index           (2'd0             ), //use only write_addr_0
	.write_len                  (24'd307200       ), //frame size
	.write_en                   (sd_card_write_en         ),
	.write_data                 (sd_card_write_data       )
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

//wire [31:0]          m_video_data;

wire m_udp_wrusedw;
assign m_udp_wrusedw=(udp_wrusedw>=12'd2000);//触发门限低于2048,因为计数器到m_video_en有数十拍延时

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

wire [23:0] image_data;//synthesis keep
wire        m_video_en;//synthesis keep

m_synchronization_header video_to_udp
(
    .video_clk                  (udp_clk                ),
	.rst                        (~rst_n    ),
    
    .read_data                  (vout_data),
    .hs                         (hs),
    .vs                         (vs),
    .de                         (de),
    
    .video_data                  (image_data),
    .video_data_en               (m_video_en)
);


always @(posedge clk_50_out or negedge key1)
begin
    if(~key1)
        phy_reset_cnt<='d0;
    else if(phy_reset_cnt < 255)
        phy_reset_cnt<= phy_reset_cnt+1;
    else
        phy_reset_cnt<=phy_reset_cnt;
end

assign  reset = ~key1 || reset_reg || (soft_reset_cnt != 'd0);
assign  phy_reset = phy_reset_cnt[7];


always @(posedge udp_clk or negedge key1)
begin
    if(~key1)
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
//assign  mac_cfg_vector    = {1'b0,2'b00,2'b10,8'b00000010,7'b0000010}; //地址过滤模式、流控配置、速度配置、接收器配置、发送器配置
//assign  mac_cfg_vector    = {1'b0,2'b00,2'b01,8'b00000010,7'b0000010}; //地址过滤模式、流控配置、速度配置、接收器配置、发送器配置
//assign  mac_cfg_vector    = {1'b0,2'b00,2'b00,8'b00000010,7'b0000010}; //地址过滤模式、流控配置、速度配置、接收器配置、发送器配置



clk_gen_rst_gen#(
    .DEVICE         (DEVICE     )
)u_clk_gen(
    .reset                (~key1                ),//~key1 
    .clk_in         (clk_50     ),
    .rst_out        (reset_reg  ),
    .clk_125_out0   (temac_clk  ),
    .clk_125_out1   (clk_125_out),
    .clk_125_out2   (temac_clk90),
    .clk_12_5_out   (clk_12_5_out),
    .clk_1_25_out   (clk_1_25_out),
    .clk_25_out     (clk_50_out )
);


udp_data_tpg u1_udp_data_tpg(
    .clk                (udp_clk            ),
    .reset              (~key2              ),

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
    .reset                (~key1               ),//~key1 
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