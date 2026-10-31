`timescale 1ns/1ps
// A first active pixel on SOF counts. Bright blanking and invalid extra pixels do not.
module camera_black_boundary_tb;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,sof=0,de=0;
    reg [11:0] x=0,y=0;
    reg [23:0] pixel=0;
    wire covered,frame_is_black,frame_valid;
    camera_black_gate #(.WIDTH(50),.HEIGHT(1),.CONFIRM_FRAMES(2),.RELEASE_FRAMES(1)) dut(.*);
    integer i;
    task send;
        input integer black_count;
        input [23:0] dark;
        begin
            // Initial pixel belongs to the NEW frame, not the one being closed.
            @(negedge clk);sof=1;de=1;x=0;y=0;pixel=(black_count>0)?dark:24'hffffff;
            for(i=1;i<50;i=i+1) begin
                @(negedge clk);sof=0;x=i;pixel=(i<black_count)?dark:24'hffffff;
            end
            @(negedge clk);de=0;sof=0;pixel=24'h000000;
        end
    endtask
    task close_frame;
        begin @(negedge clk);sof=1;de=0;@(negedge clk);sof=0;end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;
        send(49,24'h101010);close_frame;
        if(!frame_valid || !frame_is_black || covered) $fatal(1,"SOF first pixel or 16 boundary failed");
        send(49,24'h101010); // starts a new frame; empty prior interval resets the streak
        send(49,24'h101010); // first 98%-black frame closes while next first pixel starts
        send(49,24'h101010);
        if(!covered) $fatal(1,"back-to-back SOF active pixels did not confirm");
        send(50,24'h111111);close_frame;
        if(!frame_valid || frame_is_black || covered) $fatal(1,"17 is not near-black");
        send(48,24'h000000);close_frame;
        if(frame_is_black) $fatal(1,"96 percent accepted");
        send(50,24'h000000);
        @(negedge clk);de=1;sof=0;x=0;y=0;
        @(negedge clk);de=0;close_frame;
        if(frame_valid || covered) $fatal(1,"overflow accepted");
        $display("PASS: camera_black_boundary first-active-SOF/RGB16vs17/96vs98/overflow");$finish;
    end
    initial begin #100000;$fatal(1,"timeout");end
endmodule
