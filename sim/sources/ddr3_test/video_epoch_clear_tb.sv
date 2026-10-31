`timescale 1ns/1ps
module video_epoch_clear_tb;
    reg ui_clk=0,ui_rst=1,source_clear=0,fifo_ui_rst_busy=0;
    always #5 ui_clk=~ui_clk;
    wire client_clear;
    video_epoch_clear dut(.*);
    integer i;
    initial begin
        #2;if(!client_clear) $fatal(1,"FAIL: common reset did not hold epoch");
        @(negedge ui_clk);ui_rst=0;
        repeat(3) @(negedge ui_clk);
        if(client_clear) $fatal(1,"FAIL: reset release did not settle");
        // Pulse entirely between UI edges must nevertheless be captured.
        #1;source_clear=1;#1;
        if(!client_clear) $fatal(1,"FAIL: subcycle frame clear lost");
        source_clear=0;
        for(i=0;i<2;i=i+1) begin @(negedge ui_clk);if(!client_clear) $fatal(1,"FAIL: premature release");end
        @(negedge ui_clk);if(client_clear) $fatal(1,"FAIL: pulse did not release");
        // Busy keeps clear asserted after the source pulse has gone away.
        #1;source_clear=1;#2;source_clear=0;fifo_ui_rst_busy=1;
        repeat(8) @(negedge ui_clk);
        if(!client_clear) $fatal(1,"FAIL: FIFO busy not honored");
        fifo_ui_rst_busy=0;#1;
        if(client_clear) $fatal(1,"FAIL: FIFO busy release stuck");
        // A second pulse during synchronization restarts the hold.
        source_clear=1;#2;source_clear=0;
        @(negedge ui_clk);source_clear=1;#2;source_clear=0;
        repeat(2) begin @(negedge ui_clk);if(!client_clear) $fatal(1,"FAIL: repeated pulse release");end
        @(negedge ui_clk);if(client_clear) $fatal(1,"FAIL: repeated pulse stuck");
        $display("PASS: video_epoch_clear short pulse/reset busy/retrigger all checks");$finish;
    end
    initial begin #10000;$fatal(1,"FAIL: epoch clear timeout");end
endmodule
