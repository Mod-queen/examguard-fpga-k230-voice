`timescale 1ns/1ps
module camera_black_720p_tb;
    reg clk=0;always #5 clk=~clk;
    reg rst=1,sof=0,de=0;
    reg [11:0] x=0,y=0;
    reg [23:0] pixel=0;
    wire covered,frame_is_black,frame_valid;
    camera_black_gate #(.CONFIRM_FRAMES(2)) dut(.*);
    task frame;
        input integer blacks;
        integer i;
        begin
            for(i=0;i<921600;i=i+1) begin
                @(negedge clk);de=1;sof=0;x=i%1280;y=i/1280;
                pixel=(i<blacks)?24'h000000:24'hffffff;
            end
            @(negedge clk);de=0;
            @(negedge clk);sof=1;
            @(negedge clk);sof=0;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;sof=1;
        @(negedge clk);sof=0;
        frame(903167);
        if(!frame_valid || frame_is_black || covered) $fatal(1,"903167 of 921600 must fail");
        frame(903168);
        if(!frame_valid || !frame_is_black || covered) $fatal(1,"903168 first frame must start confirmation");
        frame(903168);
        if(!covered) $fatal(1,"full-size exact98 second frame must confirm");
        $display("PASS: 720p all921600 pixels exact903167/903168 threshold and confirmation");$finish;
    end
    initial begin #40000000;$fatal(1,"timeout");end
endmodule
