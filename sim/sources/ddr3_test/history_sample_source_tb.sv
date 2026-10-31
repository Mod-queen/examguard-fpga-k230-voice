`timescale 1ns/1ps
module history_sample_source_case #(parameter W=8,H=8,S=4,INTERVAL=3,FULL=0)(output reg test_done=0);
    localparam FP=(W/S)*(H/S);
    reg clk=0,rst=1,enable=1,de=0,sof=0,time_valid=1;
    always #5 clk=~clk;
    reg [7:0] pixel_r=0,pixel_g=0,pixel_b=0;
    reg [11:0] x=0,y=0;
    reg [31:0] frame_id=0,age_cycles=0;
    reg [63:0] time_ms=0;
    wire command_valid,pixel_valid,pixel_last,halted;
    reg command_ready=0,pixel_ready=0,drain=1;
    wire [1:0] command_kind,banks_occupied;
    wire [95:0] command_meta;
    wire [7:0] command_reason;
    wire [15:0] pixel_data;
    wire [2:0] halt_reason;
    wire [4:0] occupancy;
    wire [31:0] frames_seen,frames_published,frames_dropped,decisions_sent,source_sofs,cadence_skipped,time_unknown,time_stale;
    history_sample_source #(.SRC_WIDTH(W),.SRC_HEIGHT(H),.SAMPLE_STRIDE(S),.FRAME_INTERVAL(INTERVAL),.MAX_AGE_CYCLES(20)) dut(.*);
    integer put=0,get=0,phase=0,pix=0,pixels_checked=0,seed=617,i;
    reg [95:0] metas[0:63];
    reg [1:0] kinds[0:63];
    reg [7:0] reasons[0:63];
    function [15:0] pattern(input integer id,input integer xx,input integer yy);
        pattern=((id*413) ^ (yy*W+xx)*37) & 65535;
    endfunction
    task automatic drive_pixel(input integer id,input integer xx,input integer yy);
        reg [15:0] rgb;
        begin
            rgb=pattern(id,xx,yy);x=xx;y=yy;
            pixel_r={rgb[15:11],rgb[15:13]};pixel_g={rgb[10:5],rgb[10:9]};pixel_b={rgb[4:0],rgb[4:2]};
        end
    endtask
    always @(negedge clk) begin
        command_ready=drain && (($random(seed)&3)!=0);
        pixel_ready=drain && (($random(seed)&3)!=0);
    end
    reg command_stalled=0,pixel_stalled=0;
    reg [105:0] held_command;
    reg [16:0] held_pixel;
    always @(posedge clk) begin
        if(rst || halted) begin command_stalled=0;pixel_stalled=0;end
        else begin
            if(command_stalled && (!command_valid || {command_kind,command_meta,command_reason}!==held_command)) $fatal(1,"FAIL: sampler command hold");
            if(pixel_stalled && (!pixel_valid || {pixel_data,pixel_last}!==held_pixel)) $fatal(1,"FAIL: sampler pixel hold");
            command_stalled=command_valid && !command_ready;pixel_stalled=pixel_valid && !pixel_ready;
            held_command={command_kind,command_meta,command_reason};held_pixel={pixel_data,pixel_last};
            if(command_valid && command_ready) begin
                if(get>=put || command_meta!==metas[get]) $fatal(1,"FAIL: sampler metadata/order W%0d get%0d",W,get);
                if(phase==0) begin
                    if(command_kind!=kinds[get] || command_reason!=reasons[get]) $fatal(1,"FAIL: sampler decision got%0d/%0d exp%0d/%0d",command_kind,command_reason,kinds[get],reasons[get]);
                    phase=command_kind==0 ? 1 : 2;pix=0;
                end else if(phase==2) begin
                    if(command_kind!=2) $fatal(1,"FAIL: sampler fence");phase=0;get=get+1;
                end else $fatal(1,"FAIL: fence overtook samples");
            end
            if(pixel_valid && pixel_ready) begin
                if(phase!=1 || pixel_data!==pattern(metas[get][95:64],(pix%(W/S))*S,(pix/(W/S))*S) || pixel_last!=(pix==FP-1))
                    $fatal(1,"FAIL: grid RGB/index FP%0d pix%0d got%h",FP,pix,pixel_data);
                pixels_checked=pixels_checked+1;
                if(pixel_last) phase=2;else pix=pix+1;
            end
        end
    end
    task automatic expect_decision(input integer id,input [1:0] kind,input [7:0] reason);
        begin metas[put]={32'(id),64'(id*100)};kinds[put]=kind;reasons[put]=reason;put=put+1;end
    endtask
    // mode1 drops one interior sample, mode2 drops final grid sample;
    // mode3 truncates physical frame before END; metadata changes mid-frame.
    task automatic send_frame(input integer id,input separate_sof,input integer mode);
        integer xx,yy;
        begin
            @(negedge clk);#1;frame_id=id;time_ms=id*100;time_valid=1;age_cycles=20;sof=1;de=0;
            if(separate_sof) begin @(negedge clk);#1;sof=0;end
            for(yy=0;yy<H;yy=yy+1) begin
                for(xx=0;xx<W;xx=xx+1) begin
                    drive_pixel(id,xx,yy);de=1;
                    if((mode==1 && xx==S && yy==0) || (mode==2 && xx==W-S && yy==H-S) || (mode==3 && yy>=H/2)) de=0;
                    @(negedge clk);#1;sof=0;frame_id=32'hdeadbeef;time_ms=64'h123456789abcdef0;age_cycles=99;time_valid=0;
                end
                de=0;repeat(2) @(negedge clk);#1;
            end
            de=0;sof=0;
        end
    endtask
    task automatic flush;
        begin drain=1;wait(get==put);repeat(8) @(negedge clk);#1;
            if(halted || occupancy || banks_occupied) $fatal(1,"FAIL: sampler flush");end
    endtask
    task automatic reset_all;
        begin
            @(negedge clk);#1;rst=1;de=0;sof=0;enable=1;drain=1;
            repeat(4) @(negedge clk);#1;rst=0;put=0;get=0;phase=0;pix=0;
        end
    endtask
    initial begin
        reset_all();
        // Real default geometry case sends seven1280x720 frames, selecting0/6.
        for(i=0;i<=INTERVAL;i=i+1) begin
            if(i==0 || i==INTERVAL) expect_decision(i+1,0,0);
            send_frame(i+1,i%2,0);
        end
        flush();
        if(frames_seen!=2 || frames_published!=2 || source_sofs!=INTERVAL+1 || cadence_skipped!=INTERVAL-1 || time_unknown || time_stale)
            $fatal(1,"FAIL: cadence/time latching");
        if(!FULL) begin
            reset_all();enable=0;expect_decision(1,1,1);send_frame(1,0,0);flush();
            // Enable changes do not restart cadence: skipped frames generate no
            // DROP/fence even when their time snapshot is unknown/stale.
            enable=1;
            for(i=1;i<INTERVAL;i=i+1) send_frame(i+1,1,0);
            expect_decision(INTERVAL+1,0,0);send_frame(INTERVAL+1,0,0);flush();
            if(FP>1 && W>S) begin
                reset_all();expect_decision(1,1,3);send_frame(1,0,1);flush();
                reset_all();expect_decision(1,1,5);send_frame(1,0,2);flush();
            end
            if(INTERVAL>1 && H>1) begin
                reset_all();expect_decision(1,1,5);send_frame(1,0,3);
                // Skipped next SOF closes incomplete selected frame, no new
                // decision or fence for that skipped source frame.
                send_frame(2,1,0);flush();
            end
            if(INTERVAL>1) begin
                reset_all();expect_decision(1,0,0);send_frame(1,0,0);flush();
                for(i=1;i<INTERVAL;i=i+1) begin
                    @(negedge clk);#1;sof=1;de=0;time_valid=0;age_cycles=99;
                    @(negedge clk);#1;sof=0;
                    repeat(3) @(negedge clk);
                end
                if(halted || time_unknown || time_stale || frames_seen!=1 || cadence_skipped!=INTERVAL-1)
                    $fatal(1,"FAIL: skipped SOF created time fault/decision");
                // The next chosen frame still has to pass the source ordering
                // check even though intervening nonselected times are ignored.
                @(negedge clk);#1;sof=1;frame_id=2;time_ms=100;time_valid=1;age_cycles=0;
                @(negedge clk);#1;sof=0;repeat(4) @(negedge clk);#1;
                if(!halted || halt_reason!=3) $fatal(1,"FAIL: repeated chosen frame time accepted");
            end
            // Time qualification is at selected SOF, including age==limit.
            reset_all();@(negedge clk);#1;sof=1;frame_id=1;time_ms=100;time_valid=1;age_cycles=21;
            @(negedge clk);#1;sof=0;time_valid=1;age_cycles=0;
            repeat(4) @(negedge clk);#1;
            if(!halted || halt_reason!=2 || time_stale!=1 || time_unknown) $fatal(1,"FAIL: stale SOF rescued by tail");
            reset_all();@(negedge clk);#1;sof=1;time_valid=0;age_cycles=0;
            @(negedge clk);#1;sof=0;repeat(4) @(negedge clk);#1;
            if(!halted || time_unknown!=1 || time_stale) $fatal(1,"FAIL: unknown SOF accepted");
            reset_all();expect_decision(1,0,0);send_frame(1,0,0);flush();
        end
        $display("PASS: history_sample_source W%0d H%0d stride%0d cadence%0d checkedPixels%0d",W,H,S,INTERVAL,pixels_checked);
        test_done=1;
    end
    initial begin #150000000;if(!test_done) $fatal(1,"FAIL: history sampler timeout W%0d phase%0d get%0d put%0d",W,phase,get,put);end
endmodule
module history_sample_source_tb;
    wire a,b,c;
    history_sample_source_case tiny_grid(a);
    history_sample_source_case #(.W(1),.H(1),.S(1),.INTERVAL(1)) one(b);
    history_sample_source_case #(.W(1280),.H(720),.S(4),.INTERVAL(6),.FULL(1)) fullsize(c);
    initial begin wait(a && b && c);$display("PASS: history_sample_source ALL");$finish;end
endmodule
