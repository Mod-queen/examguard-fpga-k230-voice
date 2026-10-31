`timescale 1ns/1ps
module camera_time_guard_tb;
    reg clk=0,rst=1,sof=0,enable=1,time_valid=0,de=0;
    always #5 clk=~clk;
    reg [31:0] frame_id=0,age_cycles=0;
    reg [63:0] time_ms=64'h12345678ffffffff;
    wire frame_enable;
    wire [95:0] frame_meta;
    wire [31:0] rejected_unknown,rejected_stale;
    camera_time_guard #(.MAX_AGE_CYCLES(10)) time_check(.*);
    reg [11:0] x=0,y=0;
    reg [7:0] pixel_r=0,pixel_g=0,pixel_b=0;
    wire out_valid,out_sof,out_last;
    wire [15:0] out_data;
    wire [95:0] out_meta;
    reg out_ready=1;
    wire [1:0] banks_occupied;
    wire [31:0] frames_seen,frames_buffered,frames_sent,dropped_busy,dropped_invalid,dropped_disabled;
    camera_sample_guard #(.SRC_WIDTH(8),.SRC_HEIGHT(8),.FRAME_INTERVAL(1)) sampler(
        .enable(frame_enable),.*);
    integer got=0,pixel=0,xx,yy;
    reg [95:0] expected[0:3];
    reg [15:0] colors[0:3];
    always @(posedge clk) if(!rst && out_valid && out_ready) begin
        if(out_meta!==expected[got] || out_data!==colors[got] || out_sof!==(pixel==0) || out_last!==(pixel==3))
            $fatal(1,"FAIL: time-qualified frame metadata/pixel/whole-frame admission");
        if(out_last) begin pixel=0;got=got+1;end else pixel=pixel+1;
    end
    task frame;
        input integer id,valid,age,mutate;
        begin
            @(negedge clk);sof=1;frame_id=id;time_valid=valid;age_cycles=age;time_ms=64'h12345678ffffffff+id;
            {pixel_r,pixel_g,pixel_b}=24'hf08028+id*256;
            for(yy=0;yy<8;yy=yy+1) for(xx=0;xx<8;xx=xx+1) begin
                de=1;x=xx;y=yy;
                @(negedge clk);sof=0;
                // SOF admission is atomic: becoming valid mid rejected frame
                // cannot rescue its tail, and becoming stale mid accepted frame
                // does not tear its held timestamp.
                if(mutate) begin time_valid=!valid;age_cycles=100;time_ms=~time_ms;end
            end
            de=0;repeat(35) @(negedge clk);
        end
    endtask
    initial begin
        expected[0]={32'd2,64'h1234567900000001};colors[0]={5'h1e,6'h20,5'h05};
        expected[1]={32'd3,64'h1234567900000002};colors[1]={5'h1e,6'h20,5'h05};
        repeat(8) @(negedge clk);rst=0;
        frame(0,0,0,1); // unknown at SOF, no tail rescue
        frame(1,1,11,0); // stale just beyond bound
        frame(2,1,10,1); // inclusive bound, then stale midframe
        frame(3,1,0,0); // fresh, including low32 time rollover
        enable=0;frame(4,0,0,0);enable=1;
        if(got!=2 || rejected_unknown!=1 || rejected_stale!=1 || frames_seen!=5 || frames_sent!=2 || dropped_disabled!=3 || dropped_invalid)
            $fatal(1,"FAIL: time qualification accounting got=%d unknown/stale=%d/%d",got,rejected_unknown,rejected_stale);
        time_check.rejected_unknown=32'hffffffff;time_check.rejected_stale=32'hffffffff;
        frame(5,0,0,0);frame(6,1,11,0);
        if(rejected_unknown!=32'hffffffff || rejected_stale!=32'hffffffff) $fatal(1,"FAIL: time rejection counters wrapped");
        @(negedge clk);rst=1;repeat(4) @(negedge clk);rst=0;
        if(rejected_unknown || rejected_stale || frame_enable) $fatal(1,"FAIL: time validity/reset state");
        $display("PASS: camera_time_guard unknown/stale/inclusive-age/SOF-atomicity/RGB-metadata/rollover/saturation/reset");$finish;
    end
    initial begin #1000000;$fatal(1,"FAIL: camera time guard timeout");end
endmodule
