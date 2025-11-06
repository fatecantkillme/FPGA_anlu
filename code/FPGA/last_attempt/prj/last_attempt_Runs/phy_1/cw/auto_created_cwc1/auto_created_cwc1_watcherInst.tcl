source "D:/FPGA/TD6_2_1/cw/atpl/templa.tcl"
set fd [open "D:/FPGA/TD6_2_1/cw/atpl/cwc.atpl" r]
set tmpl [read $fd]
close $fd
set parser [::tmpl_parser::tmpl_parser $tmpl]

set ComponentName        auto_created_cwc1
set bus_num              3
set cwc_ctrl_len         104
set cwc_bus_ctrl_len     84
set bus_din_num          25
set ram_len              25
set input_pipe_num       0
set output_pipe_num      0
set depth                1024
set capture_ctrl_exist   0
set bus_width            { 8,16,1 };
set bus_din_pos          { 0,8,24 };
set bus_ctrl_pos         { 0,28,80 };
set fp [open "cw/auto_created_cwc1/auto_created_cwc1_watcherInst.sv" w+]
puts $fp [eval $parser]
close $fp
