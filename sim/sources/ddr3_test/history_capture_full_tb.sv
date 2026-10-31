`timescale 1ns/1ps
// Default-sized sampled RGB565 frames, all pixels checked across two banks.
module history_capture_full_tb;
    localparam FP=57600;
    reg clk=0,rst=1,frame_start=0,frame_end=0,enable=1,time_valid=1,in_valid=0,in_last=0;
    always #5 clk=~clk;
    reg [95:0] in_meta=0;
    reg [15:0] in_index=0,in_data=0;
    wire command_valid,pixel_valid,pixel_last,halted;
    reg command_ready=0,pixel_ready=0;
    wire [1:0] command_kind,banks_occupied;
    wire [95:0] command_meta;
    wire [7:0] command_reason;
    wire [15:0] pixel_data;
    wire [2:0] halt_reason;
    wire [4:0] occupancy;
    wire [31:0] frames_seen,frames_published,frames_dropped,decisions_sent;
    history_capture_source dut(.*);
    integer frame_number=0,phase=0,received=0,seed=827,p,f,cycles=0;
    reg drain=0;
    function [15:0] pattern(input integer source,input integer pixel);
        pattern=((pixel*29) ^ (source*16'h5317)) & 65535;
    endfunction
    always @(negedge clk) begin
        command_ready=drain && (($random(seed)&7)!=0);
        pixel_ready=drain && (($random(seed)&3)!=0);
    end
    always @(posedge clk) if(!rst) begin
        cycles=cycles+1;
        if(halted) $fatal(1,"FAIL: full frame producer halted");
        if(command_valid && command_ready) begin
            if(command_meta!=={32'(frame_number+1),64'((frame_number+1)*100)}) $fatal(1,"FAIL: full metadata");
            if(phase==0) begin
                if(command_kind!=(frame_number<2?0:1) || command_reason!=(frame_number<2?0:2)) $fatal(1,"FAIL: full frame decision");
                phase=frame_number<2?1:2;received=0;
            end else if(phase==2) begin
                if(command_kind!=2) $fatal(1,"FAIL: full frame fence");
                frame_number=frame_number+1;phase=0;
            end else $fatal(1,"FAIL: command before full pixel drain");
        end
        if(pixel_valid && pixel_ready) begin
            if(phase!=1 || pixel_data!==pattern(frame_number+1,received) || pixel_last!=(received==FP-1))
                $fatal(1,"FAIL: full bank readout frame%0d pixel%0d got%h",frame_number,received,pixel_data);
            received=received+1;
            if(pixel_last) phase=2;
        end
    end
    initial begin
        repeat(5) @(negedge clk);#1;rst=0;
        for(f=1;f<=3;f=f+1) begin
            @(negedge clk);#1;frame_start=1;in_meta={32'(f),64'(f*100)};
            for(p=0;p<FP;p=p+1) begin
                in_valid=1;in_data=pattern(f,p);in_index=p;in_last=p==FP-1;
                @(negedge clk);#1;frame_start=0;
                // Metadata is only a START snapshot, never a per-pixel input.
                in_meta=96'hfeedbeef_deadbeef_01234567;
            end
            in_valid=0;in_last=0;
        end
        if(banks_occupied!=2 || frames_published!=2 || frames_dropped!=1 || occupancy!=3)
            $fatal(1,"FAIL: full-sized bank/queue ownership");
        drain=1;wait(frame_number==3);repeat(5) @(negedge clk);#1;
        if(banks_occupied || occupancy || decisions_sent!=3) $fatal(1,"FAIL: full frame ownership not released");
        $display("PASS: history_capture_full default57600 2frames115200pixels/third busyDROP/metadata START snapshot/random output stalls cycles=%0d",cycles);
        $finish;
    end
    initial begin #15000000;$fatal(1,"FAIL: full frame capture timeout");end
endmodule
