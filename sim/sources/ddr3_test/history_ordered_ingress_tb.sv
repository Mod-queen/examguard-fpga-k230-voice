`timescale 1ns/1ps
// Decision producer and gap sink are test fixtures. Actual ingress + full store
// + frame DMA + independent AXI memory, no internal write handshake scripting.
module history_ordered_ingress_tb;
    reg clk=0,rst=1;
    always #5 clk=~clk;
    reg command_valid=0;
    wire command_ready;
    reg [1:0] command_kind=0;
    reg [95:0] command_meta=0;
    reg [7:0] command_reason=0;
    reg source_valid=0,source_last=0;
    reg [15:0] source_data=0;
    wire source_ready,frame_valid,frame_ready,frame_fence,pixel_valid,pixel_last,pixel_ready;
    wire [95:0] frame_meta,write_result_meta;
    wire [15:0] pixel_data;
    wire write_result_valid,write_result_ready,fence_done,fence_ok;
    wire [2:0] write_result_code;
    wire gap_valid,result_valid,halted;
    reg permit_gap=0,result_ready=0;
    wire gap_ready,journal_ready;
    assign gap_ready=permit_gap && journal_ready;
    wire [95:0] gap_meta,result_meta;
    wire [7:0] gap_reason;
    wire [1:0] result_kind;
    wire [2:0] result_code;
    wire [31:0] decisions_completed,gaps_recorded;
    history_ordered_ingress ingress(.*);
    wire journal_halted;
    wire [31:0] journal_recorded,journal_evicted;
    reg journal_query=0,journal_result_ready=0;
    wire journal_query_ready,journal_result_valid,journal_unknown,journal_bad;
    wire [31:0] journal_count;
    wire [95:0] journal_first,journal_last;
    wire [7:0] journal_first_reason,journal_last_reason;
    history_gap_journal #(.DEPTH(4)) journal(.clk(clk),.rst(rst),
        .gap_valid(gap_valid && permit_gap),.gap_ready(journal_ready),.gap_meta(gap_meta),.gap_reason(gap_reason),
        .query_valid(journal_query),.query_ready(journal_query_ready),.query_lower(64'd0),.query_upper(64'd300),
        .result_valid(journal_result_valid),.result_ready(journal_result_ready),.result_bad_range(journal_bad),.result_unknown(journal_unknown),
        .result_count(journal_count),.result_first_meta(journal_first),.result_last_meta(journal_last),
        .result_first_reason(journal_first_reason),.result_last_reason(journal_last_reason),
        .halted(journal_halted),.recorded_count(journal_recorded),.evicted_count(journal_evicted));
    reg request_valid=0;
    reg [255:0] request_event=0;
    wire request_ready,accepted,accepted_window;
    wire [31:0] accepted_token;
    wire [1:0] protected_slots;
    wire [2:0] faults;
    wire [31:0] frames_committed,frames_dropped,reserve_rejected,write_failed,write_beats,read_beats;
    `include "axi_frame_tb_wires.vh"
    reg hold_b=0,inject_b=0,inject_r=0;
    wire dir_seal_valid=1'b0;
    wire dir_seal_ready;
    wire [63:0] dir_seal_time=64'd0;
    wire directory_writer_pending;
    wire [0:0] directory_active_mask,directory_closed_mask;
    history_store_axi #(.FRAME_PIXELS(37),.SLOTS(2),.WINDOWS(1),.PRE_MS(100),.POST_MS(100),.BASE_ADDR(4080),.BURST(1)) store(
        .read_valid(1'b0),.read_ready(),.read_window(1'b0),.read_token(32'd0),
        .out_valid(),.out_sof(),.out_last(),.out_data(),.out_meta(),.out_event(),.out_index(),.out_ready(1'b0),
        .result_valid(),.result_ready(1'b0),.result_code(),.result_ok(),.result_truncated(),.result_capture_error(),
        .result_frames(),.result_token(),.result_window(),.done(),.done_ok(),.token_exhausted(),.window_token_exhausted(),.*);
    axi_frame_slave_model memory(.*);
    // Independent receipt scoreboard: record only handshaken gaps, not valids.
    integer gap_count=0,seals=0,aw_before;
    reg [95:0] gap_log[0:15];
    reg [7:0] reason_log[0:15];
    always @(posedge clk) if(!rst) begin
        if(gap_valid && gap_ready) begin
            gap_log[gap_count]=gap_meta;reason_log[gap_count]=gap_reason;gap_count=gap_count+1;
        end
        if(store.seal_valid && store.seal_ready) begin
            if(gap_valid || store.wr_busy) $fatal(1,"FAIL: fence overtook gap/B");
            seals=seals+1;
        end
    end
    task automatic reset_all;
        begin
            @(negedge clk);rst=1;command_valid=0;source_valid=0;source_last=0;request_valid=0;
            permit_gap=0;result_ready=0;hold_b=0;inject_b=0;
            repeat(4) @(negedge clk);rst=0;gap_count=0;seals=0;
        end
    endtask
    task automatic command(input [1:0] kind,input [63:0] stamp,input [7:0] reason);
        begin
            @(negedge clk);command_valid=1;command_kind=kind;command_meta={32'h12345678,stamp};command_reason=reason;
            @(posedge clk);while(!command_ready) @(posedge clk);
            @(negedge clk);command_valid=0;
        end
    endtask
    task automatic pixels(input integer n,input integer base);
        integer p;
        begin
            for(p=0;p<n;p=p+1) begin
                @(negedge clk);source_valid=1;source_last=p==n-1;source_data=base+p;
                @(posedge clk);while(!source_ready) @(posedge clk);
                @(negedge clk);source_valid=0;source_last=0;
            end
        end
    endtask
    task automatic result(input [1:0] kind,input [63:0] stamp,input [2:0] code);
        begin
            wait(result_valid);#1;
            repeat(17) begin
                @(negedge clk);
                if(!result_valid || command_ready || result_kind!=kind || result_meta!=={32'h12345678,stamp} || result_code!=code)
                    $fatal(1,"FAIL: ordered result unstable");
            end
            result_ready=1;@(negedge clk);result_ready=0;
        end
    endtask
    task automatic gap(input [63:0] stamp,input [7:0] reason);
        begin
            wait(gap_valid);#1;
            repeat(23) begin
                @(negedge clk);
                if(!gap_valid || gap_meta!=={32'h12345678,stamp} || gap_reason!=reason || command_ready || result_valid || frame_valid)
                    $fatal(1,"FAIL: gap not held before frontier");
            end
            permit_gap=1;@(posedge clk);while(!gap_ready) @(posedge clk);
            @(negedge clk);permit_gap=0;
        end
    endtask
    initial begin
        reset_all();hold_b=1;command(0,100,0);
        fork
            pixels(37,1000);
            begin wait(m_axi_bready);repeat(30) @(negedge clk);
                if(result_valid || gap_valid) $fatal(1,"FAIL: outcome before B");hold_b=0;end
        join
        result(0,100,0);
        if(frames_committed!=1 || gap_count) $fatal(1,"FAIL: good frame gap");
        // Source drop has no pixels or DDR traffic, and cannot be bypassed by
        // a queued fence while the external gap sink is stalled.
        aw_before=memory.aw_count;command(1,150,7);
        @(negedge clk);command_valid=1;command_kind=2;command_meta={32'h12345678,64'd150};
        gap(150,8'h87);result(1,150,0);
        @(posedge clk);while(!command_ready) @(posedge clk);
        @(negedge clk);command_valid=0;result(2,150,0);
        if(seals!=1 || gap_count!=1 || memory.aw_count!=aw_before || reason_log[0]!=8'h87) $fatal(1,"FAIL: drop/fence order");
        // Hold a real journal query result while a new source drop is pending.
        // permit_gap alone cannot acknowledge it; journal backpressure must
        // propagate all the way to the next frame/fence command.
        @(negedge clk);journal_query=1;
        @(posedge clk);while(!journal_query_ready) @(posedge clk);
        @(negedge clk);journal_query=0;wait(journal_result_valid);
        command(1,175,8);
        @(negedge clk);permit_gap=1;
        repeat(25) begin
            @(negedge clk);
            if(!gap_valid || gap_ready || command_ready || result_valid || journal_count!=1)
                $fatal(1,"FAIL: journal query did not backpressure new gap");
        end
        journal_result_ready=1;@(negedge clk);journal_result_ready=0;
        @(posedge clk);while(!gap_ready) @(posedge clk);
        @(negedge clk);permit_gap=0;result(1,175,0);
        inject_b=1;command(0,200,0);pixels(37,2000);gap(200,2);result(0,200,2);inject_b=0;
        command(0,250,0);pixels(5,2500);gap(250,3);result(0,250,3);
        command(0,300,0);pixels(42,3000);gap(300,3);result(0,300,3);
        if(gap_count!=5 || gaps_recorded!=5 || frames_dropped!=3 || halted) $fatal(1,"FAIL: failed frames gaps");
        // Query the REAL bounded sink for a late event after all decisions.
        @(negedge clk);journal_query=1;
        @(posedge clk);while(!journal_query_ready) @(posedge clk);
        @(negedge clk);journal_query=0;wait(journal_result_valid);#1;
        if(journal_count!=4 || !journal_unknown || journal_bad || journal_halted || journal_recorded!=5 || journal_evicted!=1 ||
           journal_first[63:0]!=175 || journal_last[63:0]!=300 || journal_first_reason!=8'h88 || journal_last_reason!=3)
            $fatal(1,"FAIL: late query lost recorded failed/drop decisions");
        @(negedge clk);journal_result_ready=1;@(negedge clk);journal_result_ready=0;
        // Reset cancels both held gap and queued fence. No old outcome replay.
        command(1,350,1);wait(gap_valid);reset_all();repeat(30) @(negedge clk);
        if(gap_valid || result_valid || frame_valid || gaps_recorded) $fatal(1,"FAIL: reset replay");
        // All slots protected: writer's capacity failure is recorded too.
        command(0,100,0);pixels(37,100);result(0,100,0);
        command(0,150,0);pixels(37,150);result(0,150,0);
        @(negedge clk);request_event={32'd1,32'd5,32'd3,64'd1,64'd150,8'd1,8'd0,16'h3750};request_valid=1;
        @(posedge clk);while(!request_ready) @(posedge clk);
        @(negedge clk);request_valid=0;repeat(5) @(negedge clk);
        aw_before=memory.aw_count;command(0,200,0);pixels(37,200);gap(200,1);result(0,200,1);
        if(memory.aw_count!=aw_before || protected_slots!=3 || gap_count!=1) $fatal(1,"FAIL: capacity gap/overwrite");
        command(2,250,0);result(2,250,0);
        // Reordered decisions fail closed, preventing false seals; no fake
        // historical point gap can repair already-passed frontier ordering.
        command(1,200,1);repeat(10) @(negedge clk);
        if(!halted || command_ready || frame_valid || gap_valid) $fatal(1,"FAIL: old drop accepted");
        reset_all();command(2,64'hffffffffffffffff,0);result(2,64'hffffffffffffffff,0);
        command(2,64'hffffffffffffffff,0);result(2,64'hffffffffffffffff,0);
        command(0,0,0);repeat(10) @(negedge clk);if(!halted) $fatal(1,"FAIL: MAX fence wrap");
        reset_all();command(3,100,0);repeat(10) @(negedge clk);if(!halted) $fatal(1,"FAIL: unknown kind accepted");
        reset_all();command(1,100,2);gap(100,8'h82);result(1,100,0);
        command(2,99,0);repeat(10) @(negedge clk);if(!halted) $fatal(1,"FAIL: backward fence accepted");
        // A corrupted write-result identity must halt rather than journal the
        // wrong timestamp and then let a later fence certify that history.
        reset_all();command(0,100,0);pixels(37,100);
        wait(write_result_valid);force ingress.write_result_meta=96'd0;
        @(posedge clk);@(negedge clk);release ingress.write_result_meta;
        repeat(5) @(negedge clk);
        if(!halted || gap_valid || result_valid || frame_valid) $fatal(1,"FAIL: mismatched result context not halted");
        $display("PASS: history_ordered_ingress actualStore FRAME/DROP/FENCE B-error/shape/capacity gaps held before fence/order/MAX/reset");$finish;
    end
    initial begin #2000000;$fatal(1,"FAIL: ingress timeout state%0d storeW%0d",ingress.state,store.writer.state);end
endmodule
