`timescale 1ns/1ps

// Small deterministic cross-client reset-epoch regression for the exact
// fabric used by candidate20. Frame clear is LOCAL, common rst is separate.
// The evidence source deliberately uses the same ID0 as video.
module video_memory_clear_cross_tb #(parameter COMMON_RESET=0,EPOCH_GUARD=0);
    reg clk=0,rst=1,wrfifo_clk=0,rdfifo_clk=0;
    always #5 clk=~clk;
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
    reg [3:0] e_awid=0,e_arid=0;
    reg [29:0] e_awaddr=8192,e_araddr=8192;
    reg [7:0] e_awlen=2,e_arlen=2;
    reg [2:0] e_awsize=4,e_arsize=4;
    reg [1:0] e_awburst=1,e_arburst=1;
    reg e_awvalid=0,e_arvalid=0,e_wlast=0,e_wvalid=0,e_bready=0,e_rready=0;
    reg [127:0] e_wdata=0;
    reg [15:0] e_wstrb=16'hffff;
    wire e_awready,e_arready,e_wready,e_bvalid,e_rvalid,e_rlast;
    wire [3:0] e_bid,e_rid;
    wire [1:0] e_bresp,e_rresp;
    wire [127:0] e_rdata;
    reg epoch_cancel=0;
    wire epoch_idle,epoch_fault;
    wire [3:0] g_awid,g_arid,g_bid,g_rid;
    wire [29:0] g_awaddr,g_araddr;
    wire [7:0] g_awlen,g_arlen;
    wire [2:0] g_awsize,g_arsize;
    wire [1:0] g_awburst,g_arburst,g_bresp,g_rresp;
    wire g_awvalid,g_awready,g_arvalid,g_arready,g_wvalid,g_wready,g_wlast,g_bvalid,g_bready,g_rvalid,g_rready,g_rlast;
    wire [127:0] g_wdata,g_rdata;wire [15:0] g_wstrb;
    generate if(EPOCH_GUARD) begin: guarded
        history_axi_epoch_guard guard(.clk(clk),.rst(rst),.cancel(epoch_cancel),.idle(epoch_idle),.protocol_fault(epoch_fault),
            .s_awid(e_awid),.s_arid(e_arid),.s_awaddr(e_awaddr),.s_araddr(e_araddr),.s_awlen(e_awlen),.s_arlen(e_arlen),
            .s_awsize(e_awsize),.s_arsize(e_arsize),.s_awburst(e_awburst),.s_arburst(e_arburst),
            .s_awvalid(e_awvalid),.s_arvalid(e_arvalid),.s_awready(e_awready),.s_arready(e_arready),
            .s_wdata(e_wdata),.s_wstrb(e_wstrb),.s_wlast(e_wlast),.s_wvalid(e_wvalid),.s_wready(e_wready),
            .s_bid(e_bid),.s_rid(e_rid),.s_bresp(e_bresp),.s_rresp(e_rresp),.s_bvalid(e_bvalid),.s_rvalid(e_rvalid),
            .s_rlast(e_rlast),.s_rdata(e_rdata),.s_bready(e_bready),.s_rready(e_rready),
            .m_awid(g_awid),.m_arid(g_arid),.m_awaddr(g_awaddr),.m_araddr(g_araddr),.m_awlen(g_awlen),.m_arlen(g_arlen),
            .m_awsize(g_awsize),.m_arsize(g_arsize),.m_awburst(g_awburst),.m_arburst(g_arburst),
            .m_awvalid(g_awvalid),.m_arvalid(g_arvalid),.m_awready(g_awready),.m_arready(g_arready),
            .m_wdata(g_wdata),.m_wstrb(g_wstrb),.m_wlast(g_wlast),.m_wvalid(g_wvalid),.m_wready(g_wready),
            .m_bid(g_bid),.m_rid(g_rid),.m_bresp(g_bresp),.m_rresp(g_rresp),.m_bvalid(g_bvalid),.m_rvalid(g_rvalid),
            .m_rlast(g_rlast),.m_rdata(g_rdata),.m_bready(g_bready),.m_rready(g_rready));
    end else begin: legacy
        assign epoch_idle=1;assign epoch_fault=0;
        assign {g_awid,g_arid,g_awaddr,g_araddr,g_awlen,g_arlen,g_awsize,g_arsize,g_awburst,g_arburst,
            g_awvalid,g_arvalid,g_wdata,g_wstrb,g_wlast,g_wvalid,g_bready,g_rready}=
            {e_awid,e_arid,e_awaddr,e_araddr,e_awlen,e_arlen,e_awsize,e_arsize,e_awburst,e_arburst,
            e_awvalid,e_arvalid,e_wdata,e_wstrb,e_wlast,e_wvalid,e_bready,e_rready};
        assign {e_awready,e_arready,e_wready,e_bid,e_rid,e_bresp,e_rresp,e_bvalid,e_rvalid,e_rlast,e_rdata}=
            {g_awready,g_arready,g_wready,g_bid,g_rid,g_bresp,g_rresp,g_bvalid,g_rvalid,g_rlast,g_rdata};
    end endgenerate
    video_memory_fabric #(.WR_END_EXCLUSIVE(512),.RD_END_EXCLUSIVE(512)) dut(
        .e_awid(g_awid),.e_arid(g_arid),.e_awaddr(g_awaddr),.e_araddr(g_araddr),.e_awlen(g_awlen),.e_arlen(g_arlen),
        .e_awsize(g_awsize),.e_arsize(g_arsize),.e_awburst(g_awburst),.e_arburst(g_arburst),
        .e_awvalid(g_awvalid),.e_arvalid(g_arvalid),.e_awready(g_awready),.e_arready(g_arready),
        .e_wdata(g_wdata),.e_wstrb(g_wstrb),.e_wlast(g_wlast),.e_wvalid(g_wvalid),.e_wready(g_wready),
        .e_bid(g_bid),.e_rid(g_rid),.e_bresp(g_bresp),.e_rresp(g_rresp),.e_bvalid(g_bvalid),.e_rvalid(g_rvalid),
        .e_rlast(g_rlast),.e_rdata(g_rdata),.e_bready(g_bready),.e_rready(g_rready),.*);

    reg allow_w=1,allow_r=1,allow_aw=1,hold_b=0;
    wire inject_b=0,inject_r=0;
    wire mem_wready,mem_awready,mem_rvalid;
    assign m_axi_awready=mem_awready && allow_aw;
    assign m_axi_wready=mem_wready && allow_w;
    assign m_axi_rvalid=mem_rvalid && allow_r;
    axi_frame_slave_model memory (
        .m_axi_awvalid(m_axi_awvalid && allow_aw),.m_axi_awready(mem_awready),
        .m_axi_wvalid(m_axi_wvalid && allow_w),.m_axi_wready(mem_wready),
        .m_axi_rready(m_axi_rready && allow_r),.m_axi_rvalid(mem_rvalid),.*);

    integer e_writes=0,e_responses=0,e_reads=0,e_read_responses=0,video_pixels=0;
    integer clears=0,p,before_count,tag=1,read_tag=1,expected_index=0;
    reg check_video=0,display_pending=0,e_stalled=0;
    reg [134:0] held_e;
    function [127:0] evidence_pattern;
        input integer t,n;
        begin evidence_pattern={32'(t),32'(n),32'h13579bdf,32'(t*17+n)};end
    endfunction
    always @(posedge clk) if(!rst) begin
        if(e_wvalid && e_wready) e_writes=e_writes+1;
        if(e_bvalid && e_bready) begin
            if(e_bid!==e_awid || e_bresp!==0) $fatal(1,"FAIL: evidence B affected by video epoch");
            e_responses=e_responses+1;
        end
        if(e_stalled && !epoch_cancel && (!e_rvalid || {e_rid,e_rresp,e_rlast,e_rdata}!==held_e))
            $fatal(1,"FAIL: video clear overwrote held evidence read");
        e_stalled<=e_rvalid && !e_rready && !epoch_cancel;
        held_e<={e_rid,e_rresp,e_rlast,e_rdata};
        if(e_rvalid && e_rready) begin
            if(e_rid!==e_arid || e_rresp!==0 || e_rlast!==((expected_index%3)==2) ||
                e_rdata!==evidence_pattern(read_tag,expected_index%3))
                $fatal(1,"FAIL: evidence R data/owner corrupted by video clear tag=%d index=%d",read_tag,expected_index);
            expected_index=expected_index+1;e_reads=e_reads+1;
            if(e_rlast) e_read_responses=e_read_responses+1;
        end
        // Epoch clear never resets shared ownership/response buffer.
        if((wrfifo_clr || rdfifo_clr) && (dut.arbiter.write_busy || dut.arbiter.read_busy)) clears=clears+1;
    end
    always @(posedge rdfifo_clk) begin
        if(rst || rdfifo_clr) display_pending<=0;
        else begin
            display_pending<=rdfifo_rden && !rdfifo_empty;
            if(check_video && display_pending) begin
                if(rdfifo_dout!==16'(video_pixels^16'h5a7c)) $fatal(1,"FAIL: old video epoch leaked after evidence drain pixel=%d",video_pixels);
                video_pixels=video_pixels+1;
            end
        end
    end
    task clear_video;
        begin
            @(negedge rdfifo_clk);rdfifo_clr=1;
            // Single display-period pulse; wr-domain event is independent.
            @(negedge wrfifo_clk);wrfifo_clr=1;
            @(negedge rdfifo_clk);rdfifo_clr=0;
            @(negedge wrfifo_clk);wrfifo_clr=0;
        end
    endtask
    task source_frame;
        begin
            wait(!dut.video.wclear && !dut.video.w_source_busy);
            for(p=0;p<256;p=p+1) begin
                @(negedge wrfifo_clk);wrfifo_wren=1;wrfifo_din=p^16'h5a7c;
                @(negedge wrfifo_clk);wrfifo_wren=0;
            end
        end
    endtask
    task e_address;
        input integer t;
        begin
            tag=t;
            @(negedge clk);e_awaddr=8192+t*64;e_awvalid=1;
            @(posedge clk);while(!e_awready) @(posedge clk);
            @(negedge clk);e_awvalid=0;
        end
    endtask
    task e_words;
        input integer t;
        integer n;
        begin
            for(n=0;n<3;n=n+1) begin
                @(negedge clk);e_wvalid=1;e_wdata=evidence_pattern(t,n);e_wlast=n==2;
                @(posedge clk);while(!e_wready) @(posedge clk);
                @(negedge clk);e_wvalid=0;e_wlast=0;
            end
        end
    endtask
    task consume_b;
        begin
            @(negedge clk);e_bready=1;
            @(posedge clk);while(!e_bvalid) @(posedge clk);
            @(negedge clk);e_bready=0;
        end
    endtask
    task e_read;
        input integer t;
        begin
            read_tag=t;expected_index=0;
            @(negedge clk);e_araddr=8192+t*64;e_arvalid=1;
            @(posedge clk);while(!e_arready) @(posedge clk);
            @(negedge clk);e_arvalid=0;
        end
    endtask
    task consume_r;
        begin
            @(negedge clk);e_rready=1;
            wait(expected_index==3);
            @(negedge clk);e_rready=0;
        end
    endtask
    reg [29:0] held_video_aw,held_video_ar;
    task common_cancel;
        begin
            #1;rst=1;wr_enable=0;rd_enable=0;wrfifo_wren=0;rdfifo_rden=0;
            wrfifo_clr=1;rdfifo_clr=1;
            e_awvalid=0;e_wvalid=0;e_arvalid=0;e_bready=0;e_rready=0;
            allow_w=1;allow_aw=1;allow_r=1;hold_b=0;check_video=0;
            repeat(8) @(negedge clk);rst=0;
            repeat(8) @(negedge clk);wrfifo_clr=0;rdfifo_clr=0;
            repeat(25) @(negedge clk);
            if(dut.arbiter.write_busy || dut.arbiter.read_busy || e_bvalid || e_rvalid ||
                memory.writing || memory.responding || memory.reading || video_fault || protocol_fault || evidence_buffer_fault)
                $fatal(1,"FAIL: common cancellation retained AXI owner/response");
        end
    endtask
    initial begin
        repeat(8) @(negedge clk);rst=0;
        repeat(8) @(negedge clk);wrfifo_clr=0;rdfifo_clr=0;
        repeat(20) @(negedge clk);
        if(EPOCH_GUARD) begin
            // History write stalls in shared W while VIDEO fills/queues AW.
            allow_w=0;e_address(1);e_words(1);
            wait(dut.arbiter.ws==2 && dut.arbiter.write_owner);
            wr_enable=1;source_frame();wr_enable=0;wait(dut.video.client.m_axi_awvalid);
            @(negedge clk);epoch_cancel=1;
            repeat(12) @(negedge clk);
            if(!dut.video.client.m_axi_awvalid || !dut.arbiter.write_owner || rst)
                $fatal(1,"FAIL: history cancel reset shared/video state");
            allow_w=1;wait(epoch_idle);epoch_cancel=0;
            wait(video_write_beats==32 && dut.video.client.ws==0);
            if(memory.mem[8256]!==8'(17) || e_responses!=0)
                $fatal(1,"FAIL: cancelled write not completed/response leaked");
            // Held B discarded, source does not need to acknowledge it.
            e_address(2);e_words(2);wait(e_bvalid);
            @(negedge clk);epoch_cancel=1;wait(epoch_idle);
            @(negedge clk);epoch_cancel=0;
            // Fresh write/read, then local cancel held read buffer; video AR
            // proceeds through SAME arbiter/slave without resetting the fabric.
            e_address(3);e_words(3);consume_b();e_read(3);wait(e_rvalid);
            wait(!dut.arbiter.read_busy);rd_enable=1;
            @(negedge clk);epoch_cancel=1;wait(epoch_idle);
            @(negedge clk);epoch_cancel=0;
            wait(video_published_beats>=32);rd_enable=0;
            wait(!dut.video.rclear && rdfifo_rd_cnt>=256);check_video=1;
            for(p=0;p<256;p=p+1) begin @(negedge rdfifo_clk);rdfifo_rden=1;@(negedge rdfifo_clk);rdfifo_rden=0;end
            repeat(8) @(negedge clk);
            // New evidence epoch sees only its own data after stale buffer drain.
            e_address(4);e_words(4);consume_b();e_read(4);consume_r();
            if(video_pixels!=256 || e_responses!=2 || e_reads!=3 || epoch_fault || video_fault || protocol_fault ||
                evidence_buffer_fault || source_overflow || display_underflow || rst)
                $fatal(1,"FAIL: history cancel/video shared recovery");
            $display("PASS: history_shared_epoch W-owner/held-B/read-buffer cancelled without video reset; fresh256video+3evidencepixels");
            $finish;
        end
        // 1: Evidence owns W and is stalled. Video fills a complete burst,
        // asserts AW while arbiter is occupied, then frame-clear occurs.
        allow_w=0;e_address(1);wait(dut.arbiter.ws==2 && dut.arbiter.write_owner);
        wr_enable=1;source_frame();wr_enable=0;
        wait(dut.video.client.m_axi_awvalid);
        held_video_aw=dut.video.client.m_axi_awaddr;
        clear_video();
        repeat(12) begin @(negedge clk);
            if(!dut.video.client.m_axi_awvalid || dut.video.client.m_axi_awaddr!==held_video_aw || !dut.arbiter.write_owner)
                $fatal(1,"FAIL: video AW clear changed shared evidence W owner or withdrawn AW");
        end
        allow_w=1;e_words(1);consume_b();
        wait(video_write_beats==32 && dut.video.client.ws==0);
        if(e_responses!=1 || memory.mem[8192+64]!==8'(17)) $fatal(1,"FAIL: evidence write not preserved");
        // 2: B is present and stalled by the evidence client, not by memory.
        e_address(2);e_words(2);wait(e_bvalid);clear_video();
        repeat(25) begin @(negedge clk);
            if(!e_bvalid || !dut.arbiter.write_owner || dut.arbiter.ws!=3) $fatal(1,"FAIL: video epoch cancelled evidence B");
        end
        consume_b();
        // 3: All W accepted, slave B delayed. Clear must not reset owner.
        hold_b=1;e_address(3);e_words(3);wait(dut.arbiter.ws==3);clear_video();
        repeat(20) @(negedge clk);
        if(!dut.arbiter.write_owner || e_bvalid) $fatal(1,"FAIL: waiting evidence B lost on local clear");
        hold_b=0;consume_b();
        // 4: Evidence read captures from memory slowly; video AR waits behind
        // that transaction. Clearing display must preserve both pending owners.
        allow_r=0;e_read(1);wait(dut.arbiter.rs==2 && dut.arbiter.read_owner);
        rd_enable=1;wait(dut.video.client.m_axi_arvalid);rd_enable=0;
        held_video_ar=dut.video.client.m_axi_araddr;
        clear_video();
        repeat(15) begin @(negedge clk);
            if(!dut.video.client.m_axi_arvalid || dut.video.client.m_axi_araddr!==held_video_ar || !dut.arbiter.read_owner)
                $fatal(1,"FAIL: local display clear withdrew pending AR/shared read owner");
        end
        before_count=video_published_beats;
        allow_r=1;consume_r();
        wait(dut.video.client.rs==0);
        if(video_published_beats!=before_count) $fatal(1,"FAIL: cancelled video AR leaked old pixels");
        // 5: Evidence response fully buffered, upstream output stalled, arbiter
        // now free. Display clear must NOT erase the evidence's held result.
        e_read(2);wait(e_rvalid);wait(!dut.arbiter.read_busy);
        clear_video();repeat(30) @(negedge clk);consume_r();
        // 6: Video read returns/publishes while evidence buffer is held.
        e_read(3);wait(e_rvalid);rd_enable=1;
        wait(dut.video.client.rs==3);rd_enable=0;
        clear_video();repeat(25) @(negedge clk);consume_r();
        wait(dut.video.client.rs==0);
        // New video epoch starts exactly at BEGIN and produces ordered image.
        rd_enable=1;wait(video_published_beats>=before_count+32);
        rd_enable=0;wait(!dut.video.rclear && rdfifo_rd_cnt>=256);
        check_video=1;
        // Standard FIFO data arrives one edge after the request. Issue exactly
        // 256 requests; counting only returned pixels would request a 257th.
        for(p=0;p<256;p=p+1) begin
            @(negedge rdfifo_clk);rdfifo_rden=1;
            @(negedge rdfifo_clk);rdfifo_rden=0;
        end
        repeat(8) @(negedge clk);
        if(video_pixels!=256 || e_writes!=9 || e_responses!=3 || e_reads!=9 || e_read_responses!=3 ||
            source_overflow || display_underflow || video_fault || protocol_fault || evidence_buffer_fault || clears==0)
            $fatal(1,"FAIL: clear cross conservation W/B/R/RLAST=%d/%d/%d/%d of/uf=%d/%d",e_writes,e_responses,e_reads,e_read_responses,source_overflow,display_underflow);
        $display("PASS: video_memory_clear_cross AW/W/B/AR/R/buffer isolation video_pixels=%0d evidence_W/R=%0d/%0d",video_pixels,e_writes,e_reads);
        if(COMMON_RESET) begin
            common_cancel();
            // Evidence W owner blocked, video AW waiting; common reset cancels
            // both clients AND slave, unlike a local SOF clear above.
            allow_w=0;e_address(4);wait(dut.arbiter.ws==2 && dut.arbiter.write_owner);
            wr_enable=1;source_frame();wr_enable=0;wait(dut.video.client.m_axi_awvalid);
            common_cancel();
            // All W accepted, delayed B: response must not resurrect afterward.
            hold_b=1;e_address(5);e_words(5);wait(memory.responding);common_cancel();
            // R in flight blocked ahead of buffer; display AR pending.
            e_address(6);e_words(6);consume_b();allow_r=0;e_read(6);
            wait(dut.arbiter.rs==2 && dut.arbiter.read_owner);rd_enable=1;
            wait(dut.video.client.m_axi_arvalid);common_cancel();
            // Returned R buffer held with arbiter free also belongs to epoch.
            e_read(6);wait(e_rvalid);wait(!dut.arbiter.read_busy);common_cancel();
            e_address(7);e_words(7);consume_b();e_read(7);consume_r();
            wr_enable=1;source_frame();wr_enable=0;wait(video_write_beats==32);
            rd_enable=1;wait(video_published_beats==32);rd_enable=0;
            wait(!dut.video.rclear && rdfifo_rd_cnt>=256);video_pixels=0;check_video=1;
            for(p=0;p<256;p=p+1) begin @(negedge rdfifo_clk);rdfifo_rden=1;@(negedge rdfifo_clk);rdfifo_rden=0;end
            repeat(8) @(negedge clk);
            if(video_pixels!=256 || source_overflow || display_underflow || video_fault || protocol_fault || evidence_buffer_fault)
                $fatal(1,"FAIL: common reset recovery video/evidence");
            $display("PASS: video_memory_common_reset cancels W-owner/pending-videoAW/late-B/R-owner/pending-videoAR/held-buffer then fresh256pixels+evidence");
        end
        $finish;
    end
    initial begin #2000000;$fatal(1,"FAIL: cross-client clear timeout video_ws/rs=%d/%d arbiter_ws/rs=%d/%d",dut.video.client.ws,dut.video.client.rs,dut.arbiter.ws,dut.arbiter.rs);end
endmodule
