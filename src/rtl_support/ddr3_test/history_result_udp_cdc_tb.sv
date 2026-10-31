`timescale 1ns/1ps
module history_result_udp_cdc_tb;
    reg src_clk=0,dst_clk=0;
    always #5 src_clk=~src_clk;
    always #4 dst_clk=~dst_clk;
    reg src_rst=1,dst_rst=1,tx_qualified=1,payload_req=0,tx_done=0;
    reg result_valid=0;
    wire result_ready;
    reg [1:0] result_window=0;
    reg [31:0] result_token=0,result_frames=0,result_gap_count=0;
    reg [2:0] result_code=0;
    reg result_ok=0,result_truncated=0,result_capture_error=0;
    reg result_gap_unknown=0,result_gap_bad_range=0,result_coverage_ok=0;
    reg [63:0] result_lower=0,result_upper=0;
    reg [95:0] result_gap_first_meta=0,result_gap_last_meta=0;
    reg [7:0] result_gap_first_reason=0,result_gap_last_reason=0;
    reg [255:0] result_event=0;
    wire tx_en_pulse,protocol_fault;
    wire [15:0] data_length;
    wire [7:0] payload_data;
    wire [31:0] records_sent,packets_sent,packets_dropped;
    reg [7:0] received[0:127];
    integer i,count,checked=0;
    reg [31:0] crc;
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
    history_result_udp_cdc #(.WINDOWS(4)) dut(
        .src_clk(src_clk),.src_rst(src_rst),.dst_clk(dst_clk),.dst_rst(dst_rst),
        .result_valid(result_valid),.result_ready(result_ready),
        .result_window(result_window),.result_token(result_token),.result_code(result_code),
        .result_ok(result_ok),.result_truncated(result_truncated),.result_capture_error(result_capture_error),
        .result_frames(result_frames),.result_gap_count(result_gap_count),
        .result_gap_unknown(result_gap_unknown),.result_gap_bad_range(result_gap_bad_range),
        .result_coverage_ok(result_coverage_ok),.result_lower(result_lower),.result_upper(result_upper),
        .result_gap_first_meta(result_gap_first_meta),.result_gap_last_meta(result_gap_last_meta),
        .result_gap_first_reason(result_gap_first_reason),.result_gap_last_reason(result_gap_last_reason),
        .result_event(result_event),.tx_qualified(tx_qualified),.tx_en_pulse(tx_en_pulse),
        .data_length(data_length),.payload_req(payload_req),.tx_done(tx_done),
        .payload_data(payload_data),.protocol_fault(protocol_fault),.records_sent(records_sent),
        .packets_sent(packets_sent),.packets_dropped(packets_dropped));
    task automatic send(input [1:0] win,input [31:0] token,input [2:0] code,
                        input ok,input trunc,input caperr,input unk,input badr,input cov,
                        input [31:0] frames,input [31:0] gaps,input [63:0] lo,input [63:0] hi,
                        input [255:0] ev);
        begin
            @(negedge src_clk);
            result_window=win;result_token=token;result_code=code;
            result_ok=ok;result_truncated=trunc;result_capture_error=caperr;
            result_gap_unknown=unk;result_gap_bad_range=badr;result_coverage_ok=cov;
            result_frames=frames;result_gap_count=gaps;result_lower=lo;result_upper=hi;
            result_gap_first_meta={32'd7,lo};result_gap_last_meta={32'd8,hi};
            result_gap_first_reason=8'h81;result_gap_last_reason=8'h82;
            result_event=ev;result_valid=1;
            @(posedge src_clk);while(!result_ready) @(posedge src_clk);
            @(negedge src_clk);result_valid=0;
            while(!tx_en_pulse) @(posedge dst_clk);
            if(data_length!=16'd128) $fatal(1,"FAIL: CDC datagram length %0d",data_length);
            for(i=0;i<128;i=i+1) begin
                @(negedge dst_clk);payload_req=1;
                @(posedge dst_clk);received[i]=payload_data;
                @(negedge dst_clk);payload_req=0;
            end
            @(negedge dst_clk);tx_done=1;@(negedge dst_clk);tx_done=0;
            repeat(6) @(negedge dst_clk);
            if(packets_sent!=checked+1 || records_sent!=checked+1 || packets_dropped)
                $fatal(1,"FAIL: CDC counters packets%0d records%0d",packets_sent,records_sent);
            if(received[0]!=8'h48 || received[1]!=8'h52 || received[2]!=1 || received[3]!=1 ||
               {received[4],received[5]}!=16'd128 || received[6]!={2'b0,cov,badr,unk,caperr,trunc,ok})
                $fatal(1,"FAIL: CDC HR header/flags");
            for(count=0;count<32;count=count+1)
                if(received[8+count]!=ev[255-count*8 -: 8]) $fatal(1,"FAIL: CDC HR transaction");
            if({received[52],received[53],received[54],received[55]}!=frames ||
               {received[56],received[57],received[58],received[59]}!=gaps)
                $fatal(1,"FAIL: CDC HR fields");
            crc=32'hffffffff;
            for(count=0;count<124;count=count+1) crc=crc32_byte(crc,received[count]);
            if({received[124],received[125],received[126],received[127]}!=(~crc))
                $fatal(1,"FAIL: CDC HR CRC");
            checked=checked+1;
            repeat(6) @(negedge src_clk);
        end
    endtask
    initial begin
        repeat(4) @(negedge dst_clk);src_rst=0;dst_rst=0;
        send(1,32'h12345678,0,1,0,0,0,0,0,3,1,100,300,256'hac7500010000000500000003000000000000000100000000000000c801003750);
        send(0,32'hdeadbeef,4,0,1,0,0,0,0,0,0,50,150,256'h1111111122222222333333334444444455555555666666667777777788888888);
        if(protocol_fault) $fatal(1,"FAIL: CDC protocol fault");
        $display("PASS: history_result_udp_cdc src10ns/dst8ns records=%0d packets=%0d CRC PASS",records_sent,packets_sent);
        $finish;
    end
    initial begin #500000;$fatal(1,"FAIL: HR CDC timeout");end
endmodule
