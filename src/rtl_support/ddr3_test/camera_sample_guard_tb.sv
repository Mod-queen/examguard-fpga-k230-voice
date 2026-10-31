`timescale 1ns/1ps
module camera_sample_case #(parameter W=32,H=20,S=4,INTERVAL=2,FULL=0)(output reg passed=0);
    localparam FW=W/S,FH=H/S,FP=FW*FH;
    reg clk=0,rst=1,enable=1,sof=0,de=0;
    always #5 clk=~clk;
    reg [7:0] pixel_r=0,pixel_g=0,pixel_b=0;
    reg [11:0] x=0,y=0;
    reg [95:0] frame_meta=0;
    wire out_valid,out_sof,out_last;
    wire [15:0] out_data;
    wire [95:0] out_meta;
    reg out_ready=0,random_ready=0;
    wire [1:0] banks_occupied;
    wire [31:0] frames_seen,frames_buffered,frames_sent,dropped_busy,dropped_invalid,dropped_disabled;
    camera_sample_guard #(.SRC_WIDTH(W),.SRC_HEIGHT(H),.SAMPLE_STRIDE(S),.FRAME_INTERVAL(INTERVAL)) dut(.*);
    integer expected[0:31],tail=0,head=0,pixel=0,xx,yy,f;
    reg [31:0] rng=32'hca987655;
    reg stalled=0;
    reg [113:0] held;
    function [95:0] meta;
        input integer n;
        begin meta={32'(n),64'h1234567800000000+n*100};end
    endfunction
    function [23:0] rgb;
        input integer n,px,py;
        begin rgb={8'(n*7+px),8'(n*13+py),8'(n*17+px+py)};end
    endfunction
    function [15:0] expected_pixel;
        input integer n,idx;
        reg [23:0] color;
        begin color=rgb(n,(idx%FW)*S,(idx/FW)*S);expected_pixel={color[23:19],color[15:10],color[7:3]};end
    endfunction
    always @(negedge clk) if(random_ready) begin
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};out_ready=rng[0] || rng[2];
    end
    always @(posedge clk) if(!rst) begin
        if(stalled && (!out_valid || {out_data,out_meta,out_sof,out_last}!==held)) $fatal(1,"FAIL: camera sample held output changed");
        stalled<=out_valid && !out_ready;held<={out_data,out_meta,out_sof,out_last};
        if(out_valid && out_ready) begin
            if(head>=tail || out_data!==expected_pixel(expected[head],pixel) || out_meta!==meta(expected[head]) ||
                out_sof!==(pixel==0) || out_last!==(pixel==FP-1))
                $fatal(1,"FAIL: camera sample grid/meta frame=%d pixel=%d",head,pixel);
            if(out_last) begin pixel=0;head=head+1;end else pixel=pixel+1;
        end
    end
    task expect_frame;
        input integer n;
        begin expected[tail]=n;tail=tail+1;end
    endtask
    task frame;
        input integer n,missing,coincident;
        begin
            @(negedge clk);sof=1;frame_meta=meta(n);de=0;
            if(!coincident) begin @(negedge clk);sof=0;end
            for(yy=0;yy<H;yy=yy+1) begin
                for(xx=0;xx<W;xx=xx+1) begin
                    x=xx;y=yy;de=!(missing==1 && xx==S && yy==0) && !(missing==2 && xx==W-S && yy==H-S);
                    {pixel_r,pixel_g,pixel_b}=rgb(n,xx,yy);
                    @(negedge clk);sof=0;frame_meta=~meta(n);
                end
                de=0;repeat(4) @(negedge clk);
            end
            de=0;repeat(8) @(negedge clk);
        end
    endtask
    initial begin
        repeat(8) @(negedge clk);rst=0;
        // Default full geometry: 320x180 complete frames; actual raster cadence
        // tested elsewhere, this case stresses full-sized banks/grid/index.
        if(FULL) begin
            random_ready=1;expect_frame(0);frame(0,0,1);
            for(f=1;f<INTERVAL;f=f+1) frame(f,0,0);
            expect_frame(INTERVAL);frame(INTERVAL,0,0);
            wait(head==2);repeat(4) @(negedge clk);
            if(frames_seen!=INTERVAL+1 || frames_sent!=2 || dropped_disabled!=INTERVAL-1 || dropped_busy || dropped_invalid)
                $fatal(1,"FAIL: full camera sample conservation");
        end else begin
            expect_frame(0);expect_frame(2);
            frame(0,0,1);frame(1,0,0);frame(2,0,0);frame(3,0,0);
            // Both banks retained: entire selected frame4 is dropped.
            frame(4,0,1);frame(5,0,0);
            if(dropped_busy!=1 || frames_buffered!=2) $fatal(1,"FAIL: sampler bank overflow not whole-frame");
            random_ready=1;wait(head==2);
            // Missing middle/last grid samples must be invalid, not reindexed.
            frame(6,1,1);frame(7,0,0);frame(8,2,0);frame(9,0,0);
            expect_frame(10);frame(10,0,1);frame(11,0,0);wait(head==3);
            enable=0;frame(12,0,1);enable=1;frame(13,0,0);
            expect_frame(14);frame(14,0,0);wait(head==4);
            @(negedge clk); // guard's final-handshake counter updates by NBA
            if(frames_seen!=15 || frames_buffered!=4 || frames_sent!=4 || dropped_invalid!=2 || dropped_busy!=1 || dropped_disabled!=8)
                $fatal(1,"FAIL: sampler missing-sample/stride/cadence counts invalid=%d disabled=%d",dropped_invalid,dropped_disabled);
        end
        $display("camera_sample_guard %0dx%0d stride%0d interval%0d checked_frames=%0d pixels=%0d PASS",W,H,S,INTERVAL,head,head*FP);
        passed=1;
    end
endmodule
module camera_sample_guard_tb;
    wire a,b;
    camera_sample_case small_case(a);
    camera_sample_case #(.W(1280),.H(720),.S(4),.INTERVAL(6),.FULL(1)) full_case(b);
    initial begin wait(a&&b);$display("PASS: camera_sample_guard all checks");$finish;end
    initial begin #100000000;$fatal(1,"FAIL: camera sample timeout");end
endmodule
