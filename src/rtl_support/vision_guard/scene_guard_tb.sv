`timescale 1ns/1ps
module scene_guard_tb;
    reg clk=0; always #5 clk=~clk;
    reg rst=1, sof=0, de=0;
    reg [11:0] x=0,y=0;
    reg [23:0] pixel=0;
    wire covered, frame_is_black, frame_valid;
    camera_black_gate #(.WIDTH(100),.HEIGHT(10),.CONFIRM_FRAMES(3),.RELEASE_FRAMES(2)) gate(.*);
    reg tick=0, face=0, start=0, fp=0;
    reg [15:0] cells=0;
    reg [7:0] luma=120;
    wire [2:0] stage;
    wire [7:0] code;
    wire [3:0] requests;
    exam_fsm #(.SELFCHECK_TICKS(1),.PARALLEL_EVENTS(1)
`ifdef CANDIDATE
        ,.USE_PIXEL_BLACK_GATE(1)
`endif
    ) fsm(.clk(clk),.rst(rst),.tick_1s(tick),.frame_pulse(fp),
        .face_pulse(face),.face_ok(1'b1),.face_id(2'd1),.object_pulse(1'b0),.object_class(3'd0),
        .activity_global(8'd20),.active_cells(cells),.luma_avg(luma),
`ifdef CANDIDATE
        .camera_covered(covered),
`endif
        .gaze_pulse(1'b0),.gaze_away(1'b0),.gaze_present(1'b0),.start_pulse(start),
        .submit_pulse(1'b0),.ack_pulse(1'b0),.timeout_pulse(1'b0),.configured_duration_s(16'd2700),
        .stage_id(stage),.event_code(code),.event_request(requests));
    integer events=0;
    always @(posedge clk) if (!rst && requests[3]) events <= events+1;
    task stats;
        begin @(negedge clk);fp=1;@(negedge clk);fp=0;repeat(2) @(negedge clk);end
    endtask
    task frame;
        input integer blacks, total;
        integer i;
        begin
            for(i=0;i<total;i=i+1) begin
                @(negedge clk);de=1;sof=0;x=i%100;y=i/100;
                pixel=(i<blacks)?24'h101010:24'h808080;
            end
            @(negedge clk);de=0;sof=0;
            @(negedge clk);sof=1;
            @(negedge clk);sof=0;
            stats;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst=0;sof=1;
        @(negedge clk);sof=0;tick=1;
        @(negedge clk);tick=0;face=1;
        @(negedge clk);face=0;start=1;
        @(negedge clk);start=0;
        repeat(3) @(negedge clk);
        if(stage!=3) $fatal(1,"did not enter exam");
        // Original bug: motion alone on a bright frame must not mean cover.
        stats;cells=2000;stats;
        if(events!=0) $fatal(1,"REPRO: bright scene motion falsely emitted 0x64");
        cells=0;luma=40;stats;
        if(events!=0) $fatal(1,"brightness collapse alone falsely emitted 0x64");
        frame(979,1000);frame(979,1000);frame(979,1000);
        if(covered || events!=0 || frame_is_black) $fatal(1,"97.9 percent accepted");
        frame(980,1000);frame(980,1000);
        if(covered || events!=0) $fatal(1,"cover confirmation too early");
        frame(980,1000);
        if(!covered || events!=1) $fatal(1,"98 percent sustained must emit once");
        frame(1000,1000);
        if(events!=1) $fatal(1,"same cover episode repeated");
        frame(0,1000);frame(0,1000);
        if(covered) $fatal(1,"normal frame did not release cover");
        frame(1000,1000);frame(1000,1000);frame(1000,1000);
        if(events!=2) $fatal(1,"second cover episode missing");
        frame(900,900);
        if(frame_valid || covered) $fatal(1,"incomplete frame treated as valid cover");
        // No active image pixels, even if blanking RGB is black.
        frame(0,0);
        if(frame_valid || covered) $fatal(1,"blanking counted as image");
        $display("PASS: scene guard real FSM/motion/dimming/97.9 vs 98/confirmation/release/rearm/incomplete/blanking");
        $finish;
    end
    initial begin #1000000;$fatal(1,"timeout");end
endmodule
