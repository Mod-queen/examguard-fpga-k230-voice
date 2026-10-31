`timescale 1ns/1ps
module history_capture_source_case #(parameter FP=7,D=8)(output reg done=0);
    localparam IW=FP<2?1:$clog2(FP),CW=$clog2(D+1);
    reg clk=0,rst=1,frame_start=0,frame_end=0,enable=1,time_valid=1,in_valid=0,in_last=0;
    always #5 clk=~clk;
    reg [95:0] in_meta=0;
    reg [IW-1:0] in_index=0;
    reg [15:0] in_data=0;
    wire command_valid,pixel_valid,pixel_last,halted;
    reg command_ready=0,pixel_ready=0,drain=0;
    wire [1:0] command_kind,banks_occupied;
    wire [95:0] command_meta;
    wire [7:0] command_reason;
    wire [15:0] pixel_data;
    wire [2:0] halt_reason;
    wire [CW-1:0] occupancy;
    wire [31:0] frames_seen,frames_published,frames_dropped,decisions_sent;
    history_capture_source #(.FRAME_PIXELS(FP),.DEPTH(D)) dut(.*);
    integer put=0,get=0,phase=0,pix=0,seed=123,stamp=0,i,j;
    reg [1:0] expected_kind[0:511];
    reg [95:0] expected_meta[0:511];
    reg [7:0] expected_reason[0:511];
    reg was_command_stall=0,was_pixel_stall=0;
    reg [105:0] held_command;
    reg [16:0] held_pixel;
    always @(negedge clk) begin
        command_ready=drain && (($random(seed)&3)!=0);
        pixel_ready=drain && (($random(seed)&3)==0);
    end
    always @(posedge clk) begin
        if(rst || halted) begin was_command_stall=0;was_pixel_stall=0;end
        else begin
            if(was_command_stall && (!command_valid || {command_kind,command_meta,command_reason}!==held_command))
                $fatal(1,"FAIL: capture command hold FP%0d D%0d",FP,D);
            if(was_pixel_stall && (!pixel_valid || {pixel_data,pixel_last}!==held_pixel)) $fatal(1,"FAIL: capture pixel hold");
            was_command_stall=command_valid && !command_ready;
            was_pixel_stall=pixel_valid && !pixel_ready;
            held_command={command_kind,command_meta,command_reason};held_pixel={pixel_data,pixel_last};
            if(command_valid && command_ready) begin
                if(get>=put || command_meta!==expected_meta[get]) $fatal(1,"FAIL: capture ordering/meta");
                if(phase==0) begin
                    if(command_kind!==expected_kind[get] || command_reason!==expected_reason[get])
                        $fatal(1,"FAIL: decision FP%0d D%0d entry%0d got%0d/%0d expected%0d/%0d",FP,D,get,command_kind,command_reason,expected_kind[get],expected_reason[get]);
                    phase=command_kind==0?1:2;pix=0;
                end else if(phase==2) begin
                    if(command_kind!=2 || command_reason!=0) $fatal(1,"FAIL: fence order/reason");
                    phase=0;get=get+1;
                end else $fatal(1,"FAIL: fence before pixels");
            end
            if(pixel_valid && pixel_ready) begin
                if(phase!=1 || pixel_data!=expected_meta[get][63:0]+pix || pixel_last!=(pix==FP-1))
                    $fatal(1,"FAIL: source pixel mismatch FP%0d D%0d",FP,D);
                if(pixel_last) phase=2;else pix=pix+1;
            end
        end
    end
    task automatic expect_entry(input [1:0] kind,input [7:0] reason,input integer t);
        begin
            expected_kind[put]=kind;expected_reason[put]=reason;expected_meta[put]={32'(t),64'(t)};put=put+1;
        end
    endtask
    task automatic reset_source;
        begin
            @(negedge clk);#1;rst=1;frame_start=0;frame_end=0;in_valid=0;in_last=0;drain=0;enable=1;time_valid=1;
            repeat(4) @(negedge clk);#1;rst=0;put=0;get=0;phase=0;pix=0;stamp=0;
        end
    endtask
    task automatic start_frame(input integer t,input on,input simultaneous);
        begin
            @(negedge clk);#1;frame_start=1;enable=on;in_meta={32'(t),64'(t)};
            in_valid=simultaneous;in_data=t;in_index=0;in_last=simultaneous && FP==1;
            @(negedge clk);#1;frame_start=0;in_valid=0;in_last=0;
        end
    endtask
    task automatic samples(input integer t,input integer first);
        integer p;
        begin
            for(p=first;p<FP;p=p+1) begin
                @(negedge clk);#1;in_valid=1;in_index=p;in_data=t+p;in_last=p==FP-1;
                @(negedge clk);#1;in_valid=0;in_last=0;
            end
        end
    endtask
    task automatic flush;
        begin
            drain=1;wait(get==put);repeat(8) @(negedge clk);#1;
            if(occupancy || banks_occupied || halted || decisions_sent!=put) $fatal(1,"FAIL: capture drain/count");
            drain=0;
        end
    endtask
    initial begin
        reset_source();
        // Complete packets and same-cycle START/first pixel, non-power sizes.
        for(i=1;i<=40;i=i+1) begin
            expect_entry(0,0,i*100);start_frame(i*100,1,i%2);samples(i*100,i%2);flush();
        end
        if(frames_published!=40 || frames_dropped) $fatal(1,"FAIL: complete source count");
        reset_source();expect_entry(1,1,100);start_frame(100,0,0);flush();
        // Explicit END resolves an incomplete frame, including zero pixels.
        expect_entry(1,5,200);start_frame(200,1,0);
        @(negedge clk);#1;frame_end=1;@(negedge clk);#1;frame_end=0;flush();
        expect_entry(1,3,300);start_frame(300,1,0);
        @(negedge clk);#1;in_valid=1;in_index=0;in_data=300;in_last=FP!=1;
        @(negedge clk);#1;in_valid=0;in_last=0;flush();
        if(D>=3) begin
            reset_source();
            // Two full banks stay occupied while commands are stalled; third
            // frame resolves as busy DROP, never switches to a freed tail bank.
            expect_entry(0,0,100);start_frame(100,1,1);samples(100,1);
            expect_entry(0,0,200);start_frame(200,1,1);samples(200,1);
            expect_entry(1,2,300);start_frame(300,1,1);samples(300,1);flush();
            if(frames_dropped!=1 || frames_published!=2) $fatal(1,"FAIL: bank busy accounting");
            reset_source();
            // Unfinished frame is resolved ahead of the new frame. START and
            // END together refer to the new frame; old frame reason=interrupted.
            expect_entry(1,4,100);start_frame(100,1,0);
            expect_entry(1,5,200);
            @(negedge clk);#1;frame_start=1;frame_end=1;in_meta={32'd200,64'd200};
            @(negedge clk);#1;frame_start=0;frame_end=0;flush();
            if(frames_dropped!=2) $fatal(1,"FAIL: dual decisions accounting");
            reset_source();
            expect_entry(1,4,100);start_frame(100,1,0);
            expect_entry(0,0,200);start_frame(200,1,1);samples(200,1);flush();
            // Continuous producer/consumer overlap, enough headroom deliberately
            // retained for this non-overflow test. Exact expected decisions do
            // not depend on DUT queue RAM or internal state.
            reset_source();drain=1;
            for(i=1;i<=120;i=i+1) begin
                wait(occupancy<D-1 && banks_occupied<2);
                stamp=i*100;
                case(i%3)
                    0: begin expect_entry(0,0,stamp);start_frame(stamp,1,1);samples(stamp,1);end
                    1: begin expect_entry(1,1,stamp);start_frame(stamp,0,0);end
                    2: begin
                        expect_entry(1,3,stamp);start_frame(stamp,1,0);
                        @(negedge clk);#1;in_valid=1;in_index=0;in_data=stamp;in_last=1;
                        @(negedge clk);#1;in_valid=0;in_last=0;
                    end
                endcase
            end
            flush();
            if(frames_seen!=120 || frames_dropped!=80 || frames_published!=40) $fatal(1,"FAIL: concurrent producer accounting");
        end
        reset_source();
        // A queue slot is reserved at START even before outcome is known.
        for(i=1;i<=D;i=i+1) begin expect_entry(1,1,i*100);start_frame(i*100,0,0);end
        start_frame((D+1)*100,0,0);#1;
        if(!halted || halt_reason!=1) $fatal(1,"FAIL: decision overflow not halted");
        drain=1;repeat(30) @(negedge clk);#1;
        if(command_valid || pixel_valid || get) $fatal(1,"FAIL: overflow advanced frontier");
        reset_source();time_valid=0;start_frame(100,1,0);
        if(!halted || halt_reason!=2) $fatal(1,"FAIL: unknown source time accepted");
        reset_source();expect_entry(1,1,100);start_frame(100,0,0);flush();start_frame(100,1,0);
        if(!halted || halt_reason!=3) $fatal(1,"FAIL: duplicate source time accepted");
        reset_source();expect_entry(0,0,100);start_frame(100,1,1);samples(100,1);
        // Cancel a held command and BRAM ownership, then restart low timestamps.
        wait(command_valid);reset_source();expect_entry(0,0,50);start_frame(50,1,1);samples(50,1);flush();
        // Cancel an already offered pixel under backpressure, not only command.
        reset_source();expect_entry(0,0,100);start_frame(100,1,1);samples(100,1);
        drain=1;wait(pixel_valid);@(negedge clk);#1;drain=0;pixel_ready=0;
        repeat(5) @(negedge clk);reset_source();
        expect_entry(0,0,25);start_frame(25,1,1);samples(25,1);flush();
        // MAX is a legal final source time, but cannot be followed by zero.
        reset_source();
        expected_kind[0]=1;expected_reason[0]=1;expected_meta[0]={32'hffffffff,64'hffffffffffffffff};put=1;
        @(negedge clk);#1;frame_start=1;enable=0;in_meta=expected_meta[0];
        @(negedge clk);#1;frame_start=0;flush();start_frame(0,0,0);
        if(!halted || halt_reason!=3) $fatal(1,"FAIL: source MAX time wrapped");
        $display("PASS: history_capture_source FP%0d D%0d FRAME/DROP/FENCE/banks/order/stalls/invalid/interrupted/fullhalt/unknown/reset",FP,D);
        done=1;
    end
    initial begin #2000000;if(!done) $fatal(1,"FAIL: capture source timeout FP%0d D%0d get%0d put%0d",FP,D,get,put);end
endmodule
module history_capture_source_tb;
    wire a,b,c;
    history_capture_source_case #(.FP(1),.D(1)) one(a);
    history_capture_source_case #(.FP(7),.D(3)) seven(b);
    history_capture_source_case #(.FP(37),.D(8)) tail(c);
    initial begin wait(a && b && c);$display("PASS: history_capture_source ALL");$finish;end
endmodule
