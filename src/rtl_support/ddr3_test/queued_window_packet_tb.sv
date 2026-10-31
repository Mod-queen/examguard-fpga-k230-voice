`timescale 1ns/1ps
// Real queued DDR pipeline and packetizer, asynchronous pixels, stalled packet
// sink and behavioral memory. Raw wire packets are checked with host zlib too.
module queued_window_packet_tb #(parameter ETHERNET_SINK=0, ASYNC_ETHERNET=0, FP=37, CHUNK=16);
    reg clk=0,cap_clk=0,rst=1,cap_rst=1;
    reg eth_clk=0;
    always #4 eth_clk=~eth_clk;
    always #5 clk=~clk;
    always #7 cap_clk=~cap_clk;
    reg pix_valid=0,pix_sof=0,pix_last=0;
    reg [15:0] pix_data=0;
    reg [95:0] pix_meta=0;
    wire pix_ready,fifo_full,accepted,rejected;
    reg request=0;
    reg [255:0] request_data=0;
    wire [1:0] occupancy,high_water;
    wire [31:0] accepted_count,rejected_count,completed_count;
    wire out_valid,out_sof,out_last,out_deferred,out_ready;
    wire [15:0] out_data;
    wire [95:0] out_meta,commit_meta;
    wire [255:0] out_event,result_event;
    wire result_valid,result_ok,result_deferred,result_ready,commit_valid;
    wire [2:0] commit_slot;
    wire [31:0] result_frames,frames_committed,frames_failed,windows_completed,read_errors,write_beats,read_beats;
    reg hold_b=0,inject_b=0,inject_r=0;
    `include "axi_frame_tb_wires.vh"
    ddr_evidence_queued #(.FRAME_PIXELS(FP),.PRE_FRAMES(1),.POST_FRAMES(1),.EVENT_DEPTH(2),
        .RING_FRAMES(7),.FIFO_DEPTH(16),.BASE_ADDR(4080)) pipeline(.*);
    axi_frame_slave_model memory(.*);
    wire tx_valid,tx_last,protocol_fault;
    wire [7:0] tx_data;
    wire tx_ready;
    reg hold_tx=1;
    reg random_ready=0;
    wire bridge_fault;
    wire [31:0] wire_packets;
    wire [31:0] packets_sent,results_sent;
    evidence_window_packetizer #(.WIDTH(FP),.HEIGHT(1),.CHUNK_PIXELS(CHUNK)) consumer(.*);
    integer seed=32'h9876,p,n,fd,bytes=0,packets=0,pixels=0,results=0;
    function [255:0] transaction;
        input integer uid;
        begin transaction={32'h12345678,32'h23456789,32'h3456789a,64'h1234567800000000+uid,
            64'h8765432100000000+uid,8'h02,8'h00,16'h0350};end
    endfunction
    function [95:0] metadata;
        input integer f;
        begin metadata={32'(f),64'hdeadbeef00000000+f*100};end
    endfunction
    always @(negedge clk) if(!rst) random_ready=!hold_tx && (($random(seed)&7)!=0);
    generate if(ETHERNET_SINK) begin: eth_sink
        wire in_ready,tx_en_pulse,tx_done,payload_req;
        wire [15:0] data_length;
        wire [7:0] payload_data,gmii_txd;
        wire gmii_txen,gmii_tx_clk;
        wire packet_valid,packet_last,packet_ready;
        wire [7:0] packet_data;
        wire send_clk=ASYNC_ETHERNET ? eth_clk : clk;
        // Both domains share epoch assertion; deassert through a two-domain
        // release barrier. Producer pipeline is held in rst longer than barrier
        // startup; no old packet can be issued during that startup.
        wire [1:0] send_resets;
        evidence_reset_barrier #(.DOMAINS(2)) reset_barrier(.arst(rst),.clocks({send_clk,clk}),.resets(send_resets));
        if(ASYNC_ETHERNET) begin: crossing
            wire src_ready;
            evidence_packet_cdc #(.DEPTH(16)) packet_cdc(.src_clk(clk),.src_rst(send_resets[0]),.src_valid(tx_valid && !hold_tx),
                .src_data(tx_data),.src_last(tx_last),.src_ready(src_ready),.dst_clk(send_clk),.dst_rst(send_resets[1]),
                .dst_valid(packet_valid),.dst_data(packet_data),.dst_last(packet_last),.dst_ready(packet_ready));
            assign tx_ready=src_ready && !hold_tx;
            assign in_ready=1'b0;
        end else begin: direct
            assign packet_valid=tx_valid && !hold_tx;
            assign packet_data=tx_data;
            assign packet_last=tx_last;
            assign tx_ready=in_ready && !hold_tx;
            assign packet_ready=in_ready;
        end
        wire [31:0] packets_dropped;
        integer eth_fd;
        reg previous_en=0;
        reg [31:0] got_packets=0;
        wire bridge_ready;
        if(ASYNC_ETHERNET) assign packet_ready=bridge_ready;
        else assign in_ready=bridge_ready;
        evidence_packet_udp_bridge bridge(.clk(send_clk),.rst(send_resets[1]),.in_valid(packet_valid),
            .in_last(packet_last),.in_data(packet_data),.in_ready(bridge_ready),.tx_en_pulse(tx_en_pulse),.tx_done(tx_done),
            .data_length(data_length),.payload_req(payload_req),.payload_data(payload_data),
            .protocol_fault(bridge_fault),.packets_sent(),.packets_dropped(packets_dropped));
        assign wire_packets=got_packets;
        eth_udp_tx_gmii ethernet(.clk125m(send_clk),.reset_p(send_resets[1]),.tx_en_pulse(tx_en_pulse),.tx_done(tx_done),
            .dst_mac(48'hffffffffffff),.src_mac(48'h020000000002),.dst_ip(32'hc0a80003),.src_ip(32'hc0a80002),
            .dst_port(16'd6102),.src_port(16'd5000),.data_length(data_length),
            .payload_req_o(payload_req),.payload_dat_i(payload_data),.gmii_tx_clk(gmii_tx_clk),.gmii_txen(gmii_txen),.gmii_txd(gmii_txd));
        initial begin eth_fd=$fopen("window_gmii.hex","w");if(!eth_fd) $fatal(1,"FAIL: GMII trace open");end
        always @(posedge send_clk) if(!send_resets[1]) begin
            previous_en<=gmii_txen;
            if(gmii_txen) $fwrite(eth_fd,"%02x",gmii_txd);
            if(previous_en && !gmii_txen) begin
                $fwrite(eth_fd,"\n");$fflush(eth_fd);got_packets<=got_packets+1;
            end
        end
    end else begin: byte_sink
        assign tx_ready=random_ready;
        assign bridge_fault=0;
        assign wire_packets=0;
    end endgenerate
    always @(posedge clk) if(!rst) begin
        if(tx_valid && tx_ready) begin
            $fwrite(fd,"%02x",tx_data);bytes=bytes+1;
            if(tx_last) begin $fwrite(fd,"\n");packets=packets+1;end
        end
        if(out_valid && out_ready) pixels=pixels+1;
        if(result_valid && result_ready) results=results+1;
    end
    task enqueue;
        input integer uid;
        begin
            @(negedge clk);request=1;request_data=transaction(uid);
            #1;if(!accepted || rejected) $fatal(1,"FAIL: packet integration event rejected");
            @(negedge clk);request=0;
        end
    endtask
    task frame;
        input integer f,okay;
        integer commits,fails;
        begin
            commits=frames_committed+okay;fails=frames_failed+!okay;
            for(p=0;p<FP;p=p+1) begin
                @(negedge cap_clk);pix_valid=1;pix_sof=p==0;pix_last=p==FP-1;
                pix_data=f*103+p;pix_meta=p==0 ? metadata(f) : ~metadata(f);
                @(posedge cap_clk);while(!pix_ready) @(posedge cap_clk);
                @(negedge cap_clk);pix_valid=0;
            end
            pix_sof=0;pix_last=0;
            wait(frames_committed==commits && frames_failed==fails);@(negedge clk);
        end
    endtask
    initial begin
        fd=$fopen("window_packets.hex","w");if(!fd) $fatal(1,"FAIL: packet trace open");
        repeat(8) @(negedge clk);rst=0;@(negedge cap_clk);cap_rst=0;
        frame(10,1);enqueue(1);wait(pipeline.dispatcher.active);frame(11,1);
        wait(tx_valid);enqueue(2);
        // A queued event must not dispatch while the first packet/result stalls.
        repeat(80) @(negedge clk);
        if(results_sent || occupancy!=1 || !pipeline.dispatcher.active)
            $fatal(1,"FAIL: stalled packet lost serialized window ownership");
        hold_tx=0;wait(results_sent==1);
        wait(pipeline.dispatcher.active && out_event==transaction(2));frame(12,1);
        wait(results_sent==2);
        // Write failure yields a result-only failed event.
        enqueue(3);wait(pipeline.dispatcher.active);inject_b=1;frame(13,0);
        wait(results_sent==3);inject_b=0;
        // Read failure still publishes all pixel bytes, but must stay failed.
        frame(14,1);enqueue(4);wait(pipeline.dispatcher.active);inject_r=1;frame(15,1);
        wait(results_sent==4);inject_r=0;repeat(6) @(negedge clk);
        if(ETHERNET_SINK) wait(wire_packets==6*((FP+CHUNK-1)/CHUNK)+4);
        if(protocol_fault || bridge_fault || results!=4 || pixels!=6*FP || packets!=6*((FP+CHUNK-1)/CHUNK)+4 ||
            accepted_count!=4 || rejected_count || completed_count!=4 || frames_failed!=1 || read_errors!=2)
            $fatal(1,"FAIL: queued packet conservation pixels=%0d packets=%0d results=%0d",pixels,packets,results);
        $fclose(fd);
        $display("PASS: queued_window_packet 4results/2OK/failedB/failedR frames=6 pixels=%0d packets=%0d bytes=%0d ethernet_sink=%0d async_ethernet=%0d",pixels,packets,bytes,ETHERNET_SINK,ASYNC_ETHERNET);$finish;
    end
    initial begin #10000000;$fatal(1,"FAIL: queued packet timeout results=%0d",results_sent);end
endmodule
