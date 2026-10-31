`timescale 1ns/1ps
// Actual snapshot DVP byte pairing/reset synchronizer; no camera/MIG model.
module camera_capture_reset_tb;
    reg PCLK=0,run_clock=1,raw_fault=1,reset_n=0;
    always #5 if(run_clock) PCLK=~PCLK;
    reg Vsync=0,Href=0;
    reg [7:0] Data=0;
    wire capture_rst,ImageState,DataValid,DataHs,DataVs;
    wire [15:0] DataPixel;
    wire [11:0] Xaddr,Yaddr;
    video_epoch_clear release_inst(.ui_clk(PCLK),.ui_rst(1'b0),.source_clear(raw_fault || !reset_n),.fifo_ui_rst_busy(1'b0),.client_clear(capture_rst));
    DVP_Capture dut(.Rst_p(capture_rst),.*);
    integer n,p,received=0,expected_count=0;
    reg checking=0,suppress_pixels=0;
    reg [15:0] expected[0:31];
    always @(posedge PCLK) begin
        #1;
        if(capture_rst && (DataValid!==0 || dut.FrameCnt!==0 || dut.dump_frame!==0 || dut.Hcount!==0))
            $fatal(1,"FAIL: camera capture reset not held");
        if(suppress_pixels && DataValid) $fatal(1,"FAIL: camera warmup leaked pixel");
        if(checking && DataValid) begin
            if(received>=expected_count || DataPixel!==expected[received])
                $fatal(1,"FAIL: camera RGB565 alignment index=%0d data=%h expected=%h",received,DataPixel,expected[received]);
            received=received+1;
        end
    end
    task release_check;
        begin
            // Must not release before exactly three CLEAN edges; capture
            // sees asserted reset on that third edge and works on the fourth.
            for(n=1;n<=3;n=n+1) begin
                @(posedge PCLK);#2;
                if(capture_rst!==(n<3)) $fatal(1,"FAIL: camera synchronous release edge%0d",n);
                if(dut.FrameCnt!==0 || dut.Hcount!==0) $fatal(1,"FAIL: camera premature work");
            end
            @(negedge PCLK);
        end
    endtask
    task send_line;
        input integer base;
        begin
            @(negedge PCLK);Href=1;
            for(p=0;p<8;p=p+1) begin
                Data=base+p;@(negedge PCLK);
            end
            Href=0;Data=8'hee;repeat(5) @(negedge PCLK);
        end
    endtask
    task sync_frame;
        begin
            @(negedge PCLK);Vsync=1;repeat(3) @(negedge PCLK);Vsync=0;
            repeat(3) @(negedge PCLK);
        end
    endtask
    task warmup_and_pixels;
        integer f,i;
        begin
            suppress_pixels=1;
            for(f=1;f<=9;f=f+1) begin
                sync_frame();send_line(f*8);
                if(DataValid || dut.dump_frame || dut.FrameCnt!=f) $fatal(1,"FAIL: camera first9 frames not suppressed");
            end
            suppress_pixels=0;
            sync_frame();
            if(dut.FrameCnt!=10 || !dut.dump_frame) $fatal(1,"FAIL: camera tenth VS warmup boundary");
            expected_count=8;received=0;
            for(i=0;i<4;i=i+1) begin expected[i]={8'(8'h80+i*2),8'(8'h81+i*2)};expected[4+i]={8'(8'h90+i*2),8'(8'h91+i*2)};end
            checking=1;send_line(128);send_line(144);checking=0;
            if(received!=8) $fatal(1,"FAIL: camera pixel count=%0d",received);
            sync_frame();if(dut.FrameCnt!=10) $fatal(1,"FAIL: camera warmup counter not saturated");
        end
    endtask
    initial begin
        repeat(4) @(negedge PCLK);reset_n=1;raw_fault=0;
        release_check();warmup_and_pixels();
        // Cancel active half-pixel using a pulse shorter than one PCLK period.
        @(negedge PCLK);Href=1;Data=8'hba;@(negedge PCLK);Data=8'hdc;
        #1;raw_fault=1;#1;
        if(!capture_rst || DataValid) $fatal(1,"FAIL: camera short pulse asynchronous assert");
        raw_fault=0;Href=0;release_check();warmup_and_pixels();
        // Clock stopped: reset assertion still clears capture immediately;
        // deasserting raw fault must never release until PCLK resumes.
        @(negedge PCLK);run_clock=0;#2;reset_n=0;#1;reset_n=1;
        #47;if(!capture_rst || DataValid || dut.FrameCnt!=0) $fatal(1,"FAIL: camera stopped-clock reset");
        raw_fault=1;#1;raw_fault=0;#29;
        if(!capture_rst) $fatal(1,"FAIL: camera stopped-clock retrigger");
        run_clock=1;release_check();warmup_and_pixels();
        // Reassert during release: restart all three stages, not two remaining.
        @(negedge PCLK);raw_fault=1;#1;raw_fault=0;
        @(posedge PCLK);#1;raw_fault=1;#1;raw_fault=0;
        release_check();warmup_and_pixels();
        $display("PASS: camera_capture_reset actual DVP/3edge release/stopped PCLK/short pulse/retrigger/warmup10/RGB565 recovery");$finish;
    end
    initial begin #200000;$fatal(1,"FAIL: camera reset timeout");end
endmodule
