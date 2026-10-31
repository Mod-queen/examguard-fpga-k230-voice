`timescale 1ns/1ps

// Exact new synthesizable fabric, board FIFO IP models, 720p-sized image and
// 1650x750 line scheduling at ~74.25MHz. Memory remains an AXI behavior model,
// NOT MIG. Repeated image intentionally does NOT test tearing/frame ownership.
module video_memory_fabric_tb #(parameter PACKET_MODE=0);
`ifdef FABRIC_SMOKE
    localparam WIDTH=1280,HEIGHT=4,HTOTAL=1650,VTOTAL=750;
`else
    localparam WIDTH=1280,HEIGHT=720,HTOTAL=1650,VTOTAL=750;
`endif
    localparam FRAME_PIXELS=WIDTH*HEIGHT,FRAME_BYTES=FRAME_PIXELS*2;
    localparam EBASE=2097152,FP=PACKET_MODE ? 320*180 : 269;
    reg clk=0,rst=1,wrfifo_clk=0,rdfifo_clk=0,cap_clk=0,cap_rst=1;
    always #5 clk=~clk;
    always #6.734 wrfifo_clk=~wrfifo_clk;
    always #6.734 rdfifo_clk=~rdfifo_clk;
    always #7 cap_clk=~cap_clk;
    reg control_clk=0,eth_clk=0;
    always #10 control_clk=~control_clk;
    always #4 eth_clk=~eth_clk;
    reg arst=1;
    wire [3:0] reset_domains;
    evidence_reset_barrier reset_barrier(.arst(arst),.clocks({eth_clk,clk,rdfifo_clk,control_clk}),.resets(reset_domains));
    wire packet_ui_rst=reset_domains[2],packet_cap_rst=reset_domains[1],packet_control_rst=reset_domains[0],packet_eth_rst=reset_domains[3];
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
    wire [3:0] e_awid,e_arid,e_bid,e_rid;
    wire [29:0] e_awaddr,e_araddr;
    wire [7:0] e_awlen,e_arlen;
    wire [2:0] e_awsize,e_arsize;
    wire [1:0] e_awburst,e_arburst,e_bresp,e_rresp;
    wire e_awvalid,e_awready,e_arvalid,e_arready,e_wlast,e_wvalid,e_wready,e_bvalid,e_bready,e_rvalid,e_rlast,e_rready;
    wire [127:0] e_wdata,e_rdata;
    wire [15:0] e_wstrb;
    wire fabric_rst=PACKET_MODE ? packet_ui_rst : rst;
    video_memory_fabric #(.WR_END_EXCLUSIVE(FRAME_BYTES),.RD_END_EXCLUSIVE(FRAME_BYTES)) dut(.rst(fabric_rst),.*);
    reg hold_b=0;
    wire inject_b=0,inject_r=0;
    // Every referenced pixel is fully written before read, so avoid initializing
    // 2MiB of unused sentinel bytes in this large-frame simulation.
    // aresetn-model cancellation is shared with both masters/arbiter, while the
    // memory bytes survive. This is an AXI interface model, not MIG calibration.
    axi_frame_slave_model #(.MEM_BYTES(EBASE+7*115200+8192),.INITIALIZE(0)) memory(.rst(fabric_rst),.*);
    reg pix_valid=0,pix_sof=0,pix_last=0,request=0;
    reg [15:0] pix_data=0;
    reg [95:0] pix_meta=0;
    reg [255:0] request_data=0;
    wire pix_ready,fifo_full,accepted,rejected;
    wire [2:0] occupancy,high_water;
    wire [31:0] accepted_count,rejected_count,completed_count;
    wire out_valid,out_sof,out_last,out_deferred,result_valid,result_ok,result_deferred,commit_valid;
    wire [15:0] out_data;
    wire [95:0] out_meta,commit_meta;
    wire [255:0] out_event,result_event;
    wire [31:0] result_frames,frames_committed,frames_failed,windows_completed,read_errors,write_beats,read_beats;
    wire [2:0] commit_slot;
    reg out_ready=0;
    wire packet_result_ready;
    reg tap_de=0,tap_sof=0;
    reg [11:0] tap_x=0,tap_y=0;
    reg [15:0] tap_rgb=0;
    wire event_ready;
    wire [31:0] packet_sent,packet_results,udp_sent,udp_dropped;
    wire packet_fault,udp_fault;
    reg hold_network=0;
    reg network_qualified=1;
    integer offline_display_pixels=0;
    always @(posedge rdfifo_clk) if(PACKET_MODE==2 && !network_qualified && rdfifo_rden && !rdfifo_empty)
        offline_display_pixels=offline_display_pixels+1;
    wire tx_start,tx_done,payload_req;
    wire [15:0] tx_length;
    wire [7:0] payload_data,gmii_data;
    wire gmii_en,gmii_clk;
    integer net_fd,meta_fd,wire_packets=0,network_stalls=0,stalled_display_pixels=0;
    integer source_pixels=0,display_pixels=0,display_epoch_pixels=0,display_epoch=0;
    reg previous_en=0;
    reg [63:0] control_time=64'h1234567800000000;
    always @(posedge control_clk) if(!packet_control_rst) control_time<=control_time+1;
    generate if(PACKET_MODE) begin: packet_mode
        camera_evidence_transport #(.SRC_WIDTH(1280),.SRC_HEIGHT(720),.SAMPLE_STRIDE(4),.FRAME_INTERVAL(1),
            .PRE_FRAMES(1),.POST_FRAMES(1),.RING_FRAMES(7),.EVENT_DEPTH(4),.BASE_ADDR(EBASE),.REQUIRE_TX_QUALIFIED(1)) transport(
            .clk(clk),.rst(packet_ui_rst),.control_clk(control_clk),.control_rst(packet_control_rst),.cap_clk(rdfifo_clk),.cap_rst(packet_cap_rst),
            .eth_clk(eth_clk),.eth_rst(packet_eth_rst),.control_time_ms(control_time),.event_valid(request),.event_data(request_data),.event_ready(event_ready),
            .tx_qualified(network_qualified),
            .enable(1'b1),.de(tap_de),.sof(tap_sof),.x(tap_x),.y(tap_y),
            .pixel_r({tap_rgb[15:11],tap_rgb[15:13]}),.pixel_g({tap_rgb[10:5],tap_rgb[10:9]}),.pixel_b({tap_rgb[4:0],tap_rgb[4:2]}),
            .frame_id(32'(display_epoch)),.rejected_unknown(),.rejected_stale(),.frames_committed(frames_committed),.frames_failed(frames_failed),.read_errors(read_errors),
            .packets_sent(packet_sent),.results_sent(packet_results),.udp_packets_sent(udp_sent),.udp_packets_dropped(udp_dropped),.packet_fault(packet_fault),.udp_fault(udp_fault),
            .tx_en_pulse(tx_start),.data_length(tx_length),.payload_data(payload_data),.payload_req(payload_req),.tx_done(tx_done),
            .m_axi_awid(e_awid),.m_axi_awaddr(e_awaddr),.m_axi_awlen(e_awlen),.m_axi_awsize(e_awsize),.m_axi_awburst(e_awburst),.m_axi_awvalid(e_awvalid),.m_axi_awready(e_awready),
            .m_axi_wdata(e_wdata),.m_axi_wstrb(e_wstrb),.m_axi_wlast(e_wlast),.m_axi_wvalid(e_wvalid),.m_axi_wready(e_wready),
            .m_axi_bid(e_bid),.m_axi_bresp(e_bresp),.m_axi_bvalid(e_bvalid),.m_axi_bready(e_bready),
            .m_axi_arid(e_arid),.m_axi_araddr(e_araddr),.m_axi_arlen(e_arlen),.m_axi_arsize(e_arsize),.m_axi_arburst(e_arburst),.m_axi_arvalid(e_arvalid),.m_axi_arready(e_arready),
            .m_axi_rid(e_rid),.m_axi_rdata(e_rdata),.m_axi_rresp(e_rresp),.m_axi_rlast(e_rlast),.m_axi_rvalid(e_rvalid),.m_axi_rready(e_rready));
        // Pause before start, not mid-Ethernet-frame. Hold start pulse until
        // network resumes; UDP bridge naturally retains all bytes/ownership.
        reg pending_start=0;
        wire eth_start=network_qualified && !hold_network && (pending_start || tx_start);
        always @(posedge eth_clk) begin
            if(packet_eth_rst || !network_qualified) pending_start<=0;
            else if(tx_start && hold_network) pending_start<=1;
            else if(eth_start) pending_start<=0;
            if(pending_start && hold_network) network_stalls=network_stalls+1;
        end
        always @(posedge rdfifo_clk) if(!packet_cap_rst && tap_sof && transport.frame_enable) begin
            $fwrite(meta_fd,"%0d %016x\n",display_epoch,transport.frame_meta[63:0]);$fflush(meta_fd);
        end
        eth_udp_tx_gmii ethernet(.clk125m(eth_clk),.reset_p(packet_eth_rst || !network_qualified),.tx_en_pulse(eth_start),.tx_done(tx_done),
            .dst_mac(48'hffffffffffff),.src_mac(48'h020000000002),.dst_ip(32'hc0a80003),.src_ip(32'hc0a80002),.dst_port(16'd6102),.src_port(16'd5000),
            .data_length(tx_length),.payload_req_o(payload_req),.payload_dat_i(payload_data),.gmii_tx_clk(gmii_clk),.gmii_txen(gmii_en),.gmii_txd(gmii_data));
        always @(posedge eth_clk) begin
            if(packet_eth_rst) previous_en<=0;
            else begin
                previous_en<=gmii_en;
                if(gmii_en) $fwrite(net_fd,"%02x",gmii_data);
                if(previous_en && !gmii_en) begin $fwrite(net_fd,"\n");$fflush(net_fd);wire_packets=wire_packets+1;end
            end
        end
    end else begin: legacy_mode
    ddr_evidence_queued #(.FRAME_PIXELS(FP),.RING_FRAMES(7),.FIFO_DEPTH(16),.BASE_ADDR(EBASE)) evidence (
        .clk(clk),.rst(rst),.cap_clk(cap_clk),.cap_rst(cap_rst),
        .pix_valid(pix_valid),.pix_sof(pix_sof),.pix_last(pix_last),.pix_data(pix_data),.pix_meta(pix_meta),.pix_ready(pix_ready),.fifo_full(fifo_full),
        .request(request),.request_data(request_data),.accepted(accepted),.rejected(rejected),.occupancy(occupancy),.high_water(high_water),
        .accepted_count(accepted_count),.rejected_count(rejected_count),.completed_count(completed_count),
        .out_valid(out_valid),.out_sof(out_sof),.out_last(out_last),.out_data(out_data),.out_meta(out_meta),.out_event(out_event),.out_deferred(out_deferred),.out_ready(out_ready),
        .result_valid(result_valid),.result_ready(1'b1),.result_ok(result_ok),.result_deferred(result_deferred),.result_event(result_event),.result_frames(result_frames),
        .commit_valid(commit_valid),.commit_slot(commit_slot),.commit_meta(commit_meta),
        .frames_committed(frames_committed),.frames_failed(frames_failed),.windows_completed(windows_completed),.read_errors(read_errors),.write_beats(write_beats),.read_beats(read_beats),
        .m_axi_awid(e_awid),.m_axi_awaddr(e_awaddr),.m_axi_awlen(e_awlen),.m_axi_awsize(e_awsize),.m_axi_awburst(e_awburst),.m_axi_awvalid(e_awvalid),.m_axi_awready(e_awready),
        .m_axi_wdata(e_wdata),.m_axi_wstrb(e_wstrb),.m_axi_wlast(e_wlast),.m_axi_wvalid(e_wvalid),.m_axi_wready(e_wready),
        .m_axi_bid(e_bid),.m_axi_bresp(e_bresp),.m_axi_bvalid(e_bvalid),.m_axi_bready(e_bready),
        .m_axi_arid(e_arid),.m_axi_araddr(e_araddr),.m_axi_arlen(e_arlen),.m_axi_arsize(e_arsize),.m_axi_arburst(e_arburst),.m_axi_arvalid(e_arvalid),.m_axi_arready(e_arready),
        .m_axi_rid(e_rid),.m_axi_rdata(e_rdata),.m_axi_rresp(e_rresp),.m_axi_rlast(e_rlast),.m_axi_rvalid(e_rvalid),.m_axi_rready(e_rready));
    end endgenerate
    function [15:0] pattern;
        input integer x,y;
        begin pattern=(y*WIDTH+x)^16'h5a7c;end
    endfunction
    function [255:0] ident;
        input integer uid;
        begin ident={32'h1234,32'h5678,32'h9abc,64'(uid),64'h1234567800001000+uid,32'h0350};end
    endfunction
    function [95:0] meta;
        input integer f;
        begin meta={32'(f),64'h8765432100000000+f*100};end
    endfunction
    integer source_blocked=0;
    reg display_pending=0;
    integer expected_index=0,source_active_high=0,display_active_low=512;
    integer errors=0,evidence_pixels=0,evidence_frames=0,results=0;
    integer video_wait_w=0,video_wait_r=0,evidence_wait_w=0,evidence_wait_r=0;
    reg [31:0] rng=32'h7654ab;
    reg concurrent=0;
    always @(negedge clk) begin rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};out_ready<=rng[0];end
    always @(posedge wrfifo_clk) if(!rst && wrfifo_wren) begin
        source_pixels=source_pixels+1;
        if(dut.video.wreset || dut.video.w_source_busy) source_blocked=source_blocked+1;
        if(wrfifo_wr_cnt>source_active_high) source_active_high=wrfifo_wr_cnt;
    end
    always @(posedge rdfifo_clk) begin
        tap_de<=0;tap_sof<=0;
        if(PACKET_MODE && hold_network && display_epoch>=3 && rdfifo_rden && !rdfifo_empty)
            stalled_display_pixels=stalled_display_pixels+1;
        if(rst || rdfifo_clr) display_pending<=0;
        else begin
            display_pending<=rdfifo_rden && !rdfifo_empty;
            if(rdfifo_rden && rdfifo_empty) begin
                errors=errors+1;
                if(errors<4) $display("DEADLINE_MISS epoch=%0d pixel=%0d FIFO=%0d",display_epoch,display_epoch_pixels,rdfifo_rd_cnt);
            end
            if(rdfifo_rden && rdfifo_rd_cnt<display_active_low) display_active_low=rdfifo_rd_cnt;
            if(display_pending) begin
                if(rdfifo_dout!==pattern(display_epoch_pixels%WIDTH,display_epoch_pixels/WIDTH))
                    $fatal(1,"FAIL: 720p pixel/order epoch=%d index=%d got=%h",display_epoch,display_epoch_pixels,rdfifo_dout);
                tap_de<=1;tap_sof<=display_epoch_pixels==0;
                tap_x<=display_epoch_pixels%WIDTH;tap_y<=display_epoch_pixels/WIDTH;tap_rgb<=rdfifo_dout;
                display_epoch_pixels=display_epoch_pixels+1;display_pixels=display_pixels+1;
            end
        end
    end
    integer expected_source_frame;
    always @(posedge clk) if(!fabric_rst) begin
        if(concurrent) begin
            if(dut.arbiter.write_busy && dut.arbiter.write_owner && dut.s_axi_awvalid[0]) video_wait_w=video_wait_w+1;
            if(dut.arbiter.read_busy && dut.arbiter.read_owner && dut.s_axi_arvalid[0]) video_wait_r=video_wait_r+1;
            if(dut.arbiter.write_busy && !dut.arbiter.write_owner && e_awvalid) evidence_wait_w=evidence_wait_w+1;
            if(dut.arbiter.read_busy && !dut.arbiter.read_owner && e_arvalid) evidence_wait_r=evidence_wait_r+1;
        end
        if(!PACKET_MODE && out_valid && out_ready) begin
            expected_source_frame=evidence_frames<4 ? evidence_frames+2 : evidence_frames;
            if(out_data!==16'(expected_source_frame*512+evidence_pixels%FP) || out_meta!==meta(expected_source_frame) ||
                out_event!==ident(evidence_frames<4 ? 1 : 2) || out_deferred!==(evidence_frames>=4))
                $fatal(1,"FAIL: fabric evidence data/meta/UID frame=%d pixel=%d",evidence_frames,evidence_pixels);
            evidence_pixels=evidence_pixels+1;
            if(out_last) evidence_frames=evidence_frames+1;
        end
        if(!PACKET_MODE && result_valid) begin
            if(!result_ok || result_event!==ident(results+1) || result_frames!=4) $fatal(1,"FAIL: evidence result");
            results=results+1;
        end
    end
    task camera_frame;
        integer y,x;
        begin
            for(y=0;y<HEIGHT;y=y+1) begin
                for(x=0;x<HTOTAL;x=x+1) begin
                    @(negedge wrfifo_clk);wrfifo_wren=x<WIDTH;wrfifo_din=pattern(x,y);
                end
            end
            @(negedge wrfifo_clk);wrfifo_wren=0;
        end
    endtask
    task display_frame;
        integer y,x;
        begin
            display_epoch=display_epoch+1;display_epoch_pixels=0;
            @(negedge rdfifo_clk);rdfifo_clr=1;
            @(negedge rdfifo_clk);rdfifo_clr=0;
            // Real 720p SOF at VS rising precedes active region by ~20 lines.
            repeat(20*HTOTAL) @(negedge rdfifo_clk);
            for(y=0;y<HEIGHT;y=y+1) begin
                for(x=0;x<HTOTAL;x=x+1) begin @(negedge rdfifo_clk);rdfifo_rden=x<WIDTH;end
            end
            @(negedge rdfifo_clk);rdfifo_rden=0;
            repeat(6) @(negedge rdfifo_clk);
            if(errors || display_epoch_pixels!=FRAME_PIXELS) $fatal(1,"FAIL:720p deadline/count epoch=%d errors=%d pixels=%d",display_epoch,errors,display_epoch_pixels);
        end
    endtask
    task enqueue;
        input integer uid;
        begin
            if(PACKET_MODE) begin
                @(negedge control_clk);request=1;request_data=ident(uid);
                @(posedge control_clk);while(!event_ready) @(posedge control_clk);
                @(negedge control_clk);request=0;
            end else begin @(negedge clk);request=1;request_data=ident(uid);@(negedge clk);request=0;end
        end
    endtask
    task evidence_frame;
        input integer f;
        integer p;
        begin
            for(p=0;p<FP;p=p+1) begin
                @(negedge cap_clk);pix_valid=1;pix_sof=p==0;pix_last=p==FP-1;pix_data=f*512+p;pix_meta=meta(f);
                @(posedge cap_clk);while(!pix_ready) @(posedge cap_clk);
                @(negedge cap_clk);pix_valid=0;
            end
            pix_sof=0;pix_last=0;wait(frames_committed==f+1);
        end
    endtask
    integer f;
    generate if(!PACKET_MODE) begin: legacy_run
    initial begin
        repeat(8) @(negedge clk);rst=0;@(negedge cap_clk);cap_rst=0;
        repeat(16) @(negedge clk);wrfifo_clr=0;rdfifo_clr=0;
        repeat(16) @(negedge clk);wr_enable=1;
        wait(!dut.video.w_source_busy && !dut.video.wclear);
        repeat(8) @(negedge wrfifo_clk);
        camera_frame();
        if(source_blocked) $fatal(1,"FAIL: test source started before FIFO reset finished");
        wait(video_write_beats==FRAME_PIXELS/8);
        wr_enable=0;
        // Continuous writer may already be waiting in an EMPTY next fill.
        // Cancel that local empty epoch; no externally committed burst is lost.
        @(negedge wrfifo_clk);wrfifo_clr=1;
        @(negedge wrfifo_clk);wrfifo_clr=0;
        wait(!dut.video.wclear && dut.video.client.ws==0);rd_enable=1;
        // First full frame validates video-only, including one-pixel SOF reset.
        display_frame();
        $display("720P_VIDEO_ONLY pixels=%0d source_high=%0d display_active_low=%0d errors=%0d",display_epoch_pixels,source_high,display_active_low,errors);
        concurrent=1;wr_enable=1;
        fork
            camera_frame();
            display_frame();
            begin
`ifdef FABRIC_SMOKE
                repeat(HTOTAL) @(negedge rdfifo_clk);
`else
                repeat(50*HTOTAL) @(negedge rdfifo_clk);
`endif
                fork
                    begin for(f=0;f<12;f=f+1) begin if(f==4) begin enqueue(1);wait(legacy_mode.evidence.dispatcher.active);end evidence_frame(f);end end
                    begin wait(out_valid);enqueue(2);end
                join
            end
        join
        wait(results==2);repeat(20) @(negedge clk);
`ifdef FABRIC_SMOKE
        // Four-row minimizer has too little active time to overlap both read
        // and write competition. Full 720p configuration below requires both.
        if(!(video_wait_w+evidence_wait_w+video_wait_r+evidence_wait_r)) $fatal(1,"FAIL: smoke had no competition");
`else
        if(!(video_wait_r+evidence_wait_r) || !(video_wait_w+evidence_wait_w)) $fatal(1,"FAIL: full-frame competition coverage");
`endif
        if(source_overflow || display_underflow || video_fault || protocol_fault || evidence_buffer_fault || frames_failed || read_errors ||
            rejected_count || evidence_pixels!=2152 || display_pixels!=2*FRAME_PIXELS)
            $fatal(1,"FAIL: fabric conservation/deadline/competition of=%d uf=%d vW/R=%d/%d eW/R=%d/%d",source_overflow,display_underflow,video_wait_w,video_wait_r,evidence_wait_w,evidence_wait_r);
        $display("720P_COMPETITION source_pixels=%0d display_pixels=%0d evidence_frames=%0d windows=%0d pixels=%0d FIFO source_high/display_low=%0d/%0d blocked_vW/R=%0d/%0d eW/R=%0d/%0d",
            source_pixels,display_pixels,frames_committed,results,evidence_pixels,source_high,display_active_low,video_wait_w,video_wait_r,evidence_wait_w,evidence_wait_r);
        $display("PASS: video_memory_fabric 720p video-only/competition/SOF all checks");$finish;
    end
    end else begin: packet_run
    integer i;
    initial begin
        net_fd=$fopen("shared_720p_gmii.hex","w");meta_fd=$fopen("shared_720p_meta.txt","w");
        if(!net_fd || !meta_fd) $fatal(1,"FAIL: 720p packet trace");
        repeat(8) @(negedge clk);arst=0;wait(reset_domains==0);rst=0;
        repeat(16) @(negedge clk);wrfifo_clr=0;rdfifo_clr=0;
        repeat(16) @(negedge clk);wr_enable=1;
        wait(!dut.video.w_source_busy && !dut.video.wclear);repeat(8) @(negedge wrfifo_clk);
        camera_frame();wait(video_write_beats==FRAME_PIXELS/8);wr_enable=0;
        @(negedge wrfifo_clk);wrfifo_clr=1;@(negedge wrfifo_clk);wrfifo_clr=0;
        wait(!dut.video.wclear && dut.video.client.ws==0);rd_enable=1;
        // Display1 feeds REAL sampled pixels into evidence capture/DDR.
        display_frame();wait(frames_committed==1);
        concurrent=1;wr_enable=1;hold_network=1;enqueue(1);
        fork
            begin
                wait(packet_mode.transport.client.evidence.dispatcher.active);
                enqueue(2);
                wait(packet_mode.pending_start);
                // >full packet FIFO: UI readout must genuinely backpressure.
                repeat(20000) @(negedge eth_clk);
                if(!packet_mode.transport.packet_cdc.fifo.wfull || !packet_mode.transport.client.evidence.dispatcher.active)
                    $fatal(1,"FAIL: 720p UDP stall did not reach DDR consumer");
                if(PACKET_MODE==2) network_qualified=0;
                // Keep the full packet path stalled THROUGH the next active
                // display interval, not merely the prior frame's blanking tail.
                wait(display_epoch==3 && rdfifo_rden);
                repeat(20000) @(negedge eth_clk);
                network_qualified=1;
                hold_network=0;
            end
        join_none
        fork camera_frame();display_frame();join
        // Start next display while the prior window is still draining UDP;
        // waiting for its result here would hide actual read-owner contention.
        fork begin repeat(60*HTOTAL) @(negedge wrfifo_clk);camera_frame();end display_frame();join
        wait(packet_results==2);wait(udp_sent+udp_dropped==454);repeat(20) @(negedge clk);
        $display("SHARED720_CHECK vf=%h pf=%h bf=%b ff=%0d re=%0d packetFault=%b udpFault=%b drop=%0d vW/R=%0d/%0d eW/R=%0d/%0d stalls=%0d",
            video_fault,protocol_fault,evidence_buffer_fault,frames_failed,read_errors,packet_fault,udp_fault,udp_dropped,video_wait_w,video_wait_r,evidence_wait_w,evidence_wait_r,network_stalls);
        if(source_overflow || display_underflow || video_fault || protocol_fault || evidence_buffer_fault || frames_failed || read_errors || packet_fault || udp_fault ||
            display_pixels!=3*FRAME_PIXELS || udp_sent+udp_dropped!=454 || stalled_display_pixels<1000 || !network_stalls || !(video_wait_w+evidence_wait_w) || !(video_wait_r+evidence_wait_r))
            $fatal(1,"FAIL: shared720 packet conservation/competition of=%0d uf=%0d display=%0d udp=%0d",source_overflow,display_underflow,display_pixels,udp_sent);
        if(PACKET_MODE==1 && (udp_dropped || udp_sent!=454 || wire_packets!=454)) $fatal(1,"FAIL: normal network loss");
        if(PACKET_MODE==2 && (!udp_dropped || !udp_sent || offline_display_pixels<1000 || reset_domains!=0))
            $fatal(1,"FAIL: offline shared video coverage");
        if(PACKET_MODE==2) $display("PASS: shared_720p_network_isolation display=%0d offlinePixels=%0d sent=%0d drop=%0d unchangedReset=%h",display_pixels,offline_display_pixels,udp_sent,udp_dropped,reset_domains);
        $fclose(net_fd);$fclose(meta_fd);
        $display("PASS: shared_720p_packet real sampled320x180/UI100-toEth125/2windows454packets display=%0d sourceHigh/displayLow=%0d/%0d networkStalls=%0d activePixelsWhileStalled=%0d blockedVW/R=%0d/%0d EW/R=%0d/%0d",
            display_pixels,source_high,display_active_low,network_stalls,stalled_display_pixels,video_wait_w,video_wait_r,evidence_wait_w,evidence_wait_r);$finish;
    end
    end endgenerate
`ifdef FABRIC_SMOKE
    initial begin #2000000;$fatal(1,"FAIL: smoke timeout W=%d target=%d ws=%d overflow=%d fifo=%d",video_write_beats,FRAME_PIXELS/8,dut.video.client.ws,source_overflow,wrfifo_wr_cnt);end
`else
    initial begin #95000000;$fatal(1,"FAIL: fabric timeout source=%d display=%d W=%d ws=%d rs=%d overflow=%d fifo=%d packets=%d",source_pixels,display_pixels,video_write_beats,dut.video.client.ws,dut.video.client.rs,source_overflow,wrfifo_wr_cnt,wire_packets);end
`endif
endmodule
