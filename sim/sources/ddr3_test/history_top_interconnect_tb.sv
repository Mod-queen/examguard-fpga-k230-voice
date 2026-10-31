`timescale 1ns/1ps
// Top-only glue: 50->100 event CDC, 50->100 pulse CDC, UI->eth packet CDC and
// the eth-domain reset synchronizer used by the evidence history top.
module history_top_interconnect_tb;
    reg clk50=0,clk100=0,clk125=0;
    always #10 clk50=~clk50;
    always #5 clk100=~clk100;
    always #4 clk125=~clk125;
    reg ui_rst=1;
    // eth-domain async assert / sync release, same as top.
    (* ASYNC_REG="TRUE" *) reg eth_meta=1,eth_sync=1;
    always @(posedge clk125 or posedge ui_rst)
        if(ui_rst) begin eth_meta<=1;eth_sync<=1;end
        else begin eth_meta<=0;eth_sync<=eth_meta;end
    wire eth_rst=eth_sync;
    // event transaction
    reg ev_valid=0;
    reg [255:0] ev_data=0;
    wire ev_ready;
    wire ev_dst_valid;
    wire [255:0] ev_dst_data;
    reg ev_dst_ready=0;
    cdc_event_transaction #(.DATA_WIDTH(256)) event_cdc(
        .src_clk(clk50),.src_rst(ui_rst),.src_valid(ev_valid),.src_data(ev_data),.src_ready(ev_ready),
        .src_accepted_count(),
        .dst_clk(clk100),.dst_rst(ui_rst),.dst_valid(ev_dst_valid),.dst_data(ev_dst_data),
        .dst_ready(ev_dst_ready),.dst_delivered_count());
    // pulse CDC
    reg tick50=0;
    wire tick100;
    pulse_cdc pulse_inst(.src_clk(clk50),.src_rst(ui_rst),.src_pulse(tick50),
        .dst_clk(clk100),.dst_rst(ui_rst),.dst_pulse(tick100));
    integer tick_count=0;
    always @(posedge clk100) if(!ui_rst && tick100) tick_count=tick_count+1;
    // packet CDC
    reg px_valid=0,px_last=0;
    reg [7:0] px_data=0;
    wire px_ready;
    wire px_dst_valid,px_dst_last;
    wire [7:0] px_dst_data;
    reg px_dst_ready=0;
    evidence_packet_cdc #(.DEPTH(64)) packet_cdc(
        .src_clk(clk100),.src_rst(ui_rst),.src_valid(px_valid),.src_last(px_last),.src_data(px_data),.src_ready(px_ready),
        .dst_clk(clk125),.dst_rst(eth_rst),.dst_ready(px_dst_ready),
        .dst_valid(px_dst_valid),.dst_data(px_dst_data),.dst_last(px_dst_last));
    reg [7:0] got[0:127];
    integer got_count=0;
    always @(posedge clk125) if(!eth_rst && px_dst_valid && px_dst_ready) begin
        got[got_count]<=px_dst_data;got_count<=got_count+1;
    end
    always @(negedge clk125) if(!ui_rst) px_dst_ready<=($random & 1);
    task automatic send_event(input integer value);
        begin
            @(negedge clk50);ev_data={224'd0,32'(value)};ev_valid=1;
            @(posedge clk50);while(!ev_ready) @(posedge clk50);
            @(negedge clk50);ev_valid=0;
            @(posedge clk100);while(!ev_dst_valid) @(posedge clk100);
            if(ev_dst_data[31:0]!=32'(value)) $fatal(1,"FAIL: event CDC data %h",ev_dst_data[31:0]);
            ev_dst_ready=1;@(posedge clk100);ev_dst_ready=0;
            repeat(3) @(posedge clk100);
        end
    endtask
    task automatic send_packet;
        integer i;
        begin
            @(negedge clk100);
            for(i=0;i<128;i=i+1) begin
                px_valid=1;px_data=i;px_last=i==127;
                @(posedge clk100);while(!px_ready) @(posedge clk100);
                @(negedge clk100);
            end
            px_valid=0;px_last=0;
            while(got_count<128) @(negedge clk125);
            for(i=0;i<128;i=i+1) if(got[i]!=i) $fatal(1,"FAIL: packet CDC byte %0d=%0d",i,got[i]);
            if(!px_dst_last) begin end
        end
    endtask
    initial begin
        repeat(4) @(negedge clk100);ui_rst=0;
        wait(!eth_rst);repeat(4) @(negedge clk125);
        send_event(32'h12345678);
        send_event(32'hdeadbeef);
        repeat(4) @(negedge clk50);
        tick50=1;@(negedge clk50);tick50=0;
        wait(tick_count==1);repeat(4) @(negedge clk50);
        tick50=1;@(negedge clk50);tick50=0;
        wait(tick_count==2);repeat(6) @(negedge clk100);
        if(tick_count!=2) $fatal(1,"FAIL: pulse CDC count %0d",tick_count);
        send_packet();
        if(got_count!=128) $fatal(1,"FAIL: packet CDC count %0d",got_count);
        if(eth_rst) $fatal(1,"FAIL: eth reset did not release");
        $display("PASS: history_top_interconnect event/pulse CDC + UI->eth packet CDC + eth reset sync");
        $finish;
    end
    initial begin #200000;$fatal(1,"FAIL: interconnect timeout ticks%0d bytes%0d",tick_count,got_count);end
endmodule

