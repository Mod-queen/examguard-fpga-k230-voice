`timescale 1ns/1ps
// Same-clock integration: real capture producer -> ordered ingress -> journal
// and actual history store/DMA. No CDC or camera sampler/top claim.
module history_capture_pipeline_tb #(parameter CDC_MODE=0,SAMPLE_MODE=0);
    reg clk=0,cap_clock=0,control_clk=0,arst=1,restart=0;
    always #5 clk=~clk;
    always #7 cap_clock=~cap_clock;
    always #11 control_clk=~control_clk;
    wire cap_clk=CDC_MODE ? cap_clock : clk;
    wire rst,cap_rst,control_rst,cancelled;
    wire [31:0] cancellation_count;
    wire cdc_src_halt,cdc_dst_halt;
    wire source_halted,ingress_halted,journal_halted;
    generate if(CDC_MODE) begin: epoch_mode
        history_stream_epoch epoch(.src_clk(cap_clk),.dst_clk(clk),.control_clk(control_clk),.arst(arst),.restart(restart),
            .src_halt(source_halted || cdc_src_halt),.dst_halt(ingress_halted || journal_halted || cdc_dst_halt),
            .src_rst(cap_rst),.dst_rst(rst),.control_rst(control_rst),.cancelled(cancelled),.cancellation_count(cancellation_count));
    end else begin
        assign rst=arst;assign cap_rst=arst;assign cancelled=0;assign control_rst=arst;assign cancellation_count=0;
    end endgenerate
    reg frame_start=0,frame_end=0,enable=1,time_valid=1,in_valid=0,in_last=0;
    reg [95:0] in_meta=0;
    reg [2:0] in_index=0;
    reg [15:0] in_data=0;
    wire command_valid,command_ready,source_valid,source_last,source_ready;
    wire [1:0] command_kind;
    wire [95:0] command_meta;
    wire [7:0] command_reason;
    wire [15:0] source_data;
    wire [2:0] halt_reason;
    wire [3:0] occupancy;
    wire [1:0] banks_occupied;
    wire [31:0] frames_seen,frames_published,capture_dropped,decisions_sent;
    wire cap_command_valid,cap_command_ready,cap_pixel_valid,cap_pixel_last,cap_pixel_ready;
    wire [1:0] cap_command_kind;
    wire [95:0] cap_command_meta;
    wire [7:0] cap_command_reason;
    wire [15:0] cap_pixel_data;
    reg [11:0] sample_x=0,sample_y=0;
    reg sample_de=0;
    reg [15:0] sample_rgb=0;
    generate if(SAMPLE_MODE) begin: sampled_mode
        history_sample_source #(.SRC_WIDTH(14),.SRC_HEIGHT(2),.SAMPLE_STRIDE(2),.FRAME_INTERVAL(1),.DEPTH(8)) producer(
            .clk(cap_clk),.rst(cap_rst),.enable(enable),.sof(frame_start),
            .de(sample_de || in_valid || frame_end),
            .x(frame_end ? 12'd13 : in_valid ? {8'd0,in_index,1'b0} : sample_x),
            .y(frame_end ? 12'd1 : in_valid ? 12'd0 : sample_y),
            .pixel_r({sample_rgb[15:11],sample_rgb[15:13]}),
            .pixel_g({sample_rgb[10:5],sample_rgb[10:9]}),.pixel_b({sample_rgb[4:0],sample_rgb[4:2]}),
            .frame_id(in_meta[95:64]),.time_ms(in_meta[63:0]),.time_valid(time_valid),.age_cycles(32'd0),
            .source_sofs(),.cadence_skipped(),.time_unknown(),.time_stale(),
            .command_valid(cap_command_valid),.command_ready(cap_command_ready),.command_kind(cap_command_kind),
            .command_meta(cap_command_meta),.command_reason(cap_command_reason),
            .pixel_valid(cap_pixel_valid),.pixel_last(cap_pixel_last),.pixel_data(cap_pixel_data),.pixel_ready(cap_pixel_ready),
            .halted(source_halted),.frames_dropped(capture_dropped),.*);
    end else begin: raw_sample_mode
    history_capture_source #(.FRAME_PIXELS(7),.DEPTH(8)) producer(
        .clk(cap_clk),.rst(cap_rst),
        .command_valid(cap_command_valid),.command_ready(cap_command_ready),.command_kind(cap_command_kind),
        .command_meta(cap_command_meta),.command_reason(cap_command_reason),
        .pixel_valid(cap_pixel_valid),.pixel_last(cap_pixel_last),.pixel_data(cap_pixel_data),.pixel_ready(cap_pixel_ready),
        .halted(source_halted),.frames_dropped(capture_dropped),.*);
    end endgenerate
    generate if(CDC_MODE) begin: cdc_mode
        history_stream_cdc #(.DEPTH(4)) bridge(.src_clk(cap_clk),.src_rst(cap_rst),.dst_clk(clk),.dst_rst(rst),
            .command_valid(cap_command_valid),.command_ready(cap_command_ready),.command_kind(cap_command_kind),
            .command_meta(cap_command_meta),.command_reason(cap_command_reason),
            .pixel_valid(cap_pixel_valid),.pixel_last(cap_pixel_last),.pixel_data(cap_pixel_data),.pixel_ready(cap_pixel_ready),
            .dst_command_valid(command_valid),.dst_command_ready(command_ready),.dst_command_kind(command_kind),
            .dst_command_meta(command_meta),.dst_command_reason(command_reason),
            .dst_pixel_valid(source_valid),.dst_pixel_last(source_last),.dst_pixel_data(source_data),.dst_pixel_ready(source_ready),
            .src_halted(cdc_src_halt),.dst_halted(cdc_dst_halt));
    end else begin
        assign command_valid=cap_command_valid;assign cap_command_ready=command_ready;
        assign command_kind=cap_command_kind;assign command_meta=cap_command_meta;assign command_reason=cap_command_reason;
        assign source_valid=cap_pixel_valid;assign source_last=cap_pixel_last;assign source_data=cap_pixel_data;assign cap_pixel_ready=source_ready;
        assign cdc_src_halt=0;assign cdc_dst_halt=0;
    end endgenerate
    wire frame_valid,frame_ready,frame_fence,pixel_valid,pixel_last,pixel_ready;
    wire [95:0] frame_meta,write_result_meta;
    wire [15:0] pixel_data;
    wire write_result_valid,write_result_ready,fence_done,fence_ok,gap_valid,gap_ready;
    wire [2:0] write_result_code;
    wire [95:0] gap_meta,decision_meta;
    wire [7:0] gap_reason;
    wire [1:0] decision_kind;
    wire [2:0] decision_code;
    wire decision_valid;
    reg decision_ready=1;
    wire [31:0] decisions_completed,gaps_recorded;
    history_ordered_ingress ingress(.result_valid(decision_valid),.result_ready(decision_ready),
        .result_kind(decision_kind),.result_meta(decision_meta),.result_code(decision_code),.halted(ingress_halted),.*);
    reg query_valid=0,query_result_ready=0;
    reg [63:0] query_lower=0,query_upper=0;
    wire query_ready,query_result_valid,result_bad_range,result_unknown;
    wire [31:0] result_count,recorded_count,evicted_count;
    wire [95:0] result_first_meta,result_last_meta;
    wire [7:0] result_first_reason,result_last_reason;
    history_gap_journal #(.DEPTH(8)) journal(.result_valid(query_result_valid),.result_ready(query_result_ready),.halted(journal_halted),.*);
    reg request_valid=0;
    wire request_ready,accepted,accepted_window;
    reg [255:0] request_event=0;
    wire [31:0] accepted_token;
    reg read_valid=0,read_window=0;
    reg [31:0] read_token=0;
    wire read_ready,out_valid,out_sof,out_last;
    wire [15:0] out_data;
    wire [95:0] out_meta;
    wire [255:0] out_event;
    wire [31:0] out_index;
    reg out_ready=0,result_ready=0;
    wire result_valid,result_ok,result_truncated,result_capture_error,result_window,done,done_ok;
    wire [2:0] result_code,faults;
    wire [31:0] result_frames,result_token;
    wire [6:0] protected_slots;
    wire [31:0] frames_committed,frames_dropped,reserve_rejected,write_failed,write_beats,read_beats;
    wire token_exhausted,window_token_exhausted;
    `include "axi_frame_tb_wires.vh"
    reg hold_b=0,inject_b=0,inject_r=0;
    wire dir_seal_valid=1'b0;
    wire dir_seal_ready;
    wire [63:0] dir_seal_time=64'd0;
    wire directory_writer_pending;
    wire [0:0] directory_active_mask,directory_closed_mask;
    history_store_axi #(.FRAME_PIXELS(7),.SLOTS(7),.WINDOWS(1),.PRE_MS(100),.POST_MS(100),.BASE_ADDR(4080),.BURST(1)) store(.*);
    axi_frame_slave_model memory(.*);
    integer decisions=0,fences=0,gaps=0,i,p,stamp;
    reg [63:0] expected_time[0:15];
    reg [1:0] expected_kind[0:15];
    reg [7:0] expected_reason[0:15];
    reg [31:0] token;
    reg check_decisions=1;
    always @(posedge clk) if(!rst && check_decisions) begin
        if(decision_valid && decision_ready) begin
            if(decision_kind==2) begin
                if(decision_meta[63:0]!=expected_time[fences] || fences>=decisions) $fatal(1,"FAIL: source fence overtook decision");
                fences=fences+1;
            end else begin
                if(decision_meta!=={32'(expected_time[decisions]),expected_time[decisions]} || decision_kind!=expected_kind[decisions])
                    $fatal(1,"FAIL: wrong captured decision %0d",decisions);
                decisions=decisions+1;
            end
        end
        if(gap_valid && gap_ready) begin
            if(gap_meta[63:0]!=expected_time[decisions] || gap_reason!=expected_reason[decisions]) $fatal(1,"FAIL: source gap metadata/reason");
            gaps=gaps+1;
        end
        if(source_halted || ingress_halted || journal_halted) $fatal(1,"FAIL: legal pipeline halted");
    end
    task automatic start(input integer t,input on);
        begin
            @(negedge cap_clk);frame_start=1;enable=on;in_meta={32'(t),64'(t)};
            @(negedge cap_clk);frame_start=0;
        end
    endtask
    task automatic frame(input integer t);
        integer k,yy;
        begin
            start(t,1);
            if(SAMPLE_MODE) begin
                for(yy=0;yy<2;yy=yy+1) for(k=0;k<14;k=k+1) begin
                    sample_de=1;sample_x=k;sample_y=yy;sample_rgb=t+k/2;
                    @(negedge cap_clk);
                end
                sample_de=0;
            end else for(k=0;k<7;k=k+1) begin
                in_valid=1;in_index=k;in_last=k==6;in_data=t+k;@(negedge cap_clk);
            end
            in_valid=0;in_last=0;
        end
    endtask
    task automatic query(input [63:0] lo,input [63:0] hi,input integer count);
        begin
            @(negedge clk);query_valid=1;query_lower=lo;query_upper=hi;
            @(posedge clk);while(!query_ready) @(posedge clk);
            @(negedge clk);query_valid=0;wait(query_result_valid);#1;
            if(result_bad_range || result_unknown || result_count!=count) $fatal(1,"FAIL: capture gap query");
            repeat(15) @(negedge clk);query_result_ready=1;@(negedge clk);query_result_ready=0;
        end
    endtask
    initial begin
        expected_time[0]=100;expected_kind[0]=0;expected_reason[0]=0;
        expected_time[1]=200;expected_kind[1]=0;expected_reason[1]=0;
        expected_time[2]=250;expected_kind[2]=0;expected_reason[2]=0;
        expected_time[3]=300;expected_kind[3]=0;expected_reason[3]=0;
        expected_time[4]=350;expected_kind[4]=1;expected_reason[4]=8'h82;
        expected_time[5]=400;expected_kind[5]=1;expected_reason[5]=8'h81;
        expected_time[6]=450;expected_kind[6]=1;expected_reason[6]=8'h83;
        expected_time[7]=500;expected_kind[7]=1;expected_reason[7]=8'h84;
        expected_time[8]=550;expected_kind[8]=1;expected_reason[8]=8'h85;
        expected_time[9]=600;expected_kind[9]=0;expected_reason[9]=2; // actual B failure
        repeat(5) @(negedge clk);arst=0;wait(!rst && !cap_rst);
        frame(100);wait(decisions_completed==2);
        @(negedge clk);request_event={32'd1,32'd5,32'd3,64'd7,64'd200,8'd1,8'd0,16'h3750};request_valid=1;
        @(posedge clk);while(!request_ready) @(posedge clk);
        @(negedge clk);request_valid=0;token=accepted_token;
        hold_b=1;frame(200);wait(m_axi_bready);
        // Source bank200 is free after pixels leave; 250/300 occupy both
        // banks while ingress waits for B, so source350 is a whole-frame DROP.
        frame(250);frame(300);frame(350);start(400,0);
        if(fences!=1 || gaps || banks_occupied!=2) $fatal(1,"FAIL: delayed B source ordering");
        hold_b=0;
        wait(decisions_completed==12);
        if(frames_committed!=4 || gaps!=2 || faults) $fatal(1,"FAIL: real capture/store decisions");
        start(450,1);
        @(negedge cap_clk);in_valid=1;in_index=2;in_data=450;in_last=0;
        @(negedge cap_clk);in_valid=0;
        wait(decisions_completed==14);
        start(500,1);start(550,1);
        @(negedge cap_clk);frame_end=1;@(negedge cap_clk);frame_end=0;
        wait(decisions_completed==18);
        inject_b=1;frame(600);wait(decisions_completed==20);inject_b=0;
        if(gaps!=6 || gaps_recorded!=6 || frames_committed!=4 || frames_dropped!=1 || capture_dropped!=5)
            $fatal(1,"FAIL: capture vs DDR failure accounting");
        query(100,300,0);query(350,600,6);
        if(result_first_meta[63:0]!=350 || result_last_meta[63:0]!=600 || result_first_reason!=8'h82 || result_last_reason!=2)
            $fatal(1,"FAIL: late gap endpoints");
        // Read the original [100..300] window through the actual DMA. Its
        // own refs retained all four good frames despite later capture faults.
        @(negedge clk);read_valid=1;read_token=token;
        @(posedge clk);while(!read_ready) @(posedge clk);
        @(negedge clk);read_valid=0;
        for(i=0;i<4;i=i+1) begin
            case(i) 0:stamp=100;1:stamp=200;2:stamp=250;3:stamp=300;endcase
            for(p=0;p<7;p=p+1) begin
                wait(out_valid);#1;
                if(out_meta!=={32'(stamp),64'(stamp)} || out_event!==request_event || out_index!=i ||
                   out_data!=stamp+p || out_sof!=(p==0) || out_last!=(p==6)) $fatal(1,"FAIL: captured frame readback");
                repeat(3) @(negedge clk);out_ready=1;@(negedge clk);out_ready=0;
            end
        end
        wait(result_valid);#1;
        if(!result_ok || result_frames!=4 || result_code!=0 || result_token!=token) $fatal(1,"FAIL: capture pipeline window result");
        repeat(10) @(negedge clk);result_ready=1;@(negedge clk);result_ready=0;
        wait(done);#1;
        if(!done_ok || protected_slots || occupancy || banks_occupied || decisions!=10 || fences!=10) $fatal(1,"FAIL: capture pipeline conservation");
        $display("PASS: history_capture_pipeline realSource+ingress+journal+store+DMA 4frames28pixels/5sourceDrops/1Bfailure/10orderedFences CDC_MODE=%0d",CDC_MODE);
        if(CDC_MODE) begin
            check_decisions=0;
            // Fill real decision queue while store waits for an actual B.
            // Automatic halt cancels the FIFO, ingress, store AND AXI model.
            hold_b=1;frame(700);wait(m_axi_bready);
            for(i=0;i<20 && !source_halted;i=i+1) start(800+i*50,0);
            wait(cancelled);wait(rst && cap_rst);hold_b=0;
            repeat(20) @(negedge control_clk);
            if(store.wr_busy || result_valid || command_valid || protected_slots || occupancy)
                $fatal(1,"FAIL: source halt failed common cancellation");
            restart=1;@(negedge control_clk);restart=0;wait(!rst && !cap_rst);
            frame(50);wait(decisions_completed==2);
            if(frames_committed!=1 || gaps_recorded || cancellation_count!=1 || store.directory.last_time!=50)
                $fatal(1,"FAIL: cancelled epoch leaked into restart");
            // A valid but unknown timestamp also triggers the same lifecycle.
            time_valid=0;start(100,1);wait(cancelled);wait(rst && cap_rst);
            repeat(20) @(negedge control_clk);time_valid=1;
            restart=1;@(negedge control_clk);restart=0;wait(!rst && !cap_rst);
            frame(25);wait(decisions_completed==2);
            if(frames_committed!=1 || cancellation_count!=2) $fatal(1,"FAIL: unknown time cancellation/recovery");
            $display("PASS: history_capture_cdc_pipeline realSource FIFO4/14ns-to10ns/storeDMA/gaps/fences/queue-overflow-and-unknown-time commonAXIcancel/restart");
        end
        if(SAMPLE_MODE) $display("PASS: history_sample_pipeline RGB14x2 stride2 through CDC/ingress/journal/store/DMA/cancel");
        $finish;
    end
    initial begin #1000000;$fatal(1,"FAIL: capture pipeline timeout cancelled%b resets%b%b sourcehalt%b occupancy%0d decisions%0d writer%0d",cancelled,cap_rst,rst,source_halted,occupancy,decisions_completed,store.writer.state);end
endmodule
