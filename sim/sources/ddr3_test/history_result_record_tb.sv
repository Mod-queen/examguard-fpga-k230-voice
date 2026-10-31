`timescale 1ns/1ps
module history_result_record_tb;
    reg clk=0,rst=1;
    always #5 clk=~clk;
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
    wire tx_valid,tx_last;
    wire [7:0] tx_data;
    reg tx_ready=0;
    wire protocol_fault;
    wire [31:0] records_sent;
    reg [7:0] received[0:127];
    integer count=0,checked=0;
    reg [31:0] crc;
    function [31:0] crc32_byte;
        input [31:0] c_in;
        input [7:0] data;
        reg [31:0] c;
        integer i;
        begin
            c=c_in;
            for(i=0;i<8;i=i+1) begin
                if(c[0]^data[i]) c=(c>>1)^32'hedb88320;
                else c=c>>1;
            end
            crc32_byte=c;
        end
    endfunction
    history_result_record #(.WINDOWS(4)) dut(
        .clk(clk),.rst(rst),.result_valid(result_valid),.result_ready(result_ready),
        .result_window(result_window),.result_token(result_token),.result_code(result_code),
        .result_ok(result_ok),.result_truncated(result_truncated),.result_capture_error(result_capture_error),
        .result_frames(result_frames),.result_gap_count(result_gap_count),
        .result_gap_unknown(result_gap_unknown),.result_gap_bad_range(result_gap_bad_range),
        .result_coverage_ok(result_coverage_ok),.result_lower(result_lower),.result_upper(result_upper),
        .result_gap_first_meta(result_gap_first_meta),.result_gap_last_meta(result_gap_last_meta),
        .result_gap_first_reason(result_gap_first_reason),.result_gap_last_reason(result_gap_last_reason),
        .result_event(result_event),.tx_valid(tx_valid),.tx_last(tx_last),.tx_data(tx_data),
        .tx_ready(tx_ready),.protocol_fault(protocol_fault),.records_sent(records_sent));
    always @(posedge clk) begin
        if(!rst && tx_valid && tx_ready) begin
            received[count]<=tx_data;
            count<=count+1;
            tx_ready<=0; // deterministic stalls, reopened by producer below
        end
    end
    always @(negedge clk) if(!rst) tx_ready<=($random & 3)!=0;
    task automatic send(input [1:0] win,input [31:0] token,input [2:0] code,
                        input ok,input trunc,input caperr,input unk,input badr,input cov,
                        input [31:0] frames,input [31:0] gaps,input [63:0] lo,input [63:0] hi,
                        input [255:0] ev);
        begin
            @(negedge clk);
            result_window=win;result_token=token;result_code=code;
            result_ok=ok;result_truncated=trunc;result_capture_error=caperr;
            result_gap_unknown=unk;result_gap_bad_range=badr;result_coverage_ok=cov;
            result_frames=frames;result_gap_count=gaps;result_lower=lo;result_upper=hi;
            result_gap_first_meta={32'd7,lo};result_gap_last_meta={32'd8,hi};
            result_gap_first_reason=8'h81;result_gap_last_reason=8'h82;
            result_event=ev;
            result_valid=1;
            @(posedge clk);while(!result_ready) @(posedge clk);
            @(negedge clk);result_valid=0;
            count=0;
            while(count<128) @(negedge clk);
            #1;
            if(received[0]!=8'h48 || received[1]!=8'h52 || received[2]!=1 || received[3]!=1 ||
               {received[4],received[5]}!=16'd128)
                $fatal(1,"FAIL: record header");
            if(received[6]!={2'b0,cov,badr,unk,caperr,trunc,ok} || received[7]!=0)
                $fatal(1,"FAIL: record flags");
            for(count=0;count<32;count=count+1)
                if(received[8+count]!=ev[255-count*8 -: 8]) $fatal(1,"FAIL: event bytes");
            if({received[40],received[41],received[42],received[43]}!=32'(win)) $fatal(1,"FAIL: window");
            if({received[44],received[45],received[46],received[47]}!=token) $fatal(1,"FAIL: token");
            if({received[48],received[49],received[50],received[51]}!=32'(code)) $fatal(1,"FAIL: code");
            if({received[52],received[53],received[54],received[55]}!=frames) $fatal(1,"FAIL: frames");
            if({received[56],received[57],received[58],received[59]}!=gaps) $fatal(1,"FAIL: gaps");
            if({received[60],received[61],received[62],received[63],received[64],received[65],received[66],received[67]}!=lo)
                $fatal(1,"FAIL: lower");
            if({received[68],received[69],received[70],received[71],received[72],received[73],received[74],received[75]}!=hi)
                $fatal(1,"FAIL: upper");
            if(received[100]!=8'h81 || received[101]!=8'h82) $fatal(1,"FAIL: reasons");
            for(count=102;count<124;count=count+1)
                if(received[count]!=0) $fatal(1,"FAIL: reserved");
            crc=32'hffffffff;
            for(count=0;count<124;count=count+1) crc=crc32_byte(crc,received[count]);
            if({received[124],received[125],received[126],received[127]}!=(~crc))
                $fatal(1,"FAIL: CRC32");
            checked=checked+1;
            repeat(5) @(negedge clk);
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        send(1,32'h12345678,0,1,0,0,0,0,0,3,1,100,300,256'hac7500010000000500000003000000000000000100000000000000c801003750);
        send(0,32'hdeadbeef,4,0,1,0,0,0,0,0,0,50,150,256'h1111111122222222333333334444444455555555666666667777777788888888);
        send(1,1,0,1,0,1,1,0,0,2,0,10,20,256'hffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff);
        if(records_sent!=3 || protocol_fault) $fatal(1,"FAIL: record counters");
        $display("PASS: history_result_record 128B magic/fields/flags/CRC/backpressure records=%0d",checked);
        $finish;
    end
    initial begin #500000;$fatal(1,"FAIL: result record timeout count%0d",count);end
endmodule

