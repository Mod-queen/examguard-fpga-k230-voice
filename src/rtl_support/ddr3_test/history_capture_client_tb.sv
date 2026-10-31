`timescale 1ns/1ps
// Coherent time + sampling CDC + epoch identity/cancellation + ordered ingress
// + automatic closed-window history read. Small geometry, behavioral AXI.
module history_capture_client_tb #(parameter EXTERNAL_TIME=0,GUARDED_AXI=0);
    localparam W=14,H=2,STRIDE=2,FP=(W/STRIDE)*(H/STRIDE),BASE=4080;
    reg clk=0,cap_clk=0,control_clk=0;
    always #5 clk=~clk;
    always #7 cap_clk=~cap_clk;
    always #11 control_clk=~control_clk;
    reg system_rst=1,transport_rst=0,restart=0,ms_tick=0,session_start=0,session_end=0;
    reg [31:0] device_straps=32'h00000001;
    reg cap_enable=1;
    reg [7:0] pixel_r=0,pixel_g=0,pixel_b=0;
    reg [11:0] x=0,y=0;
    reg de=0,sof=0;
    reg external_time_valid=0;
    reg event_valid=0;
    reg [255:0] event_event=0;
    reg decision_ready=1;
    reg out_ready=0,result_ready=0;
    wire event_ready;
    wire [31:0] device_id,boot_id,session_id;
    wire [63:0] time_ms;
    wire session_active,boot_exhausted,identity_request_enable;
    wire decision_valid;
    wire [1:0] decision_kind;
    wire [95:0] decision_meta;
    wire [2:0] decision_code;
    wire out_valid,out_sof,out_last;
    wire [15:0] out_data;
    wire [95:0] out_meta;
    wire [255:0] out_event;
    wire [31:0] out_index;
    wire result_valid,result_ok,result_truncated,result_capture_error,result_coverage_ok;
    wire result_gap_unknown,result_gap_bad_range;
    wire [2:0] result_code;
    wire [31:0] result_frames,result_token,result_gap_count;
    wire [0:0] result_window;
    wire [63:0] result_lower,result_upper;
    wire [95:0] result_gap_first_meta,result_gap_last_meta;
    wire [7:0] result_gap_first_reason,result_gap_last_reason;
    wire [255:0] result_event;
    wire ui_rst,cap_rst,control_rst,cancelled;
    wire [31:0] cancellation_count;
    wire src_halted,dst_halted,source_halted,cdc_src_halted,cdc_dst_halted,ingress_halted,journal_halted,client_halted;
    wire [31:0] source_sofs,cadence_skipped,time_unknown_count,time_stale_count;
    wire [31:0] frames_seen,frames_published,capture_dropped,decisions_sent;
    wire [31:0] decisions_completed,gaps_recorded,gap_recorded,gap_evicted;
    wire [1:0] pending_windows;
    wire [31:0] frames_committed,frames_dropped,reserve_rejected,write_failed;
    wire [2:0] faults;
    wire [6:0] protected_slots;
    wire done,done_ok;
    `include "axi_frame_tb_wires.vh"
    wire rst=GUARDED_AXI ? system_rst : ui_rst;
    wire guard_idle,guard_fault,controlled_transport,source_epoch_rst;
    wire client_transport=GUARDED_AXI ? controlled_transport : transport_rst;
    reg hold_b=0,inject_b=0,inject_r=0;
    reg hr_tx_qualified=1,hr_payload_req=0,hr_tx_done=0;
    wire hr_tx_en_pulse,hr_protocol_fault;
    wire [15:0] hr_data_length;
    wire [7:0] hr_payload_data;
    wire [31:0] hr_records_sent,hr_packets_sent,hr_packets_dropped;
    reg [7:0] hr_received[0:127];
    reg done_seen=0,done_ok_seen=0;
    reg [31:0] crc;
    history_capture_client #(.SRC_WIDTH(W),.SRC_HEIGHT(H),.SAMPLE_STRIDE(STRIDE),.FRAME_INTERVAL(1),
        .CAP_DEPTH(8),.CDC_DEPTH(16),.SLOTS(7),.WINDOWS(2),.BURST(1),.GAP_DEPTH(8),
        .PRE_MS(100),.POST_MS(100),.BASE_ADDR(BASE),.WITH_HR_UDP(1),.EXTERNAL_CAP_TIME(EXTERNAL_TIME)) dut(
        .clk(clk),.control_clk(control_clk),.cap_clk(cap_clk),
        .system_rst(system_rst),.transport_rst(client_transport),.restart(restart),
        .ms_tick(ms_tick),.session_start(session_start),.session_end(session_end),.device_straps(device_straps),
        .device_id(device_id),.boot_id(boot_id),.session_id(session_id),.time_ms(time_ms),
        .session_active(session_active),.boot_exhausted(boot_exhausted),.identity_request_enable(identity_request_enable),
        .cap_enable(cap_enable),.pixel_r(pixel_r),.pixel_g(pixel_g),.pixel_b(pixel_b),.x(x),.y(y),.de(de),.sof(sof),
        .cap_time_ms(time_ms),.cap_time_valid(external_time_valid),.cap_time_age(32'd0),.external_ui_halt(1'b0),
        .event_valid(event_valid),.event_ready(event_ready),.event_event(event_event),
        .decision_valid(decision_valid),.decision_ready(decision_ready),.decision_kind(decision_kind),
        .decision_meta(decision_meta),.decision_code(decision_code),
        .out_valid(out_valid),.out_sof(out_sof),.out_last(out_last),.out_data(out_data),.out_meta(out_meta),
        .out_event(out_event),.out_index(out_index),.out_ready(out_ready),
        .result_valid(result_valid),.result_ready(result_ready),.result_window(result_window),
        .result_token(result_token),.result_code(result_code),.result_ok(result_ok),
        .result_truncated(result_truncated),.result_capture_error(result_capture_error),
        .result_frames(result_frames),.result_gap_count(result_gap_count),
        .result_gap_unknown(result_gap_unknown),.result_gap_bad_range(result_gap_bad_range),
        .result_coverage_ok(result_coverage_ok),.result_lower(result_lower),.result_upper(result_upper),
        .result_gap_first_meta(result_gap_first_meta),.result_gap_last_meta(result_gap_last_meta),
        .result_gap_first_reason(result_gap_first_reason),.result_gap_last_reason(result_gap_last_reason),
        .result_event(result_event),
        .hr_tx_qualified(hr_tx_qualified),.hr_tx_en_pulse(hr_tx_en_pulse),.hr_data_length(hr_data_length),
        .hr_payload_req(hr_payload_req),.hr_tx_done(hr_tx_done),.hr_payload_data(hr_payload_data),
        .hr_protocol_fault(hr_protocol_fault),.hr_records_sent(hr_records_sent),
        .hr_packets_sent(hr_packets_sent),.hr_packets_dropped(hr_packets_dropped),
        .ui_rst(ui_rst),.cap_rst(cap_rst),.control_rst(control_rst),.cancelled(cancelled),
        .cancellation_count(cancellation_count),.src_halted(src_halted),.dst_halted(dst_halted),
        .source_halted(source_halted),.cdc_src_halted(cdc_src_halted),.cdc_dst_halted(cdc_dst_halted),
        .ingress_halted(ingress_halted),.journal_halted(journal_halted),.client_halted(client_halted),
        .source_sofs(source_sofs),.cadence_skipped(cadence_skipped),
        .time_unknown_count(time_unknown_count),.time_stale_count(time_stale_count),
        .frames_seen(frames_seen),.frames_published(frames_published),.capture_dropped(capture_dropped),
        .decisions_sent(decisions_sent),.decisions_completed(decisions_completed),.gaps_recorded(gaps_recorded),
        .gap_recorded(gap_recorded),.gap_evicted(gap_evicted),.pending_windows(pending_windows),
        .frames_committed(frames_committed),.frames_dropped(frames_dropped),
        .reserve_rejected(reserve_rejected),.write_failed(write_failed),.faults(faults),
        .protected_slots(protected_slots),.done(done),.done_ok(done_ok),
        .m_axi_awid(m_axi_awid),.m_axi_arid(m_axi_arid),.m_axi_awaddr(m_axi_awaddr),.m_axi_araddr(m_axi_araddr),
        .m_axi_awlen(m_axi_awlen),.m_axi_arlen(m_axi_arlen),.m_axi_awsize(m_axi_awsize),.m_axi_arsize(m_axi_arsize),
        .m_axi_awburst(m_axi_awburst),.m_axi_arburst(m_axi_arburst),
        .m_axi_awvalid(m_axi_awvalid),.m_axi_arvalid(m_axi_arvalid),
        .m_axi_awready(m_axi_awready),.m_axi_arready(m_axi_arready),
        .m_axi_wdata(m_axi_wdata),.m_axi_wstrb(m_axi_wstrb),.m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),.m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid),.m_axi_rid(m_axi_rid),.m_axi_bresp(m_axi_bresp),.m_axi_rresp(m_axi_rresp),
        .m_axi_bvalid(m_axi_bvalid),.m_axi_rvalid(m_axi_rvalid),.m_axi_rlast(m_axi_rlast),
        .m_axi_rdata(m_axi_rdata),.m_axi_bready(m_axi_bready),.m_axi_rready(m_axi_rready));
    wire [3:0] g_awid,g_arid,g_bid,g_rid;wire [29:0] g_awaddr,g_araddr;
    wire [7:0] g_awlen,g_arlen;wire [2:0] g_awsize,g_arsize;wire [1:0] g_awburst,g_arburst,g_bresp,g_rresp;
    wire g_awvalid,g_awready,g_arvalid,g_arready,g_wvalid,g_wready,g_wlast,g_bvalid,g_bready,g_rvalid,g_rready,g_rlast;
    wire [127:0] g_wdata,g_rdata;wire [15:0] g_wstrb;
    history_lifecycle_control lifecycle(.clk(control_clk),.transport_rst(system_rst || transport_rst),
        .axi_idle(guard_idle),.local_cancelled(cancelled),.client_transport_rst(controlled_transport),.source_epoch_rst(source_epoch_rst));
    generate if(GUARDED_AXI) begin: guarded
        history_axi_epoch_guard guard(.clk(clk),.rst(rst),.cancel(ui_rst),.idle(guard_idle),.protocol_fault(guard_fault),
            .s_awid(m_axi_awid),.s_arid(m_axi_arid),.s_awaddr(m_axi_awaddr),.s_araddr(m_axi_araddr),
            .s_awlen(m_axi_awlen),.s_arlen(m_axi_arlen),.s_awsize(m_axi_awsize),.s_arsize(m_axi_arsize),
            .s_awburst(m_axi_awburst),.s_arburst(m_axi_arburst),.s_awvalid(m_axi_awvalid),.s_arvalid(m_axi_arvalid),
            .s_awready(m_axi_awready),.s_arready(m_axi_arready),.s_wdata(m_axi_wdata),.s_wstrb(m_axi_wstrb),
            .s_wlast(m_axi_wlast),.s_wvalid(m_axi_wvalid),.s_wready(m_axi_wready),.s_bid(m_axi_bid),.s_rid(m_axi_rid),
            .s_bresp(m_axi_bresp),.s_rresp(m_axi_rresp),.s_bvalid(m_axi_bvalid),.s_rvalid(m_axi_rvalid),
            .s_rlast(m_axi_rlast),.s_rdata(m_axi_rdata),.s_bready(m_axi_bready),.s_rready(m_axi_rready),
            .m_awid(g_awid),.m_arid(g_arid),.m_awaddr(g_awaddr),.m_araddr(g_araddr),.m_awlen(g_awlen),.m_arlen(g_arlen),
            .m_awsize(g_awsize),.m_arsize(g_arsize),.m_awburst(g_awburst),.m_arburst(g_arburst),
            .m_awvalid(g_awvalid),.m_arvalid(g_arvalid),.m_awready(g_awready),.m_arready(g_arready),
            .m_wdata(g_wdata),.m_wstrb(g_wstrb),.m_wlast(g_wlast),.m_wvalid(g_wvalid),.m_wready(g_wready),
            .m_bid(g_bid),.m_rid(g_rid),.m_bresp(g_bresp),.m_rresp(g_rresp),.m_bvalid(g_bvalid),.m_rvalid(g_rvalid),
            .m_rlast(g_rlast),.m_rdata(g_rdata),.m_bready(g_bready),.m_rready(g_rready));
    end else begin: direct
        assign guard_idle=1;assign guard_fault=0;
        assign {g_awid,g_arid,g_awaddr,g_araddr,g_awlen,g_arlen,g_awsize,g_arsize,g_awburst,g_arburst,
            g_awvalid,g_arvalid,g_wdata,g_wstrb,g_wlast,g_wvalid,g_bready,g_rready}=
            {m_axi_awid,m_axi_arid,m_axi_awaddr,m_axi_araddr,m_axi_awlen,m_axi_arlen,m_axi_awsize,m_axi_arsize,m_axi_awburst,m_axi_arburst,
            m_axi_awvalid,m_axi_arvalid,m_axi_wdata,m_axi_wstrb,m_axi_wlast,m_axi_wvalid,m_axi_bready,m_axi_rready};
        assign {m_axi_awready,m_axi_arready,m_axi_wready,m_axi_bid,m_axi_rid,m_axi_bresp,m_axi_rresp,m_axi_bvalid,m_axi_rvalid,m_axi_rlast,m_axi_rdata}=
            {g_awready,g_arready,g_wready,g_bid,g_rid,g_bresp,g_rresp,g_bvalid,g_rvalid,g_rlast,g_rdata};
    end endgenerate
    axi_frame_slave_model memory(.m_axi_awid(g_awid),.m_axi_arid(g_arid),.m_axi_awaddr(g_awaddr),.m_axi_araddr(g_araddr),
        .m_axi_awlen(g_awlen),.m_axi_arlen(g_arlen),.m_axi_awsize(g_awsize),.m_axi_arsize(g_arsize),
        .m_axi_awburst(g_awburst),.m_axi_arburst(g_arburst),.m_axi_awvalid(g_awvalid),.m_axi_arvalid(g_arvalid),
        .m_axi_awready(g_awready),.m_axi_arready(g_arready),.m_axi_wdata(g_wdata),.m_axi_wstrb(g_wstrb),
        .m_axi_wlast(g_wlast),.m_axi_wvalid(g_wvalid),.m_axi_wready(g_wready),.m_axi_bid(g_bid),.m_axi_rid(g_rid),
        .m_axi_bresp(g_bresp),.m_axi_rresp(g_rresp),.m_axi_bvalid(g_bvalid),.m_axi_rvalid(g_rvalid),
        .m_axi_rlast(g_rlast),.m_axi_rdata(g_rdata),.m_axi_bready(g_bready),.m_axi_rready(g_rready),.*);
    integer seen_decisions=0,checked_pixels=0,checked_results=0;
    integer frame_args[0:15];
    integer published_times[0:15];
    integer published_count=0;
    integer i,k,yy,arg;
    reg [63:0] first_boot,first_session,first_time;
    reg [255:0] e_a,e_b;
    always @(posedge clk) if(!ui_rst) begin
        if(decision_valid && decision_ready) begin
            if(decision_kind==0) begin
                if(decision_meta[63:0]!==64'(frame_args[seen_decisions/2])) $fatal(1,"FAIL: captured frame time mismatch");
                published_times[published_count]=decision_meta[63:0];
                published_count=published_count+1;
            end else if(decision_kind==1) begin
                if(decision_meta[63:0]!==64'(frame_args[seen_decisions/2])) $fatal(1,"FAIL: drop time mismatch");
            end else if(decision_kind!=2) $fatal(1,"FAIL: decision kind");
            if(decision_code>2) $fatal(1,"FAIL: decision code %0d",decision_code);
            seen_decisions=seen_decisions+1;
        end
        if(result_valid && !result_ready && result_gap_bad_range) $fatal(1,"FAIL: bad range result");
    end
    always @(posedge clk) if(!ui_rst && done) begin done_seen<=1;done_ok_seen<=done_ok;end
    task automatic advance_time(input integer target);
        integer n;
        begin
            n=0;
            while(time_ms<target && n<10000) begin
                @(negedge clk);ms_tick=1;
                @(negedge clk);ms_tick=0;
                n=n+1;
            end
            if(time_ms<target) $fatal(1,"FAIL: time did not advance to %0d",target);
            n=0;
            while((dut.time_snapshot.time_ms<target || !dut.time_snapshot.time_valid) && n<2000) begin
                @(negedge cap_clk);n=n+1;
            end
            if(dut.time_snapshot.time_ms<target || !dut.time_snapshot.time_valid)
                $fatal(1,"FAIL: time snapshot did not deliver %0d",target);
        end
    endtask
    task automatic frame(input integer stamp,input integer on);
        begin
            frame_args[seen_decisions/2]=stamp;
            @(negedge cap_clk);sof=1;cap_enable=on;
            @(negedge cap_clk);sof=0;
            for(yy=0;yy<H;yy=yy+1) for(k=0;k<W;k=k+1) begin
                de=1;x=k;y=yy;pixel_r=stamp+k;pixel_g=stamp+k;pixel_b=stamp+k;
                @(negedge cap_clk);
            end
            de=0;
        end
    endtask
    task automatic wait_decisions(input integer n);
        integer guard;
        begin
            guard=0;
            while(decisions_completed<n && guard<5000) begin @(negedge clk);guard=guard+1;end
            if(decisions_completed<n) $fatal(1,"FAIL: decisions %0d expected %0d",decisions_completed,n);
        end
    endtask
    task automatic event_request(input integer stamp,input integer uid,output reg [255:0] e);
        begin
            e={32'hac750001,32'd5,32'd3,64'(uid),64'(stamp),8'd1,8'd0,16'h3750};
            @(negedge clk);event_event=e;event_valid=1;
            @(posedge clk);while(!event_ready) @(posedge clk);
            @(negedge clk);event_valid=0;
        end
    endtask
    task automatic consume_frame(input integer stamp,input integer ordinal);
        integer p;
        reg [15:0] pat;
        begin
            for(p=0;p<FP;p=p+1) begin
                wait(out_valid);#1;
                pat=stamp+2*p;
                if(out_meta[63:0]!==64'(stamp) || out_index!=ordinal || out_sof!=(p==0) || out_last!=(p==FP-1) ||
                   out_data!=={pat[7:3],pat[7:2],pat[7:3]})
                    $fatal(1,"FAIL: client readback stamp%0d p%0d data%0d exp%0d",stamp,p,out_data,{pat[7:3],pat[7:2],pat[7:3]});
                repeat(3) @(negedge clk);
                if(!out_valid) $fatal(1,"FAIL: client pixel not held");
                checked_pixels=checked_pixels+1;
                out_ready=1;@(negedge clk);out_ready=0;
            end
        end
    endtask
    function [31:0] crc32_byte;
        input [31:0] c_in;
        input [7:0] data;
        reg [31:0] c;
        integer n;
        begin
            c=c_in;
            for(n=0;n<8;n=n+1) begin
                if(c[0]^data[n]) c=(c>>1)^32'hedb88320;
                else c=c>>1;
            end
            crc32_byte=c;
        end
    endfunction
    task automatic consume_hr(input [2:0] code,input integer frames,input integer gaps,input unknown,
                              input trunc,input coverage,input [63:0] lo,input [63:0] hi,input [255:0] e);
        integer n;
        begin
            while(!hr_tx_en_pulse) @(posedge clk);
            if(hr_data_length!=16'd128) $fatal(1,"FAIL: HR datagram length %0d",hr_data_length);
            for(n=0;n<128;n=n+1) begin
                @(negedge clk);hr_payload_req=1;
                @(posedge clk);hr_received[n]=hr_payload_data;
                @(negedge clk);hr_payload_req=0;
            end
            @(negedge clk);hr_tx_done=1;@(negedge clk);hr_tx_done=0;
            repeat(12) @(negedge clk);
            if(hr_packets_sent!=1 || hr_records_sent!=1 || hr_packets_dropped)
                $fatal(1,"FAIL: HR counters packets%0d records%0d drop%0d",hr_packets_sent,hr_records_sent,hr_packets_dropped);
            if(hr_received[0]!=8'h48 || hr_received[1]!=8'h52 || hr_received[2]!=1 || hr_received[3]!=1 ||
               {hr_received[4],hr_received[5]}!=16'd128) begin
                $display("DBGHR %h %h %h %h %h %h len%0d",hr_received[0],hr_received[1],hr_received[2],
                    hr_received[3],hr_received[4],hr_received[5],hr_data_length);
                $fatal(1,"FAIL: HR header");
            end
            if(hr_received[6]!={2'b0,coverage,1'b0,unknown,1'b0,trunc,(code==0 && !trunc)})
                $fatal(1,"FAIL: HR flags %b",hr_received[6]);
            for(n=0;n<32;n=n+1)
                if(hr_received[8+n]!=e[255-n*8 -: 8]) $fatal(1,"FAIL: HR transaction");
            if({hr_received[48],hr_received[49],hr_received[50],hr_received[51]}!=32'(code)) $fatal(1,"FAIL: HR code");
            if({hr_received[52],hr_received[53],hr_received[54],hr_received[55]}!=frames) $fatal(1,"FAIL: HR frames");
            if({hr_received[56],hr_received[57],hr_received[58],hr_received[59]}!=gaps) $fatal(1,"FAIL: HR gaps");
            if({hr_received[60],hr_received[61],hr_received[62],hr_received[63],
                hr_received[64],hr_received[65],hr_received[66],hr_received[67]}!=lo) $fatal(1,"FAIL: HR lower");
            if({hr_received[68],hr_received[69],hr_received[70],hr_received[71],
                hr_received[72],hr_received[73],hr_received[74],hr_received[75]}!=hi) $fatal(1,"FAIL: HR upper");
            for(n=102;n<124;n=n+1)
                if(hr_received[n]!=0) $fatal(1,"FAIL: HR reserved");
            crc=32'hffffffff;
            for(n=0;n<124;n=n+1) crc=crc32_byte(crc,hr_received[n]);
            if({hr_received[124],hr_received[125],hr_received[126],hr_received[127]}!=(~crc))
                $fatal(1,"FAIL: HR CRC32");
            if(!done_seen || done_ok_seen!==(code==0 && !trunc)) $fatal(1,"FAIL: HR release verdict");
            done_seen=0;checked_results=checked_results+1;
            repeat(4) @(negedge clk);
        end
    endtask
    initial begin
        repeat(8) @(negedge control_clk);system_rst=0;
        wait(!ui_rst && !cap_rst);wait(identity_request_enable);
        if(EXTERNAL_TIME) begin
            // Cold display can emit SOFs before time delivery. They must not
            // create an unknown-time halt or any fabricated frame/gap decision.
            repeat(3) begin
                @(negedge cap_clk);sof=1;@(negedge cap_clk);sof=0;
                repeat(5) @(negedge cap_clk);
            end
            if(cancelled || source_sofs || frames_seen || decisions_completed || time_unknown_count)
                $fatal(1,"FAIL: cold SOF before external time cancelled epoch");
        end
        external_time_valid=1;
        first_boot=boot_id;first_session=session_id;
        advance_time(100);
        frame(100,1);wait_decisions(2);
        event_request(200,1,e_a);
        advance_time(200);frame(200,1);wait_decisions(4);
        advance_time(250);frame(250,0);wait_decisions(6);
        advance_time(300);frame(300,1);wait_decisions(8);
        if(published_count!=3 || frames_committed!=3 || gaps_recorded!=1)
            $fatal(1,"FAIL: client capture/gap accounting");
        // Automatic reader starts after the writer's ordered fence closes [100,300].
        consume_frame(100,0);consume_frame(200,1);consume_frame(300,2);
        consume_hr(0,3,1,0,0,0,100,300,e_a);
        if(result_token==0 || pending_windows!=0 || faults || client_halted)
            $fatal(1,"FAIL: client scheduled window cleanup");
        if(GUARDED_AXI) begin
            // Actual history writer/DMA has issued W; slave deliberately retains
            // B across local cancellation. Memory/guard do NOT share ui_rst.
            hold_b=1;advance_time(350);frame(350,1);wait(memory.responding);
            if(guard_idle) $fatal(1,"FAIL: missing actual DMA outstanding B");
        end
        first_time=time_ms;
        // Transport-only cancellation: identity boot advances, session/time survive,
        // all old handles/results are reset by the common barrier.
        @(negedge clk);transport_rst=1;
        wait(ui_rst && cap_rst);
        repeat(3) @(negedge control_clk);@(negedge clk);transport_rst=0;
        if(GUARDED_AXI) begin
            repeat(20) @(negedge control_clk);
            if(!ui_rst || !controlled_transport || !memory.responding)
                $fatal(1,"FAIL: history restarted before old B drained");
            hold_b=0;
        end
        wait(!ui_rst && !cap_rst);wait(identity_request_enable);
        if(boot_id!=first_boot+1 || session_id!=first_session || time_ms<first_time)
            $fatal(1,"FAIL: transport identity continuity");
        if(pending_windows || result_valid || out_valid || faults)
            $fatal(1,"FAIL: transport reset leaked old history");
        advance_time(GUARDED_AXI?400:300);
        frame(GUARDED_AXI?400:300,1);wait_decisions(2);
        event_request(GUARDED_AXI?500:400,2,e_b);
        advance_time(GUARDED_AXI?600:500);frame(GUARDED_AXI?600:500,1);wait_decisions(4);
        consume_frame(GUARDED_AXI?400:300,0);consume_frame(GUARDED_AXI?600:500,1);
        consume_hr(0,2,0,0,0,1,GUARDED_AXI?400:300,GUARDED_AXI?600:500,e_b);
        if(GUARDED_AXI && (guard_fault || !guard_idle || rst)) $fatal(1,"FAIL: DMA/guard recovery");
        if(pending_windows || faults || client_halted) $fatal(1,"FAIL: post-transport completion");
        if(EXTERNAL_TIME) begin
            external_time_valid=0;
            @(negedge cap_clk);sof=1;@(negedge cap_clk);sof=0;
            wait(cancelled);repeat(100) @(negedge control_clk);
            if(!cancelled || !ui_rst || !cap_rst || event_ready || result_valid || out_valid)
                $fatal(1,"FAIL: runtime time fault not held until explicit reset");
            $display("PASS: history_capture_client external startup invalid SOFs ignored; runtime time fault latched without restart");
        end
        $display("PASS: history_capture_client identity/timeCDC/epoch/sampling/autoRead frames=%0d pixels=%0d results=%0d boot=%0d",
                 published_count,checked_pixels,checked_results,boot_id);
        $finish;
    end
    initial begin
        #3000000;
        $display("TIMEOUT ui_rst%0d cap_rst%0d state%0d count%0d head%0d closed%b sealed%0d result%0d out%0d dec%0d pubs%0d committed%0d gaps%0d",
            ui_rst,cap_rst,dut.store.scheduler.state,dut.store.scheduler.count,dut.store.scheduler.head,
            dut.store.directory_closed_mask,dut.store.scheduler.sealed_time,result_valid,out_valid,
            decisions_completed,published_count,frames_committed,gaps_recorded);
        $fatal(1,"FAIL: client timeout");
    end
endmodule

