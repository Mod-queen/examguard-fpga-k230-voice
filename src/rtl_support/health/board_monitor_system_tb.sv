`timescale 1ns/1ps
// Forked actual MIG temperature synchronizer + real XADC primitive + payload CDC
// + BM packet; simulated analog values, not board measurements.
module board_monitor_system_tb;
    reg xclk=0,ui_clk=0,clk=0,rst=1;
    always #2.5 xclk=~xclk;always #5 ui_clk=~ui_clk;always #10 clk=~clk;
    wire [96:0] monitor,stats;wire valid;wire [31:0] age_cycles;wire [11:0] temperature;
    mig_7series_v4_2_tempmon tempmon(.clk(ui_clk),.xadc_clk(xclk),.rst(rst),.device_temp_i(12'd0),
        .device_temp(temperature),.board_monitor(monitor));
    defparam tempmon.xadc_supplied_temperature.shared_monitor.xadc.SIM_MONITOR_FILE="D:/fpga_race/docs/baselines/xadc_sim_analog_20261021.txt";
    cdc_stats_snapshot #(.WIDTH(97)) snapshot(.src_clk(xclk),.src_rst(rst),.src_stats(monitor),
        .dst_clk(clk),.dst_rst(rst),.stats(stats),.valid(valid),.age_cycles(age_cycles));
    wire byte_valid,byte_last;wire [7:0] byte_data;integer fd,count=0;
    board_monitor_record #(.PERIOD_CYCLES(10000)) record_inst(.clk(clk),.rst(rst),.monitor(stats),.monitor_valid(valid),
        .device_id(32'd1),.boot_id(32'd18),.seat_id(32'd6),.monotonic_ms(64'd1000),.straps_valid(1'b1),.switches(8'h85),
        .byte_valid(byte_valid),.byte_last(byte_last),.byte_data(byte_data),.byte_ready(1'b1));
    always @(posedge clk) if(!rst && byte_valid) begin
        $fwrite(fd,"%c",byte_data);if(byte_last) count=count+1;
    end
    initial begin
        fd=$fopen("board_monitor_system.txt","w");repeat(10) @(negedge clk);rst=0;
        wait(count==2);#1;
        if(!monitor[96] || !valid || temperature<2300 || temperature>2500)
            $fatal(1,"FAIL: tempmon did not receive coherent temperature %d",temperature);
        $fclose(fd);$display("PASS: board_monitor_system actual MIG temp sync/one UNISIM XADC/97bit CDC/BM CRC");$finish;
    end
    initial begin #2000000;$fatal(1,"FAIL: board_monitor_system timeout");end
endmodule
