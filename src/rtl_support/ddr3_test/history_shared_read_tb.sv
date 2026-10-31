`timescale 1ns/1ps
// Real directory + descriptor iterator, behavioral pixel slots. This proves
// reference ownership under concurrent writer churn, NOT an AXI/MIG DMA test.
module history_shared_read_tb #(parameter DMA_MODE=0);
    localparam FP=37,STRIDE=80,BASE=4080;
    reg clk=0,rst=1;
    always #5 clk=~clk;
    reg reserve_valid=0,grant_ready=0,finish_valid=0,finish_ok=1,request_valid=0;
    reg seal_valid=0,release_valid=0;
    wire reserve_ready,grant_valid,grant_ok,finish_ready,request_ready,seal_ready,release_ready,accepted;
    wire [2:0] grant_slot;
    wire [31:0] grant_token;
    reg [2:0] finish_slot=0;
    reg [31:0] finish_token=0;
    reg [95:0] finish_meta=0;
    reg [255:0] request_event=0;
    reg [63:0] seal_time=0;
    reg release_window=0,query_window=0;
    wire accepted_window,query_active,query_closed,query_truncated,query_capture_error;
    wire [6:0] query_slots,protected_slots;
    wire [255:0] query_event;
    wire [2:0] query_slot;
    wire slot_valid;
    wire [95:0] slot_meta;
    wire directory_fault,token_exhausted;
    wire [31:0] reserve_rejected,write_failed;
    history_reference_directory #(.SLOTS(7),.WINDOWS(2),.PRE_MS(100),.POST_MS(100)) directory(
        .protocol_fault(directory_fault),.accepted_token(),.window_token_exhausted(),.release_token(32'd0),.release_done(),.release_ok(),.query_token(),.*);
    reg start_valid=0,out_ready=0;
    wire start_ready,out_valid,done,ok,reader_fault;
    wire [2:0] out_slot;
    wire [95:0] out_meta;
    wire [255:0] out_event;
    wire [31:0] out_index;
    history_descriptor_reader #(.SLOTS(7)) reader(
        .start_slots(query_slots),.start_event(query_event),
        .query_valid(slot_valid),.query_meta(slot_meta),.protocol_fault(reader_fault),.*);
    reg [15:0] pixels[0:6][0:7];
    `include "axi_frame_tb_wires.vh"
    reg wr_start=0,rd_start=0,in_valid=0,in_last=0,dma_out_ready=0;
    reg [29:0] wr_base=0,rd_base=0;
    reg [15:0] in_data=0;
    wire in_ready,wr_busy,wr_done,wr_ok,rd_busy,rd_done,rd_ok;
    wire dma_out_valid,dma_out_sof,dma_out_last;
    wire [15:0] dma_out_data;
    wire [31:0] write_beats,read_beats;
    reg hold_b=0,inject_b=0,inject_r=0;
    generate if(DMA_MODE) begin: actual_dma
        ddr3_axi_frame_dma #(.FRAME_PIXELS(FP)) dma(
            .out_valid(dma_out_valid),.out_data(dma_out_data),.out_sof(dma_out_sof),
            .out_last(dma_out_last),.out_ready(dma_out_ready),.*);
        axi_frame_slave_model memory(.*);
    end endgenerate
    integer i,j,writer_commits=0,read_pixels=0;
    reg first_window,second_window;
    reg [6:0] first_refs,second_refs;
    task automatic frame(input integer stamp);
        reg [2:0] slot;
        reg [31:0] token;
        integer p;
        begin
            @(negedge clk);reserve_valid=1;
            @(posedge clk);while(!reserve_ready) @(posedge clk);
            @(negedge clk);reserve_valid=0;
            wait(grant_valid);@(negedge clk);
            if(!grant_ok || protected_slots[grant_slot]) $fatal(1,"FAIL: no unprotected slot during shared read");
            slot=grant_slot;token=grant_token;
            grant_ready=1;@(negedge clk);grant_ready=0;
            if(DMA_MODE) begin
                wr_base=BASE+slot*STRIDE;wr_start=1;@(negedge clk);wr_start=0;
                for(p=0;p<FP;p=p+1) begin
                    in_valid=1;in_data=stamp+p;in_last=p==FP-1;
                    @(posedge clk);while(!in_ready) @(posedge clk);
                    if(protected_slots[slot]) $fatal(1,"FAIL: AXI writer touched referenced slot");
                    @(negedge clk);
                end
                in_valid=0;in_last=0;
                wait(wr_done);#1;
                if(wr_ok!==!inject_b) $fatal(1,"FAIL: AXI write verdict");
                @(negedge clk);
            end else for(p=0;p<8;p=p+1) begin
                if(protected_slots[slot]) $fatal(1,"FAIL: writer touched referenced slot");
                pixels[slot][p]=stamp+p;
                @(negedge clk);
            end
            // Delayed successful response. Descriptor must remain unpublished.
            repeat(7) @(negedge clk);
            if(directory.valid_slots[slot]) $fatal(1,"FAIL: descriptor published before successful B/finish");
            finish_meta={32'(stamp/50),64'(stamp)};finish_slot=slot;finish_token=token;finish_ok=!inject_b;finish_valid=1;
            @(posedge clk);while(!finish_ready) @(posedge clk);
            @(negedge clk);finish_valid=0;if(!inject_b) writer_commits=writer_commits+1;
        end
    endtask
    task automatic event_at(input integer stamp,input integer uid,output reg handle);
        begin
            @(negedge clk);request_event={32'd1,32'd5,32'd3,64'(uid),64'(stamp),8'd1,8'd0,16'h3750};request_valid=1;
            @(posedge clk);while(!request_ready) @(posedge clk);
            @(negedge clk);request_valid=0;handle=accepted_window;
            repeat(10) @(negedge clk);
        end
    endtask
    task automatic read_window(input handle,input integer uid,input integer first_stamp);
        integer n,p;
        reg [2:0] slot;
        reg [95:0] metadata;
        begin
            query_window=handle;#1;
            if(!query_closed || query_truncated || query_capture_error) $fatal(1,"FAIL: expected fixed retained range");
            start_valid=1;@(posedge clk);while(!start_ready) @(posedge clk);
            @(negedge clk);start_valid=0;
            for(n=0;n<5;n=n+1) begin
                wait(out_valid);#1;slot=out_slot;metadata=out_meta;
                if(out_index!=n || metadata[63:0]!=first_stamp+n*50 || out_event[159:96]!=uid)
                    $fatal(1,"FAIL: wrong original-time/shared descriptor");
                // Pretend a slow downstream pixel consumer. Pin stays held
                // through the entire read, not merely descriptor acceptance.
                if(DMA_MODE) begin
                    @(negedge clk);rd_base=BASE+slot*STRIDE;rd_start=1;
                    @(negedge clk);rd_start=0;
                    for(p=0;p<FP;p=p+1) begin
                        repeat(13) @(negedge clk);
                        dma_out_ready=1;
                        @(posedge clk);while(!dma_out_valid) @(posedge clk);
                        if(!protected_slots[slot] || dma_out_data!=first_stamp+n*50+p || dma_out_sof!=(p==0) || dma_out_last!=(p==FP-1))
                            $fatal(1,"FAIL: shared AXI frame data/ownership/boundary");
                        read_pixels=read_pixels+1;
                        @(negedge clk);dma_out_ready=0;
                    end
                    // R completion can coincide with final pixel handshake.
                    if(!rd_done) wait(rd_done);
                    #1;if(!rd_ok) $fatal(1,"FAIL: AXI read failed");
                end else for(p=0;p<8;p=p+1) begin
                    repeat(13) @(negedge clk);
                    if(!protected_slots[slot] || pixels[slot][p]!=first_stamp+n*50+p || !out_valid || out_meta!==metadata || out_slot!==slot)
                        $fatal(1,"FAIL: protected pixels overwritten under output stall");
                    read_pixels=read_pixels+1;
                end
                out_ready=1;@(negedge clk);out_ready=0;
            end
            if(!done || !ok) $fatal(1,"FAIL: descriptor readout completion");
            // Iterator done alone must never release references.
            repeat(20) @(negedge clk);
            if(query_slots==0) $fatal(1,"FAIL: premature release");
        end
    endtask
    task automatic release_ref(input handle);
        begin
            @(negedge clk);release_window=handle;release_valid=1;
            @(posedge clk);while(!release_ready) @(posedge clk);
            @(negedge clk);release_valid=0;
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        frame(100);frame(150);frame(200);frame(250);frame(300);
        event_at(200,1,first_window);event_at(250,2,second_window);
        frame(350);frame(400);
        @(negedge clk);seal_time=400;seal_valid=1;
        @(posedge clk);while(!seal_ready) @(posedge clk);
        @(negedge clk);seal_valid=0;
        query_window=first_window;#1;first_refs=query_slots;
        query_window=second_window;#1;second_refs=query_slots;
        if($countones(first_refs & second_refs)!=4) $fatal(1,"FAIL: expected four physically shared frames");
        fork
            begin for(i=0;i<120;i=i+1) frame(450+i*50);end
            begin
                read_window(first_window,1,100);release_ref(first_window);
                query_window=second_window;#1;
                if(query_slots!==second_refs || (protected_slots & second_refs)!==second_refs)
                    $fatal(1,"FAIL: release A released shared B frames");
                read_window(second_window,2,150);release_ref(second_window);
            end
        join
        if(protected_slots || directory_fault || reader_fault || reserve_rejected || write_failed || read_pixels!=(DMA_MODE?370:80) || writer_commits!=127)
            $fatal(1,"FAIL: shared reference result");
        $display("PASS: history_shared_read 2 original-time windows/4 shared frames/pixels=%0d/127 commits concurrent writer DMA_MODE=%0d",read_pixels,DMA_MODE);
        if(DMA_MODE) begin
            // Failed AXI B cannot appear in the history set; later successful
            // commit can join the same active window, but its error is retained.
            event_at(6600,3,first_window);
            inject_b=1;frame(6600);inject_b=0;frame(6650);
            @(negedge clk);seal_time=6700;seal_valid=1;
            @(posedge clk);while(!seal_ready) @(posedge clk);
            @(negedge clk);seal_valid=0;query_window=first_window;#1;
            if(!query_capture_error || write_failed!=1 || !query_closed || query_slots==0)
                $fatal(1,"FAIL: failed B/window diagnostic");
            // Read-error completion is NOT permission to release references.
            start_valid=1;@(posedge clk);while(!start_ready) @(posedge clk);
            @(negedge clk);start_valid=0;wait(out_valid);#1;
            if(out_meta[63:0]!=6650) $fatal(1,"FAIL: failed write was published");
            inject_r=1;@(negedge clk);rd_base=BASE+out_slot*STRIDE;rd_start=1;
            @(negedge clk);rd_start=0;dma_out_ready=1;
            wait(rd_done);#1;
            if(rd_ok || !protected_slots[out_slot]) $fatal(1,"FAIL: read failure lost protection/verdict");
            @(negedge clk);dma_out_ready=0;inject_r=0;out_ready=1;
            @(negedge clk);out_ready=0;
            if(!done || !ok || query_slots==0) $fatal(1,"FAIL: iterator incorrectly owns DDR verdict/release");
            release_ref(first_window);
            if(protected_slots) $fatal(1,"FAIL: explicit failed-window release");
            $display("PASS: history_shared_axi failedB excluded/capture_error latched/failedR retains references until explicit release");
        end
        $finish;
    end
    initial begin #2000000;$fatal(1,"FAIL: shared read timeout");end
endmodule
