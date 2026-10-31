`timescale 1ns/1ps
module evidence_packet_udp_bridge_tb;
    reg clk=0,rst=1;
    wire tx_qualified=1'b1;
    always #4 clk=~clk;
    reg in_valid=0,in_last=0;
    reg [7:0] in_data=0;
    wire in_ready,tx_en_pulse,protocol_fault;
    wire [15:0] data_length;
    wire [7:0] payload_data;
    reg payload_req=0,tx_done=0;
    wire [31:0] packets_sent,packets_dropped;
    evidence_packet_udp_bridge #(.MAX_PACKET_BYTES(11)) dut(.*);
    integer n,p,seed=32'h123;
    task capture;
        input integer length;
        begin
            for(p=0;p<length;p=p+1) begin
                @(negedge clk);in_valid=1;in_data=p+81;in_last=p==length-1;
                @(posedge clk);while(!in_ready) @(posedge clk);
            end
            @(negedge clk);in_valid=0;in_last=0;
        end
    endtask
    task transmit;
        input integer length,same_cycle_done;
        integer i;
        begin
            wait(tx_en_pulse);@(negedge clk);
            if(data_length!=length || in_ready) $fatal(1,"FAIL: packet length/ownership");
            repeat(15) @(negedge clk);
            for(i=0;i<length;i=i+1) begin
                payload_req=1;tx_done=same_cycle_done && i==length-1;
                #1;if(payload_data!==8'(i+81)) $fatal(1,"FAIL: UDP buffer byte");
                @(negedge clk);payload_req=0;tx_done=0;
                repeat(($random(seed)&3)) @(negedge clk);
            end
            if(!same_cycle_done) begin repeat(8) @(negedge clk);tx_done=1;@(negedge clk);tx_done=0;end
            wait(in_ready);
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        fork capture(1);transmit(1,0);join
        fork capture(7);transmit(7,1);join
        fork capture(11);transmit(11,0);join
        if(protocol_fault || packets_sent!=3) $fatal(1,"FAIL: good bridge fault/count");
        capture(13);repeat(3) @(negedge clk);
        if(!protocol_fault || packets_dropped!=1 || tx_en_pulse) $fatal(1,"FAIL: oversized datagram not discarded");
        fork capture(2);transmit(2,0);join
        // Buffered old packet is cancelled by shared reset.
        capture(3);wait(tx_en_pulse);@(negedge clk);rst=1;
        repeat(3) @(negedge clk);rst=0;#1;
        if(!in_ready || tx_en_pulse || packets_sent || protocol_fault) $fatal(1,"FAIL: bridge reset retained packet");
        fork capture(4);transmit(4,1);join
        // Too-early tx_done is observable.
        capture(2);wait(tx_en_pulse);repeat(2) @(negedge clk);tx_done=1;@(negedge clk);tx_done=0;
        if(!protocol_fault) $fatal(1,"FAIL: early done not detected");
        @(negedge clk);rst=1;repeat(3) @(negedge clk);rst=0;
        capture(1);wait(tx_en_pulse);repeat(2) @(negedge clk);payload_req=1;
        repeat(2) @(negedge clk);payload_req=0;#1;
        if(!protocol_fault) $fatal(1,"FAIL: excessive payload request not detected");
        $display("PASS: evidence_packet_udp_bridge lengths1/7/11 stalls/last-done/oversize/reset/earlydone/extrareq");$finish;
    end
    initial begin #2000000;$fatal(1,"FAIL: UDP bridge timeout");end
endmodule
