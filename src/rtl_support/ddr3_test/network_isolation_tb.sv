`timescale 1ns/1ps
// Actual UDP MAC + packet bridge. Link changes never assert shared reset.
module network_isolation_tb;
    reg clk=0,rst=1,tx_qualified=0;
    always #4 clk=~clk;
    reg in_valid=0,in_last=0;
    reg [7:0] in_data=0;
    wire in_ready,tx_en_pulse,protocol_fault,payload_req,tx_done;
    wire [15:0] data_length;
    wire [7:0] payload_data,gmii_txd;
    wire gmii_txen,gmii_tx_clk;
    wire [31:0] packets_sent,packets_dropped;
    evidence_packet_udp_bridge #(.MAX_PACKET_BYTES(16),.REQUIRE_TX_QUALIFIED(1)) dut(.*);
    eth_udp_tx_gmii mac(.clk125m(clk),.reset_p(rst || !tx_qualified),.tx_en_pulse(tx_en_pulse),.tx_done(tx_done),
        .dst_mac(48'h112233445566),.src_mac(48'haabbccddeeff),.dst_ip(32'hc0a80102),.src_ip(32'hc0a80101),
        .dst_port(16'd6102),.src_port(16'd6102),.data_length(data_length),.payload_req_o(payload_req),.payload_dat_i(payload_data),
        .gmii_tx_clk(gmii_tx_clk),.gmii_txen(gmii_txen),.gmii_txd(gmii_txd));
    integer starts=0,wire_bytes=0;
    reg [31:0] video_progress=0;
    always @(posedge clk) begin
        if(rst) video_progress<=0;
        else video_progress<=video_progress+1;
        if(!rst && tx_en_pulse) starts=starts+1;
        if(!rst && gmii_txen) wire_bytes=wire_bytes+1;
        if(!rst && !tx_qualified && tx_en_pulse) $fatal(1,"FAIL: unqualified start");
    end
    task automatic byte_in(input [7:0] value,input last);
        begin
            @(negedge clk);in_valid=1;in_last=last;in_data=value;
            @(posedge clk);while(!in_ready) @(posedge clk);
            @(negedge clk);in_valid=0;in_last=0;
        end
    endtask
    task automatic packet(input integer n);
        integer i;
        begin for(i=0;i<n;i=i+1) byte_in(i,i==n-1);end
    endtask
    task automatic check_counts(input integer sent,input integer dropped);
        begin
            repeat(3) @(negedge clk);
            if(packets_sent!=sent || packets_dropped!=dropped || protocol_fault)
                $fatal(1,"FAIL: counts sent=%0d drop=%0d fault=%b",packets_sent,packets_dropped,protocol_fault);
        end
    endtask
    integer before_starts;
    reg [31:0] before_video;
    initial begin
        repeat(5) @(negedge clk);rst=0;
        packet(3);check_counts(0,1);if(starts) $fatal(1,"FAIL: offline packet started");
        // Recover midway through discarded packet. No tail can be replayed.
        byte_in(8'h31,0);tx_qualified=1;byte_in(8'h32,1);check_counts(0,2);
        packet(4);wait(packets_sent==1);check_counts(1,2);
        // Fall between accepted bytes; hold partial packet until its LAST.
        byte_in(8'h41,0);@(negedge clk);tx_qualified=0;
        repeat(5) @(negedge clk);tx_qualified=1;byte_in(8'h42,1);check_counts(1,3);
        // Fall on START, before MAC accepts a new datagram.
        before_starts=starts;
        packet(2);tx_qualified=0;check_counts(1,4);
        if(starts!=before_starts) $fatal(1,"FAIL: START was not inhibited");
        tx_qualified=1;
        // Fall in header; abort real MAC locally, consume buffered packet once.
        packet(8);wait(gmii_txen);repeat(12) @(negedge clk);tx_qualified=0;
        check_counts(1,5);if(gmii_txen) $fatal(1,"FAIL: MAC still active");
        before_video=video_progress;repeat(500) @(negedge clk);
        if(video_progress-before_video!=500) $fatal(1,"FAIL: common domain stopped");
        tx_qualified=1;packet(5);wait(packets_sent==2);check_counts(2,5);
        // Fall during payload; reject tx_done instead of counting success.
        packet(16);wait(payload_req);@(negedge clk);tx_qualified=0;
        check_counts(2,6);tx_qualified=1;
        packet(1);wait(packets_sent==3);check_counts(3,6);
        // No ghost replay after repeated link recovery with empty bridge.
        before_starts=starts;
        repeat(4) begin @(negedge clk);tx_qualified=0;repeat(4) @(negedge clk);tx_qualified=1;end
        repeat(100) @(negedge clk);
        if(starts!=before_starts) $fatal(1,"FAIL: old packet replay");
        $display("PASS: network_isolation realMAC offline/partial/START/header/payload/recovery no shared reset sent=%0d dropped=%0d",packets_sent,packets_dropped);
        $finish;
    end
    initial begin #2000000;$fatal(1,"FAIL: network isolation timeout");end
endmodule
