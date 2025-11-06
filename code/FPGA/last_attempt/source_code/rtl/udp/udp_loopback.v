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
//        / /      \ \ ----- 
//       / /_ _ _   \ \ --- 
//      /_ _ _ _ _\  \_\ -
//*********************************************************************** 
// Author: suluyang 
// Email:luyang.su@anlogic.com 
// Date:2020/10/26 
// Description: 
// 
// web：www.anlogic.com 
//------------------------------------------------------------------- 
//*********************************************************************/
module udp_loopback(

input   wire		app_rx_clk		   ,
input   wire		app_tx_clk		   ,
input   wire		reset              ,
input   wire [23:0]	app_rx_data        ,
input   wire		app_rx_data_valid  ,
input   wire [15:0] app_rx_data_length ,
			
input   wire		udp_tx_ready       ,
input   wire		app_tx_ack         ,
output  wire  [7:0] app_tx_data        ,
output	reg  		app_tx_data_request,
output	reg  		app_tx_data_valid  ,
output  reg  [15:0]	udp_data_length	 ,  //s
output  full_flag,
output [11:0 ] udp_wrusedw		
);
parameter  			 	DEVICE            = "EG4";//"PH1","EG4"
parameter               und_lenghth       =12'd969;//用来防止把fifo读空造成错位//这里用udp数据长来代替其实是三倍需求的保险

reg         app_tx_data_read;
wire [11:0] udp_packet_fifo_data_cnt;//synthesis keep
reg  [15:0] fifo_read_data_cnt;
reg  [15:0] udp_data_length_reg_ff1;
reg  [15:0] udp_data_length_reg_ff2;
wire [23:0]  app_tx_data_reg;


wire  [15:0] fifo_read_data_cnt_wire;
assign fifo_read_data_cnt_wire =fifo_read_data_cnt ;
assign app_tx_data = (fifo_read_data_cnt_wire%3 == 16'd0 )? app_tx_data_reg_d [7:0] : 
                     ((fifo_read_data_cnt_wire%3 == 16'd2 )? app_tx_data_reg_d [15:8] : 
                     ((fifo_read_data_cnt_wire%3 == 16'd1 )? app_tx_data_reg_d [23:16] : 0));

//延时ram_fifo的输出实现对齐,让定位信息出现在udp包头                     
reg   [23:0] app_tx_data_reg_d_byread;
reg   [23:0] app_tx_data_reg_d;

always @(posedge app_tx_data_read or posedge reset) begin
    if (reset) begin
        app_tx_data_reg_d_byread<= 24'd0;
    end
    else begin
        app_tx_data_reg_d_byread<=app_tx_data_reg;      
    end
end

always @(posedge app_tx_clk or posedge reset) begin
    if (reset) begin
        app_tx_data_reg_d <= 24'd0;
    end
    else begin
        app_tx_data_reg_d<=app_tx_data_reg_d_byread;      
    end
end

reg [2:0]   STATE;//synthesis keep
localparam  FIND_READ       = 3'd0;
localparam  FIND_DETACT     = 3'd1;
localparam  WAIT_UDP_DATA   = 3'd2;
localparam  WAIT_ACK        = 3'd3;
localparam  SEND_UDP_DATA   = 3'd4;
localparam  DELAY           = 3'd5;

// assign udp_packet_fifo_data_cnt = 1;

wire empty_flag;//synthesis keep

ram_fifo#
(
	.DEVICE       	(DEVICE       	),//"PH1","EG4","SF1","EF2","EF3","AL"
	.DATA_WIDTH_W 	(24				),//写数据位宽
	.ADDR_WIDTH_W 	(12 			),//写地址位宽
	.DATA_WIDTH_R 	(24 			),//读数据位宽
	.ADDR_WIDTH_R 	(12 			),//读地址位宽
	.SHOW_AHEAD_EN	(1				)//普通/SHOWAHEAD模式
)
udp_packet_fifo
(
	.rst			(reset				), 
	.di				(app_rx_data		), 
	.clkw			(app_rx_clk			), 
	.we				(app_rx_data_valid	),
	.clkr			(app_tx_clk			), 
	.re				(app_tx_data_read	), 
	.do				(app_tx_data_reg	), 
	.empty_flag		(	empty_flag				), 
	.full_flag		(full_flag					), 
	.wrusedw		(	udp_wrusedw				), 
	.rdusedw		(udp_packet_fifo_data_cnt)//udp_packet_fifo_data_cnt)
);


// fifo_sdr_data_2 udp_packet_fifo(
//    .rst			   			(reset	)	,  //asynchronous port,active hight
//    .clkw		   			(app_rx_clk		),  //write clock
//    .clkr		   			(app_tx_clk		),  //read clock
//    .we			   			(app_rx_data_valid			),  //write enable,active hight
//    .di			   			(app_rx_data			),  //write data
//    .re			   			(app_tx_data_read			),  //ead enable,active hight
//    .	dout		    	(app_tx_data_reg		),  //read data
//    . 	valid		     	(app_tx_data_valid		),  //read data valid flag
//    .	full_flag	    	(full_flag	),  //fifo full flag
//    .	empty_flag	    	(empty_flag	),  //fifo empty flag
//    .	afull		    	(		),  //fifo almost full flag
//    .	aempty		    	(		),  //fifo almost empty flag
//    .	wrusedw	  	    	(	)	,  	//	stored data number in fifo
//    .	rdusedw 	    	( 	)//available data number for read
 
// );


always@(posedge app_tx_clk or posedge reset)
begin
	if(reset) begin
		udp_data_length_reg_ff1 <= 16'd0;
		udp_data_length_reg_ff2 <= 16'd0;
	end	
	else if(app_rx_data_valid)
	begin 
		udp_data_length_reg_ff1 <= app_rx_data_length;
		udp_data_length_reg_ff2 <= udp_data_length_reg_ff1;
	end
end

reg [19:0]tx_cnt ;//synthesis keep
always@(posedge app_tx_clk or posedge reset)
begin
	if(reset) begin
		tx_cnt <= 20'd0;
	end	
	else if(app_tx_data_valid)
	begin 
    tx_cnt<=tx_cnt+1;
	end
end


reg [15:0]cnt;
always@(posedge app_tx_clk or posedge reset)
begin
	if(reset) begin
		app_tx_data_request <= 1'b0;
		app_tx_data_read 	<= 1'b0;
		app_tx_data_valid 	<= 1'b0;
		fifo_read_data_cnt 	<= 16'd0;
		udp_data_length 	<= 16'd0;
        cnt <=16'b0;
		STATE 				<= WAIT_UDP_DATA;
	end
	else begin
	   case(STATE)
            FIND_READ:
                begin
                    app_tx_data_read 	<= 1'b1;
                    STATE               <=FIND_DETACT;
                end
            FIND_DETACT:
                begin
                    app_tx_data_read    <= 1'b0;
                    if(app_tx_data_reg==24'hff00ff) begin
                       STATE            <=WAIT_UDP_DATA; 
                       end
                    else begin
                        STATE            <=FIND_READ;
                    end
                end
			WAIT_UDP_DATA:
				begin
                    cnt<=16'b0;
					if((udp_packet_fifo_data_cnt > und_lenghth)  && (~app_rx_data_valid) && udp_tx_ready) begin
                  //if(!empty_flag && (~app_rx_data_valid) && udp_tx_ready) begin
                   // if( (~app_rx_data_valid) && udp_tx_ready) begin
						app_tx_data_request <= 1'b1;
						STATE 				<= WAIT_ACK;
					end
					else begin
						app_tx_data_request <= 1'b0;
     
						STATE 				<= WAIT_UDP_DATA;
					end
				end
			WAIT_ACK: 
				begin
				   if(app_tx_ack) begin
						app_tx_data_request <= 1'b0;
						app_tx_data_read 	<= 1'b0;//把每包的第一个数据交给检测去读
						app_tx_data_valid 	<= 1'b0;
						udp_data_length 	<= udp_data_length_reg_ff2;//
						STATE 				<= SEND_UDP_DATA;
					end
					else begin
						app_tx_data_request <= 1'b1;
						app_tx_data_read	<= 1'b0;
						app_tx_data_valid 	<= 1'b0;
						udp_data_length 	<= 16'd0;
						STATE 				<= WAIT_ACK;
					end
				end
			SEND_UDP_DATA: 
				begin
					if(fifo_read_data_cnt == (udp_data_length_reg_ff2 )) begin
						fifo_read_data_cnt 	<= 16'd0;
						app_tx_data_valid 	<= 1'b0;
						app_tx_data_read 	<= 1'b0;
						STATE 				<= DELAY;
					end
					else  if (fifo_read_data_cnt == 0 )begin
						fifo_read_data_cnt 	<= fifo_read_data_cnt + 1'b1;
						app_tx_data_valid  	<= 1'b1;
						app_tx_data_read 	<= 1'b0;
						STATE 				<= SEND_UDP_DATA;
					end	
                    //增加模三触发读
                    else  if ((fifo_read_data_cnt%3 ==16'd2 )&&(fifo_read_data_cnt!=udp_data_length_reg_ff2-16'd1))begin
						fifo_read_data_cnt 	<= fifo_read_data_cnt + 1'b1;
						app_tx_data_valid  	<= 1'b1;
						app_tx_data_read 	<= 1'b1;
						STATE 				<= SEND_UDP_DATA;
					end	
					else begin
						fifo_read_data_cnt 	<= fifo_read_data_cnt + 1'b1;
						app_tx_data_valid  	<= 1'b1;
						app_tx_data_read 	<= 1'b0;
						STATE 				<= SEND_UDP_DATA;
					end				
				end
			DELAY:
				begin
					if(cnt<16'h00000fff)begin
                    	cnt<=cnt+1'b1;
						STATE 	<= DELAY;
                        end
					else
						STATE 	<= FIND_READ;
				end
			default: STATE 		<= FIND_READ;
		endcase
	end
end

endmodule
