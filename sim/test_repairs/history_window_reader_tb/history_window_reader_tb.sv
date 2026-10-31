`timescale 1ns/1ps
module history_window_reader_case #(parameter FP=37)(output reg test_done=0);
    localparam STRIDE=((FP+7)/8)*16,BASE=4080;
    reg clk=0,rst=1;
    always #5 clk=~clk;
    reg reserve_valid=0,grant_ready=0,finish_valid=0,finish_ok=1;
    wire reserve_ready,grant_valid,grant_ok,finish_ready;
    wire grant_slot;
    wire [31:0] grant_token;
    reg finish_slot=0;
    reg [31:0] finish_token=0;
    reg [95:0] finish_meta=0;
    reg request_valid=0,seal_valid=0;
    reg [255:0] request_event=0;
    reg [63:0] seal_time=0;
    wire request_ready,seal_ready,accepted,accepted_window;
    wire [31:0] accepted_token,query_token;
    wire window_token_exhausted;
    wire query_window,query_slot,query_active,query_closed,query_truncated,query_capture_error;
    wire [1:0] query_slots,protected_slots;
    wire [255:0] query_event;
    wire slot_valid;
    wire [95:0] slot_meta;
    wire directory_fault,token_exhausted;
    wire [31:0] reserve_rejected,write_failed;
    wire release_valid,release_ready,release_window,release_done,release_ok;
    wire [31:0] release_token;
    reg allow_release=1,manual_release=0;
    reg [31:0] manual_token=0;
    wire dir_release_ready;
    assign release_ready=dir_release_ready && allow_release && !manual_release;
    history_reference_directory #(.SLOTS(2),.WINDOWS(1),.ENABLE_WINDOW_TOKENS(1),.PRE_MS(100),.POST_MS(100)) directory(
        .release_valid(manual_release || (release_valid && allow_release)),
        .release_ready(dir_release_ready),.release_window(1'b0),
        .release_token(manual_release ? manual_token : release_token),.protocol_fault(directory_fault),.writer_pending_o(),.active_mask(),.closed_mask(),.*);
    reg command_valid=0,command_window=0;
    reg [31:0] command_token=0;
    wire command_ready;
    wire rd_start,rd_busy,rd_done,rd_ok;
    wire [29:0] rd_base;
    wire dma_valid,dma_sof,dma_last,dma_ready;
    wire [15:0] dma_data;
    wire out_valid,out_sof,out_last;
    wire [15:0] out_data;
    wire [95:0] out_meta;
    wire [255:0] out_event;
    wire [31:0] out_index,result_frames,result_token;
    reg out_ready=0,result_ready=0;
    wire result_valid,result_ok,result_truncated,result_capture_error,result_window;
    wire [2:0] result_code;
    wire done,done_ok,reader_fault;
    reg invalidate_query=0;
    history_window_reader #(.FRAME_PIXELS(FP),.SLOTS(2),.WINDOWS(1),.BASE_ADDR(BASE)) reader(
        .slot_valid(slot_valid && !invalidate_query),.protocol_fault(reader_fault),.*);
    `include "axi_frame_tb_wires.vh"
    reg wr_start=0,in_valid=0,in_last=0;
    reg [29:0] wr_base=0;
    reg [15:0] in_data=0;
    wire in_ready,wr_busy,wr_done,wr_ok;
    wire [31:0] write_beats,read_beats;
    reg hold_b=0,inject_b=0,inject_r=0;
    ddr3_axi_frame_dma #(.FRAME_PIXELS(FP),.BURST(1)) dma(
        .out_valid(dma_valid),.out_sof(dma_sof),.out_last(dma_last),.out_data(dma_data),.out_ready(dma_ready),.*);
    axi_frame_slave_model memory(.*);
    reg [31:0] token,old_token;
    reg [255:0] saved_event;
    integer starts=0;
    always @(posedge clk) if(!rst && rd_start) starts=starts+1;
    task automatic reset_all;
        begin
            @(negedge clk);rst=1;command_valid=0;out_ready=0;result_ready=0;
            manual_release=0;allow_release=1;invalidate_query=0;inject_r=0;
            repeat(4) @(negedge clk);rst=0;starts=0;
        end
    endtask
    task automatic frame(input integer stamp);
        integer p;
        begin
            @(negedge clk);reserve_valid=1;
            @(posedge clk);while(!reserve_ready) @(posedge clk);
            @(negedge clk);reserve_valid=0;wait(grant_valid);#1;
            if(!grant_ok) $fatal(1,"FAIL: fixture reserve");
            finish_slot=grant_slot;finish_token=grant_token;
            @(negedge clk);grant_ready=1;@(negedge clk);grant_ready=0;
            wr_base=BASE+finish_slot*STRIDE;wr_start=1;@(negedge clk);wr_start=0;
            for(p=0;p<FP;p=p+1) begin
                in_valid=1;in_last=p==FP-1;in_data=stamp+p;
                @(posedge clk);while(!in_ready) @(posedge clk);
                @(negedge clk);
            end
            in_valid=0;in_last=0;wait(wr_done);#1;if(!wr_ok) $fatal(1,"FAIL: fixture DMA");
            @(negedge clk);finish_meta={32'(stamp),64'(stamp)};finish_valid=1;
            @(posedge clk);while(!finish_ready) @(posedge clk);
            @(negedge clk);finish_valid=0;
        end
    endtask
    task automatic window_at(input [63:0] t);
        begin
            @(negedge clk);request_event={32'h12345678,32'd5,32'd7,64'hfedcba9876543210,t,8'd1,8'd0,16'h3750};request_valid=1;
            @(posedge clk);while(!request_ready) @(posedge clk);
            @(negedge clk);request_valid=0;
            if(!accepted) $fatal(1,"FAIL: acceptance");
            token=accepted_token;saved_event=request_event;
            repeat(5) @(negedge clk);
        end
    endtask
    task automatic seal_to(input [63:0] t);
        begin
            @(negedge clk);seal_valid=1;seal_time=t;
            @(posedge clk);while(!seal_ready) @(posedge clk);
            @(negedge clk);seal_valid=0;
        end
    endtask
    task automatic start(input [31:0] t);
        begin
            @(negedge clk);command_valid=1;command_token=t;
            @(posedge clk);while(!command_ready) @(posedge clk);
            @(negedge clk);command_valid=0;
        end
    endtask
    task automatic expect_capacity_blocked;
        begin
            @(negedge clk);reserve_valid=1;
            @(posedge clk);while(!reserve_ready) @(posedge clk);
            @(negedge clk);reserve_valid=0;wait(grant_valid);#1;
            if(grant_ok || protected_slots!=3 || !result_valid) $fatal(1,"FAIL: result backpressure allowed overwrite");
            @(negedge clk);grant_ready=1;@(negedge clk);grant_ready=0;
        end
    endtask
    task automatic consume_two;
        integer f,p;
        reg [400:0] held;
        begin
            for(f=0;f<2;f=f+1) for(p=0;p<FP;p=p+1) begin
                wait(out_valid);#1;
                held={out_event,out_meta,out_index,out_data,out_sof};
                repeat(5) begin
                    @(negedge clk);
                    if(!out_valid || {out_event,out_meta,out_index,out_data,out_sof}!==held || protected_slots!=3 || release_valid || result_valid)
                        $fatal(1,"FAIL: backpressured stream changed/released");
                end
                if(out_data!=(f+1)*100+p || out_meta!=={32'((f+1)*100),64'((f+1)*100)} || out_index!=f ||
                   out_sof!=(p==0) || out_last!=(p==FP-1) || out_event!==saved_event) $fatal(1,"FAIL: frame output identity/meta/pixel");
                out_ready=1;@(negedge clk);out_ready=0;
            end
        end
    endtask
    task automatic result(input [2:0] code,input integer frames,input owned);
        reg expected_ok;
        begin
            wait(result_valid);#1;
            expected_ok=(code==0 && !result_truncated && !result_capture_error);
            repeat(20) begin
                @(negedge clk);
                if(!result_valid || result_code!=code || result_frames!=frames || result_ok!==expected_ok || release_valid || command_ready ||
                   (owned && (!query_active || query_token!=token))) $fatal(1,"FAIL: result hold code%0d frames%0d",result_code,result_frames);
            end
            allow_release=0;result_ready=1;@(negedge clk);result_ready=0;
            if(owned) begin
                repeat(20) begin
                    @(negedge clk);
                    if(!release_valid || release_token!=token || !query_active || command_ready || done) $fatal(1,"FAIL: release hold");
                end
                allow_release=1;wait(done);#1;
                if(query_active || done_ok!==expected_ok) $fatal(1,"FAIL: release acknowledgement/result");
            end else if(!done || done_ok) $fatal(1,"FAIL: rejected command released another owner");
        end
    endtask
    integer old_starts;
    initial begin
        reset_all();frame(100);frame(200);window_at(200);
        start(token);result(1,0,0); // open window cannot be read/released
        if(!query_active || !protected_slots) $fatal(1,"FAIL: rejected open window freed");
        seal_to(300);start(token);consume_two();wait(result_valid);expect_capacity_blocked();result(0,2,1);
        if(directory_fault || reader_fault) $fatal(1,"FAIL: good path fault");
        // Successful pixel reads must not hide known time-coverage truncation.
        window_at(150);start(token);consume_two();
        wait(result_valid);#1;
        if(!result_truncated || result_ok) $fatal(1,"FAIL: truncated history reported clean");
        result(0,2,1);
        window_at(200);
        // Fault injection of the directory's accumulated source capture flag;
        // real failed-B capture_error was exercised by history_shared_axi.
        @(negedge clk);directory.capture_error[0]=1;
        start(token);consume_two();wait(result_valid);#1;
        if(!result_capture_error || result_ok) $fatal(1,"FAIL: capture error hidden by good R");
        result(0,2,1);
        old_token=token;window_at(200);
        if(token==old_token) $fatal(1,"FAIL: generation reused");
        // Old release against the reused index is acknowledged as a rejection.
        @(negedge clk);manual_token=old_token;manual_release=1;
        @(posedge clk);while(!dir_release_ready) @(posedge clk);
        @(negedge clk);manual_release=0;#1;
        if(!release_done || release_ok || !query_active || protected_slots!=3) $fatal(1,"FAIL: old release freed new window");
        old_starts=starts;start(old_token);result(1,0,0);
        if(starts!=old_starts || query_token!=token) $fatal(1,"FAIL: stale command read new window");
        inject_r=1;start(token);consume_two();result(4,2,1);inject_r=0;
        // Duplicate release while inactive remains rejected.
        @(negedge clk);manual_token=token;manual_release=1;@(negedge clk);manual_release=0;#1;
        if(!release_done || release_ok) $fatal(1,"FAIL: duplicate release accepted");
        // Empty closed range is not a successful read.
        window_at(1000);seal_to(1100);start(token);result(2,0,1);
        window_at(200);invalidate_query=1;start(token);result(3,0,1);invalidate_query=0;
        // Last generation usable exactly once; no handle wrap at exhaustion.
        @(negedge clk);directory.next_window_token=32'hffffffff;
        window_at(200);if(token!=32'hffffffff || !window_token_exhausted) $fatal(1,"FAIL: token MAX");
        start(token);consume_two();result(0,2,1);
        repeat(10) @(negedge clk);
        if(request_ready) $fatal(1,"FAIL: token exhaustion admitted request");
        // Common reset while an R response/held output is outstanding cancels
        // ownership and iterator; old result/release cannot enter new epoch.
        reset_all();frame(100);frame(200);window_at(200);seal_to(300);start(token);
        wait(out_valid);reset_all();repeat(40) @(negedge clk);
        if(out_valid || result_valid || release_valid || query_active || rd_busy) $fatal(1,"FAIL: old read survived reset");
        frame(100);frame(200);window_at(200);seal_to(300);start(token);consume_two();result(0,2,1);
        if(directory_fault || reader_fault) $fatal(1,"FAIL: recovery faults");
        $display("PASS: history_window_reader FP=%0d realDMA sorted pixels/context/Rfailure/result-release stalls/stale handle/MAX/reset",FP);
        test_done=1;
    end
    initial begin #2000000;$fatal(1,"FAIL: reader coordinator timeout FP%0d state%0d",FP,reader.state);end
endmodule
module history_window_reader_tb;
    wire a,b;
    history_window_reader_case #(.FP(1)) one(a);
    history_window_reader_case #(.FP(37)) tail(b);
    initial begin wait(a && b);$display("PASS: history_window_reader ALL");$finish;end
endmodule
