`timescale 1ns/1ps

// Real descriptor-aware evidence subsystem competes with a continuously
// requesting video-like AXI client on one independent byte-addressed memory.
// This is a composition TB, NOT the real video FIFO/camera or MIG simulation.
module shared_evidence_axi_tb;
    localparam FP=269;
    reg clk=0,cap_clk=0,rst=1,cap_rst=1;
    always #5 clk=~clk;
    always #7 cap_clk=~cap_clk;
    `include "axi_frame_tb_wires.vh"
    `include "axi_2client_tb_wires.vh"
    axi_2client_arbiter arbiter(.*);
    wire hold_b=0,inject_b=0,inject_r=0;
    axi_frame_slave_model memory(.*);
    wire video_written,video_read;
    // Video-like source expects address-derived error injection in standalone
    // test; here use address bit mask override through a parameter.
`ifdef REAL_FIFO_VIDEO
    video_fifo_path_source video (
        .clk(clk),.rst(rst),.run(!rst),.reads_enable(1'b1),.continuous(1'b0),
`else
    arbitration_master #(.CLIENT(0),.N(256),.CHECK_RESP(0)) video (
        .clk(clk),.rst(rst),.run(!rst),.reads_enable(video.wi>=32 || video_written),.continuous(1'b0),
`endif
        .writes_done(video_written),.reads_done(video_read),
        .awid(s_axi_awid[3:0]),.awaddr(s_axi_awaddr[29:0]),.awlen(s_axi_awlen[7:0]),
        .awsize(s_axi_awsize[2:0]),.awburst(s_axi_awburst[1:0]),.awlock(s_axi_awlock[0]),
        .awcache(s_axi_awcache[3:0]),.awprot(s_axi_awprot[2:0]),.awqos(s_axi_awqos[3:0]),
        .awvalid(s_axi_awvalid[0]),.awready(s_axi_awready[0]),
        .wdata(s_axi_wdata[127:0]),.wstrb(s_axi_wstrb[15:0]),.wlast(s_axi_wlast[0]),.wvalid(s_axi_wvalid[0]),.wready(s_axi_wready[0]),
        .bid(s_axi_bid[3:0]),.bresp(s_axi_bresp[1:0]),.bvalid(s_axi_bvalid[0]),.bready(s_axi_bready[0]),
        .arid(s_axi_arid[3:0]),.araddr(s_axi_araddr[29:0]),.arlen(s_axi_arlen[7:0]),
        .arsize(s_axi_arsize[2:0]),.arburst(s_axi_arburst[1:0]),.arlock(s_axi_arlock[0]),
        .arcache(s_axi_arcache[3:0]),.arprot(s_axi_arprot[2:0]),.arqos(s_axi_arqos[3:0]),
        .arvalid(s_axi_arvalid[0]),.arready(s_axi_arready[0]),
        .rid(s_axi_rid[3:0]),.rdata(s_axi_rdata[127:0]),.rresp(s_axi_rresp[1:0]),
        .rlast(s_axi_rlast[0]),.rvalid(s_axi_rvalid[0]),.rready(s_axi_rready[0]));
    assign s_axi_awlock[1]=0;assign s_axi_arlock[1]=0;
    assign s_axi_awcache[7:4]=0;assign s_axi_arcache[7:4]=0;
    assign s_axi_awprot[5:3]=0;assign s_axi_arprot[5:3]=0;
    assign s_axi_awqos[7:4]=0;assign s_axi_arqos[7:4]=0;
    reg pix_valid=0,pix_sof=0,pix_last=0;
    reg [15:0] pix_data=0;
    reg [95:0] pix_meta=0;
    wire pix_ready,fifo_full,accepted,rejected;
    reg request=0,out_ready=0;
    reg [255:0] request_data=0;
    wire [1:0] occupancy,high_water;
    wire [31:0] accepted_count,rejected_count,completed_count;
    wire out_valid,out_sof,out_last,out_deferred,result_valid,result_ok,result_deferred;
    wire [15:0] out_data;
    wire [95:0] out_meta,commit_meta;
    wire [255:0] out_event,result_event;
    wire [31:0] result_frames,frames_committed,frames_failed,windows_completed,read_errors_e,write_beats_e,read_beats_e;
    wire commit_valid;
    wire [2:0] commit_slot;
    ddr_evidence_queued #(.FRAME_PIXELS(FP),.RING_FRAMES(7),.EVENT_DEPTH(2),.FIFO_DEPTH(16),.BASE_ADDR(16368)) evidence (
        .clk(clk),.rst(rst),.cap_clk(cap_clk),.cap_rst(cap_rst),.pix_valid(pix_valid),.pix_sof(pix_sof),.pix_last(pix_last),
        .pix_data(pix_data),.pix_meta(pix_meta),.pix_ready(pix_ready),.fifo_full(fifo_full),
        .request(request),.request_data(request_data),.accepted(accepted),.rejected(rejected),.occupancy(occupancy),.high_water(high_water),
        .accepted_count(accepted_count),.rejected_count(rejected_count),.completed_count(completed_count),
        .out_valid(out_valid),.out_sof(out_sof),.out_last(out_last),.out_data(out_data),.out_meta(out_meta),
        .out_event(out_event),.out_deferred(out_deferred),.out_ready(out_ready),
        .result_valid(result_valid),.result_ok(result_ok),.result_deferred(result_deferred),.result_event(result_event),
        .result_frames(result_frames),.result_ready(1'b1),.commit_valid(commit_valid),.commit_slot(commit_slot),.commit_meta(commit_meta),
        .frames_committed(frames_committed),.frames_failed(frames_failed),.windows_completed(windows_completed),
        .read_errors(read_errors_e),.write_beats(write_beats_e),.read_beats(read_beats_e),
        .m_axi_awid(s_axi_awid[7:4]),.m_axi_awaddr(s_axi_awaddr[59:30]),.m_axi_awlen(s_axi_awlen[15:8]),
        .m_axi_awsize(s_axi_awsize[5:3]),.m_axi_awburst(s_axi_awburst[3:2]),.m_axi_awvalid(s_axi_awvalid[1]),.m_axi_awready(s_axi_awready[1]),
        .m_axi_wdata(s_axi_wdata[255:128]),.m_axi_wstrb(s_axi_wstrb[31:16]),.m_axi_wlast(s_axi_wlast[1]),.m_axi_wvalid(s_axi_wvalid[1]),.m_axi_wready(s_axi_wready[1]),
        .m_axi_bid(s_axi_bid[7:4]),.m_axi_bresp(s_axi_bresp[3:2]),.m_axi_bvalid(s_axi_bvalid[1]),.m_axi_bready(s_axi_bready[1]),
        .m_axi_arid(s_axi_arid[7:4]),.m_axi_araddr(s_axi_araddr[59:30]),.m_axi_arlen(s_axi_arlen[15:8]),
        .m_axi_arsize(s_axi_arsize[5:3]),.m_axi_arburst(s_axi_arburst[3:2]),.m_axi_arvalid(s_axi_arvalid[1]),.m_axi_arready(s_axi_arready[1]),
        .m_axi_rid(s_axi_rid[7:4]),.m_axi_rdata(s_axi_rdata[255:128]),.m_axi_rresp(s_axi_rresp[3:2]),
        .m_axi_rlast(s_axi_rlast[1]),.m_axi_rvalid(s_axi_rvalid[1]),.m_axi_rready(s_axi_rready[1]));
    function [255:0] identity;
        input integer uid;
        begin identity={32'h76543210,32'h34,32'h56,64'(uid),64'h1234567800001000+uid,32'h00000350};end
    endfunction
    function [95:0] metadata;
        input integer f;
        begin metadata={32'(f),64'h8765432100000000+f*100};end
    endfunction
    integer f,p,got=0,pixel=0,results=0,source_expected;
    integer opposite_01=0,opposite_10=0,write_compete=0,read_compete=0;
    integer video_wait_w=0,video_wait_r=0,evidence_wait_w=0,evidence_wait_r=0;
    reg [31:0] rng=32'h8ad7f1;
    always @(negedge clk) begin
        rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};out_ready<=rng[0];
    end
    always @(posedge clk) if(!rst) begin
        if(write_busy && read_busy) begin
            if(write_owner==0 && read_owner==1) opposite_01=opposite_01+1;
            if(write_owner==1 && read_owner==0) opposite_10=opposite_10+1;
        end
        if(s_axi_awvalid==3) write_compete=write_compete+1;
        if(s_axi_arvalid==3) read_compete=read_compete+1;
        if(s_axi_awvalid[0] && write_busy && write_owner) video_wait_w=video_wait_w+1;
        if(s_axi_arvalid[0] && read_busy && read_owner) video_wait_r=video_wait_r+1;
        if(s_axi_awvalid[1] && write_busy && !write_owner) evidence_wait_w=evidence_wait_w+1;
        if(s_axi_arvalid[1] && read_busy && !read_owner) evidence_wait_r=evidence_wait_r+1;
        if(out_valid && out_ready) begin
            source_expected=got<4 ? got+6 : got+4;
            if(got>=8 || out_data!==((source_expected*512+pixel)&65535) ||
                out_meta!==metadata(source_expected) || out_event!==identity(got<4 ? 1 : 2) ||
                out_deferred!==(got>=4) || out_sof!==(pixel==0) || out_last!==(pixel==FP-1))
                $fatal(1,"FAIL: shared-memory evidence window/meta/UID frame=%d pixel=%d",got,pixel);
            if(out_last) begin got=got+1;pixel=0;end else pixel=pixel+1;
        end
        if(result_valid) begin
            if(!result_ok || result_event!==identity(results+1) || result_frames!=4 || result_deferred!==(results==1))
                $fatal(1,"FAIL: shared-memory event result");
            results=results+1;
        end
    end
    task enqueue;
        input integer uid;
        begin @(negedge clk);request=1;request_data=identity(uid);@(negedge clk);request=0;end
    endtask
    task frame;
        input integer n;
        begin
            for(p=0;p<FP;p=p+1) begin
                @(negedge cap_clk);pix_valid=1;pix_sof=p==0;pix_last=p==FP-1;pix_data=n*512+p;pix_meta=metadata(n);
                @(posedge cap_clk);while(!pix_ready) @(posedge cap_clk);
                @(negedge cap_clk);pix_valid=0;
            end
            pix_sof=0;pix_last=0;
            wait(frames_committed==n+1);
        end
    endtask
    initial begin
        repeat(8) @(negedge clk);rst=0;@(negedge cap_clk);cap_rst=0;
`ifdef REAL_FIFO_VIDEO
        // Let the first video frame populate DDR before evidence starts; later
        // camera writes and display reads then overlap the evidence windows.
        repeat(14000) @(negedge clk);
`endif
        fork
            begin
                for(f=0;f<16;f=f+1) begin
                    if(f==8) begin enqueue(1);wait(evidence.dispatcher.active);end
                    frame(f);
                end
            end
            begin wait(out_valid);enqueue(2);end
        join
        wait(video_read && video_written && results==2);repeat(12) @(negedge clk);
`ifdef REAL_FIFO_VIDEO
        if(protocol_fault || frames_failed || read_errors_e || rejected_count || accepted_count!=2 || frames_committed!=16 ||
            got!=8 || pixel || write_beats_e!=544 || read_beats_e!=272 ||
            write_grants[31:0]!=32 || read_grants[31:0]!=32 || read_beats[63:32]!=read_beats_e ||
            write_beats[63:32]!=write_beats_e || !(video_wait_w+evidence_wait_w) || !(video_wait_r+evidence_wait_r))
            $fatal(1,"FAIL: actual FIFO shared evidence counters/competition videoW/R=%d/%d evidenceW/R=%d/%d",video_wait_w,video_wait_r,evidence_wait_w,evidence_wait_r);
        $display("actual FIFO/shared evidence frames=16 windows=2 checked_pixels=2152 W/Rbeats=544/272 blocked_video_W/R=%0d/%0d blocked_evidence_W/R=%0d/%0d",
            video_wait_w,video_wait_r,evidence_wait_w,evidence_wait_r);
        $display("PASS: video_fifo_shared all checks");
`else
        if(protocol_fault || frames_failed || read_errors_e || rejected_count || accepted_count!=2 || frames_committed!=16 ||
            got!=8 || pixel || write_beats_e!=544 || read_beats_e!=272 ||
            write_grants[31:0]!=256 || read_grants[31:0]!=256 || read_beats[63:32]!=read_beats_e ||
            write_beats[63:32]!=write_beats_e || !opposite_01 || !opposite_10 || !write_compete || !read_compete)
            $fatal(1,"FAIL: shared evidence counters/overlap 01=%d 10=%d Wc=%d Rc=%d",opposite_01,opposite_10,write_compete,read_compete);
        $display("shared evidence video W/R bursts=256/256 evidence commits=16 windows=2 pixels=2152 W/Rbeats=544/272 opposite_owners=%0d/%0d",opposite_01,opposite_10);
        $display("PASS: shared_evidence_axi all checks");$finish;
`endif
        $finish;
    end
    initial begin #10000000;$fatal(1,"FAIL: shared evidence timeout");end
endmodule
