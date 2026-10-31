`timescale 1ns/1ps
// Real four-source formatter/queue -> bundled CDC -> real evidence pipeline.
// The conservative admission adapter only consumes CDC when a UI queue slot
// is free. It deliberately forgoes same-cycle dispatch credit to avoid coupling
// CDC ready to the pulse-request accepted signal.
module event_cdc_evidence_tb #(parameter SAMPLE_INPUT=0,SHARED_INPUT=0);
    localparam FP=SAMPLE_INPUT ? 40 : 37,DEPTH=2;
    reg clk=0,control_clk=0,cap_clk=0,rst=1,control_rst=1,cap_rst=1;
    always #5 clk=~clk;
    always #10 control_clk=~control_clk;
    always #7 cap_clk=~cap_clk;
    reg [3:0] control_request=0;
    reg [63:0] lane_data=64'h0365036003510350;
    reg [31:0] device_id=32'h12345678,boot_id=32'habcdef01,session_id=32'hfedcba98;
    reg [63:0] source_ms=64'h1234567800000001;
    wire [3:0] source_accepted,source_rejected;
    wire source_valid,source_ready,id_exhausted;
    wire [255:0] source_data;
    wire [2:0] source_occupancy,source_high;
    wire [31:0] source_accept_count,source_reject_count,source_deliver_count;
    event_transaction_queue #(.DEPTH(4)) source_queue(
        .clk(control_clk),.rst(control_rst),.request(control_request),.request_data(lane_data),
        .device_id(device_id),.boot_id(boot_id),.session_id(session_id),.request_time_ms(source_ms),
        .accepted(source_accepted),.rejected(source_rejected),.event_valid(source_valid),.event_ready(source_ready),
        .event_data(source_data),.occupancy(source_occupancy),.high_water(source_high),
        .accepted_count(source_accept_count),.rejected_count(source_reject_count),.delivered_count(source_deliver_count),.id_exhausted(id_exhausted));
    wire cdc_valid,cdc_ready;
    wire [255:0] cdc_data;
    wire [31:0] cdc_accept_count,cdc_deliver_count;
    generate if(SAMPLE_INPUT!=2) begin : separate_bridge
    cdc_event_transaction bridge(
        .src_clk(control_clk),.src_rst(control_rst),.src_valid(source_valid),.src_ready(source_ready),.src_data(source_data),
        .src_accepted_count(cdc_accept_count),.dst_clk(clk),.dst_rst(rst),
        .dst_valid(cdc_valid),.dst_ready(cdc_ready),.dst_data(cdc_data),.dst_delivered_count(cdc_deliver_count));
    end endgenerate
    wire [1:0] occupancy,high_water;
    assign cdc_ready=!rst && occupancy<DEPTH;
    wire request=cdc_valid && cdc_ready;
    wire [255:0] request_data=cdc_data;
    wire accepted,rejected;
    wire pix_valid,pix_sof,pix_last,pix_ready,fifo_full;
    wire [15:0] pix_data;
    wire [95:0] pix_meta;
    reg direct_valid=0,direct_sof=0,direct_last=0;
    reg [15:0] direct_data=0;
    reg [95:0] direct_meta=0;
    reg sample_de=0,sample_sof=0;
    reg [11:0] sample_x=0,sample_y=0;
    reg [15:0] sample_rgb565=0;
    reg [95:0] sample_meta=0;
    generate if(SAMPLE_INPUT==1) begin : sampled_input
        camera_sample_guard #(.SRC_WIDTH(32),.SRC_HEIGHT(20),.SAMPLE_STRIDE(4),.FRAME_INTERVAL(1)) sampler(
            .clk(cap_clk),.rst(cap_rst),.enable(1'b1),.de(sample_de),.sof(sample_sof),.x(sample_x),.y(sample_y),
            .pixel_r({sample_rgb565[15:11],3'b0}),.pixel_g({sample_rgb565[10:5],2'b0}),.pixel_b({sample_rgb565[4:0],3'b0}),
            .frame_meta(sample_meta),.out_valid(pix_valid),.out_sof(pix_sof),.out_last(pix_last),
            .out_data(pix_data),.out_meta(pix_meta),.out_ready(pix_ready),
            .banks_occupied(),.frames_seen(),.frames_buffered(),.frames_sent(),.dropped_busy(),.dropped_invalid(),.dropped_disabled());
    end else begin : direct_input
        assign pix_valid=direct_valid;assign pix_sof=direct_sof;assign pix_last=direct_last;
        assign pix_data=direct_data;assign pix_meta=direct_meta;
    end endgenerate
    wire [31:0] accepted_count,rejected_count,completed_count;
    wire out_valid,out_sof,out_last,out_deferred;
    wire [15:0] out_data;
    wire [95:0] out_meta,commit_meta;
    wire [255:0] out_event,result_event;
    reg out_ready=0,result_ready=0;
    wire result_valid,result_ok,result_deferred,commit_valid;
    wire [2:0] commit_slot;
    wire [31:0] result_frames,frames_committed,frames_failed,windows_completed,read_errors,write_beats,read_beats;
    reg hold_b=0,inject_b=0,inject_r=0;
    `include "axi_frame_tb_wires.vh"
    wire engine_active;
    wire [255:0] engine_event;
    generate if(SAMPLE_INPUT==2) begin : packaged_client
        camera_evidence_client #(.SRC_WIDTH(32),.SRC_HEIGHT(20),.SAMPLE_STRIDE(4),.FRAME_INTERVAL(1),
            .PRE_FRAMES(2),.POST_FRAMES(2),.EVENT_DEPTH(DEPTH),.RING_FRAMES(7),.FIFO_DEPTH(16),.BASE_ADDR(4080)) client(
            .event_valid(source_valid),.event_ready(source_ready),.event_data(source_data),
            .cdc_accepted_count(cdc_accept_count),.cdc_delivered_count(cdc_deliver_count),
            .enable(1'b1),.de(sample_de),.sof(sample_sof),.x(sample_x),.y(sample_y),
            .pixel_r({sample_rgb565[15:11],3'b0}),.pixel_g({sample_rgb565[10:5],2'b0}),.pixel_b({sample_rgb565[4:0],3'b0}),
            .frame_meta(sample_meta),.banks_occupied(),.frames_seen(),.frames_buffered(),.frames_sent(),
            .dropped_busy(),.dropped_invalid(),.dropped_disabled(),.*);
        assign engine_active=client.evidence.dispatcher.active;
        assign engine_event=client.evidence.dispatcher.active_event;
        assign cdc_valid=client.ui_valid;assign cdc_data=client.ui_data;
        assign accepted=request;assign rejected=1'b0;
    end else begin : separate_client
        ddr_evidence_queued #(.FRAME_PIXELS(FP),.EVENT_DEPTH(DEPTH),.RING_FRAMES(7),.FIFO_DEPTH(16),.BASE_ADDR(4080)) dut(.*);
        assign engine_active=dut.dispatcher.active;assign engine_event=dut.dispatcher.active_event;
    end endgenerate
    generate if(SHARED_INPUT) begin : shared_memory
        wire wrfifo_full,rdfifo_empty;
        wire [15:0] rdfifo_dout,wrfifo_wr_cnt,rdfifo_rd_cnt;
        wire [31:0] source_overflow,display_underflow,video_write_beats,video_read_beats,video_published_beats;
        wire [9:0] source_high,display_low;
        wire [3:0] video_fault,protocol_fault;
        wire evidence_buffer_fault;
        wire [63:0] write_grants,read_grants,write_wait_max,read_wait_max;
        // Evidence uses its same existing m_axi_* nets; outer fabric/behavior
        // memory use this nested scope's independent m_axi_* signals.
        wire [3:0] e_awid=m_axi_awid,e_arid=m_axi_arid;
        wire [29:0] e_awaddr=m_axi_awaddr,e_araddr=m_axi_araddr;
        wire [7:0] e_awlen=m_axi_awlen,e_arlen=m_axi_arlen;
        wire [2:0] e_awsize=m_axi_awsize,e_arsize=m_axi_arsize;
        wire [1:0] e_awburst=m_axi_awburst,e_arburst=m_axi_arburst;
        wire e_awvalid=m_axi_awvalid,e_arvalid=m_axi_arvalid;
        wire [127:0] e_wdata=m_axi_wdata;
        wire [15:0] e_wstrb=m_axi_wstrb;
        wire e_wlast=m_axi_wlast,e_wvalid=m_axi_wvalid,e_bready=m_axi_bready,e_rready=m_axi_rready;
        wire e_awready,e_arready,e_wready,e_bvalid,e_rvalid,e_rlast;
        wire [3:0] e_bid,e_rid;
        wire [1:0] e_bresp,e_rresp;
        wire [127:0] e_rdata;
        assign m_axi_awready=e_awready;assign m_axi_arready=e_arready;assign m_axi_wready=e_wready;
        assign m_axi_bid=e_bid;assign m_axi_bresp=e_bresp;assign m_axi_bvalid=e_bvalid;
        assign m_axi_rid=e_rid;assign m_axi_rresp=e_rresp;assign m_axi_rdata=e_rdata;
        assign m_axi_rlast=e_rlast;assign m_axi_rvalid=e_rvalid;
        shared_camera_test_memory traffic(.*);
    end else begin : direct_memory
        axi_frame_slave_model memory(.*);
    end endgenerate
    reg [255:0] events[0:15];
    integer enqueued=0,delivered=0,results=0,pixels=0,frame_pixel=0,window_frame=0,window_index=0;
    integer rejected_sources=0,i,f,p,target;
    reg drain=0,held_valid=0;
    reg [369:0] held;
    reg [31:0] rng=32'hbaddcafe;
    function [95:0] metadata;
        input integer n;
        begin metadata={32'(n),64'h9876543200000000+n*100};end
    endfunction
    always @(posedge control_clk) if(!control_rst) begin
        for(integer lane=0;lane<4;lane=lane+1) begin
            if(source_accepted[lane]) begin
                events[enqueued]={device_id,boot_id,session_id,64'(enqueued+1),source_ms,8'(lane),8'h00,lane_data[lane*16+:16]};
                enqueued=enqueued+1;
            end
            if(source_rejected[lane]) rejected_sources=rejected_sources+1;
        end
    end
    always @(posedge clk) if(!rst) begin
        if(rejected || (request && !accepted)) $fatal(1,"FAIL: CDC pulse lost at UI admission");
        if(accepted) begin
            if(delivered>=enqueued || request_data!==events[delivered]) $fatal(1,"FAIL: CDC changed source transaction/ordering");
            delivered=delivered+1;
        end
        if(held_valid && (!out_valid || {out_event,out_meta,out_data,out_sof,out_last}!==held))
            $fatal(1,"FAIL: CDC evidence output changed while stalled");
        held_valid<=out_valid && !out_ready;held<={out_event,out_meta,out_data,out_sof,out_last};
        if(out_valid && out_ready) begin
            if(out_event!==events[window_index] || out_meta!==metadata(window_index*2+window_frame) ||
                out_data!==16'((window_index*2+window_frame)*103+frame_pixel) ||
                out_sof!==(frame_pixel==0) || out_last!==(frame_pixel==FP-1))
                $fatal(1,"FAIL: CDC evidence UID/time/frame data window=%d frame=%d pixel=%d",window_index,window_frame,frame_pixel);
            pixels=pixels+1;
            if(out_last) begin
                frame_pixel=0;
                if(window_frame==3) begin window_frame=0;window_index=window_index+1;end
                else window_frame=window_frame+1;
            end else frame_pixel=frame_pixel+1;
        end
        if(result_valid && result_ready) begin
            if(result_event!==events[results] || !result_ok || result_frames!=4 || result_deferred!==(results!=0))
                $fatal(1,"FAIL: CDC evidence result lost original identity/deferred status result=%d",results);
            results=results+1;
        end
    end
    always @(negedge clk) if(drain) begin
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};out_ready=rng[0] || rng[1];result_ready=rng[2];
    end
    task pulse_four;
        input [63:0] timestamp;
        begin
            @(negedge control_clk);control_request=15;source_ms=timestamp;
            @(negedge control_clk);control_request=0;source_ms=~timestamp;lane_data=~lane_data;
        end
    endtask
    task good;
        input integer n;
        integer xx,yy;
        begin
            target=frames_committed+1;
            if(SAMPLE_INPUT) begin
                @(negedge cap_clk);sample_sof=1;sample_meta=metadata(n);
                for(yy=0;yy<20;yy=yy+1) begin
                    for(xx=0;xx<32;xx=xx+1) begin
                        sample_de=1;sample_x=xx;sample_y=yy;
                        sample_rgb565=n*103+(yy/4)*8+xx/4;
                        @(negedge cap_clk);sample_sof=0;sample_meta=~metadata(n);
                    end
                    sample_de=0;repeat(4) @(negedge cap_clk);
                end
                sample_de=0;
            end else begin
                for(p=0;p<FP;p=p+1) begin
                    @(negedge cap_clk);direct_valid=1;direct_sof=p==0;direct_last=p==FP-1;
                    direct_data=n*103+p;direct_meta=p==0 ? metadata(n) : ~metadata(n);
                    @(posedge cap_clk);while(!pix_ready) @(posedge cap_clk);
                    @(negedge cap_clk);direct_valid=0;
                end
                direct_sof=0;direct_last=0;
            end
            wait(frames_committed==target);@(negedge clk);
        end
    endtask
    initial begin
        repeat(10) @(negedge control_clk);control_rst=0;
        @(negedge clk);rst=0;@(negedge cap_clk);cap_rst=0;
        good(0);good(1);pulse_four(64'h1234567800000010);
        wait(engine_active);good(2);good(3);
        wait(out_valid && occupancy==2 && cdc_valid && !cdc_ready);
        // Result/output stall fills UI queue. Fourth event remains in CDC.
        // Another four fit in control queue; a subsequent simultaneous four
        // are explicitly rejected there, not silently lost by the CDC bridge.
        pulse_four(64'h2345678900000020);pulse_four(64'h3456789a00000030);
        repeat(20) @(negedge control_clk);
        if(enqueued!=8 || rejected_sources!=4 || source_occupancy!=4 || source_ready || cdc_deliver_count!=3)
            $fatal(1,"FAIL: cross-domain backpressure source/UI accounting accepted=%d rejected=%d",enqueued,rejected_sources);
        drain=1;
        for(i=1;i<8;i=i+1) begin
            wait(engine_active && engine_event===events[i]);
            good(i*2+2);good(i*2+3);
        end
        wait(results==8);wait(source_ready && !source_valid && !cdc_valid);
        repeat(8) @(negedge clk);
        if(pixels!=8*4*FP || frames_committed!=18 || accepted_count!=8 || completed_count!=8 ||
            rejected_count || frames_failed || read_errors || source_accept_count!=8 || source_reject_count!=4 ||
            source_deliver_count!=8 || cdc_accept_count!=8 || cdc_deliver_count!=8)
            $fatal(1,"FAIL: control CDC evidence conservation");
        $display("PASS: event_cdc_evidence four-source accepted8/rejected4 windows8 pixels=%0d original UID/time preserved",pixels);
        if(SAMPLE_INPUT) $display("PASS: camera_event_cdc_evidence RGB grid/whole-frame guard/metadata/transaction/DDR all checks");
        if(SAMPLE_INPUT==2) $display("PASS: camera_evidence_client packaged client all checks");
        if(SHARED_INPUT) $display("PASS: shared_camera_evidence_client FIFO-video/packaged-client/one-memory all checks");
        $finish;
    end
    initial begin #10000000;$fatal(1,"FAIL: event CDC evidence timeout results=%d accepted=%d UI=%d",results,enqueued,delivered);end
endmodule
module camera_event_cdc_evidence_tb;
    event_cdc_evidence_tb #(.SAMPLE_INPUT(1)) integration();
endmodule
module camera_evidence_client_tb;
    event_cdc_evidence_tb #(.SAMPLE_INPUT(2)) integration();
endmodule
module shared_camera_evidence_client_tb;
    event_cdc_evidence_tb #(.SAMPLE_INPUT(2),.SHARED_INPUT(1)) integration();
endmodule

// Nested adapter keeps the evidence master's m_axi_* names isolated from the
// shared memory master's names, avoiding accidental same-name .* loopbacks.
module shared_camera_test_memory(
    input wire clk,rst,
    input wire [3:0] e_awid,e_arid,
    input wire [29:0] e_awaddr,e_araddr,
    input wire [7:0] e_awlen,e_arlen,
    input wire [2:0] e_awsize,e_arsize,
    input wire [1:0] e_awburst,e_arburst,
    input wire e_awvalid,e_arvalid,
    output wire e_awready,e_arready,
    input wire [127:0] e_wdata,
    input wire [15:0] e_wstrb,
    input wire e_wlast,e_wvalid,
    output wire e_wready,
    output wire [3:0] e_bid,e_rid,
    output wire [1:0] e_bresp,e_rresp,
    output wire e_bvalid,e_rvalid,e_rlast,
    output wire [127:0] e_rdata,
    input wire e_bready,e_rready
);
    reg wrfifo_clk=0,rdfifo_clk=0;
    always #7 wrfifo_clk=~wrfifo_clk;
    always #9 rdfifo_clk=~rdfifo_clk;
    reg wr_enable=0,rd_enable=0,wrfifo_clr=1,rdfifo_clr=1,wrfifo_wren=0,rdfifo_rden=0;
    reg [15:0] wrfifo_din=0;
    wire wrfifo_full,rdfifo_empty;
    wire [15:0] rdfifo_dout,wrfifo_wr_cnt,rdfifo_rd_cnt;
    wire [31:0] source_overflow,display_underflow,video_write_beats,video_read_beats,video_published_beats;
    wire [9:0] source_high,display_low;
    wire [3:0] video_fault,protocol_fault;
    wire evidence_buffer_fault;
    wire [63:0] write_grants,read_grants,write_wait_max,read_wait_max;
    `include "axi_frame_tb_wires.vh"
    wire m_axi_awlock,m_axi_arlock;
    wire [3:0] m_axi_awcache,m_axi_arcache,m_axi_awqos,m_axi_arqos;
    wire [2:0] m_axi_awprot,m_axi_arprot;
    wire hold_b=0,inject_b=0,inject_r=0;
    video_memory_fabric #(.WR_END_EXCLUSIVE(512),.RD_END_EXCLUSIVE(512)) fabric(.*);
    axi_frame_slave_model memory(.*);
    integer p,n,display_pixels=0,clear_cycles=0,evidence_read_occupied=0,evidence_write_occupied=0;
    reg pending=0;
    always @(posedge clk) if(!rst && (wrfifo_clr || rdfifo_clr) &&
        ((fabric.arbiter.write_busy && fabric.arbiter.write_owner) ||
         (fabric.arbiter.read_busy && fabric.arbiter.read_owner))) clear_cycles=clear_cycles+1;
    always @(posedge clk) if(!rst) begin
        if(fabric.arbiter.read_busy && fabric.arbiter.read_owner) evidence_read_occupied=evidence_read_occupied+1;
        if(fabric.arbiter.write_busy && fabric.arbiter.write_owner) evidence_write_occupied=evidence_write_occupied+1;
    end
    always @(posedge rdfifo_clk) begin
        if(rst || rdfifo_clr) pending<=0;
        else begin
            pending<=rdfifo_rden;
            if(rdfifo_rden && rdfifo_empty) $fatal(1,"FAIL: shared packaged client display underflow");
            if(pending) begin
                if(rdfifo_dout!==16'((display_pixels%256)^16'h5a7c)) $fatal(1,"FAIL: shared packaged client video corrupted");
                display_pixels=display_pixels+1;
            end
        end
    end
    initial begin
        wait(!rst);repeat(20) @(negedge clk);wrfifo_clr=0;rdfifo_clr=0;wr_enable=1;
        wait(!fabric.video.wclear && !fabric.video.w_source_busy);
        for(p=0;p<256;p=p+1) begin
            @(negedge wrfifo_clk);wrfifo_wren=1;wrfifo_din=p^16'h5a7c;
            @(negedge wrfifo_clk);wrfifo_wren=0;
        end
        wr_enable=0;wait(video_write_beats==32);
        @(negedge wrfifo_clk);wrfifo_clr=1;
        @(negedge wrfifo_clk);wrfifo_clr=0;
        rd_enable=1;
        // Read repeated video epochs during all eight evidence windows. Frame
        // clear occurs while evidence is active without resetting shared AXI.
        for(n=0;n<7;n=n+1) begin
            // Force one local clear to straddle an evidence-owned read, rather
            // than merely assume overlapping traffic happened to cover it.
            if(n==1) wait(fabric.arbiter.read_busy && fabric.arbiter.read_owner);
            @(negedge rdfifo_clk);rdfifo_clr=1;
            @(negedge rdfifo_clk);rdfifo_clr=0;
            wait(!fabric.video.rclear && rdfifo_rd_cnt>=256);
            for(p=0;p<256;p=p+1) begin
                @(negedge rdfifo_clk);rdfifo_rden=1;
                @(negedge rdfifo_clk);rdfifo_rden=0;
            end
        end
        repeat(4) @(negedge rdfifo_clk);
        if(display_pixels!=7*256 || source_overflow || display_underflow || video_fault || protocol_fault || evidence_buffer_fault ||
            !clear_cycles || !evidence_read_occupied || !evidence_write_occupied)
            $fatal(1,"FAIL: shared packaged client video/AXI faults");
        $display("shared packaged camera client concurrent video pixels=%0d PASS",display_pixels);
        $display("shared client overlap evidence_owned_W/R=%0d/%0d clear_cycles=%0d",evidence_write_occupied,evidence_read_occupied,clear_cycles);
    end
endmodule
