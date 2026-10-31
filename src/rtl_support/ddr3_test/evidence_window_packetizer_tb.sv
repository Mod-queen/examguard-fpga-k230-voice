`timescale 1ns/1ps
module window_packet_case #(parameter FP=7, CP=3, CASE_ID=0)(output reg done=0);
    reg clk=0,rst=1;
    always #5 clk=~clk;
    reg out_valid=0,out_sof=0,out_last=0,out_deferred=0;
    reg [15:0] out_data=0;
    reg [95:0] out_meta=0;
    reg [255:0] out_event=0;
    wire out_ready,result_ready,tx_valid,tx_last,protocol_fault;
    reg result_valid=0,result_ok=0,result_deferred=0,tx_ready=0;
    reg [255:0] result_event=0;
    reg [31:0] result_frames=0;
    wire [7:0] tx_data;
    wire [31:0] packets_sent,results_sent;
    evidence_window_packetizer #(.WIDTH(FP),.HEIGHT(1),.CHUNK_PIXELS(CP)) dut(.*);
    reg [7:0] expected[0:200000];
    reg expected_last[0:200000];
    integer tail=0,head=0,packets=0,seed=32'h97531+CASE_ID,n,p,k;
    reg held=0;
    reg [8:0] held_byte;
    reg checking=1,force_stall=0;
    function [255:0] identity;
        input integer uid;
        begin identity={32'h12345678,32'h89abcdef,32'hfedcba98,64'h1234567800000000+uid,
            64'h87654321ffffffff+uid,32'h02000350};end
    endfunction
    function [95:0] meta;
        input integer f;
        begin meta={32'(f),64'hdeadbeefffffffff+f};end
    endfunction
    function [31:0] crc_byte;
        input [31:0] crc;
        input [7:0] data;
        reg [31:0] c;
        integer b;
        begin
            c=crc^data;
            for(b=0;b<8;b=b+1) c=c[0] ? (c>>1)^32'hedb88320 : c>>1;
            crc_byte=c;
        end
    endfunction
    task expect_packet;
        input integer kind,flags,uid,index,f,offset,np,planned;
        reg [639:0] h;
        reg [31:0] crc;
        reg [7:0] data;
        integer a,base;
        begin
            h={16'h4547,8'd2,8'(kind),16'd80,8'(flags),8'd1,identity(uid),32'(index),
                (kind==2 ? 96'd0 : meta(f)),32'(offset*2),32'(FP*2),32'(planned),
                16'(np*2),16'(FP),16'd1,48'd0};
            crc=32'hffffffff;base=tail;
            for(a=0;a<80+np*2;a=a+1) begin
                if(a<80) data=h[639-a*8 -: 8];
                else if((a-80)%2==0) data=((f*103+offset+(a-80)/2)>>8)&255;
                else data=(f*103+offset+(a-80)/2)&255;
                expected[tail]=data;expected_last[tail]=0;tail=tail+1;
                crc=crc_byte(crc,data);
            end
            crc=~crc;
            for(a=0;a<4;a=a+1) begin
                expected[tail]=crc[31-a*8 -: 8];expected_last[tail]=a==3;tail=tail+1;
            end
        end
    endtask
    always @(negedge clk) if(!rst) tx_ready=force_stall ? 0 : (($random(seed)&7)!=0);
    always @(posedge clk) begin
        if(rst) held<=0;
        else begin
            if(held && (!tx_valid || {tx_last,tx_data}!==held_byte))
                $fatal(1,"FAIL: packet changed under stall case=%0d",CASE_ID);
            held<=tx_valid && !tx_ready;held_byte<={tx_last,tx_data};
            if(checking && tx_valid && tx_ready) begin
                if(head>=tail || tx_data!==expected[head] || tx_last!==expected_last[head])
                    $fatal(1,"FAIL: wire byte case=%0d pos=%0d got=%h want=%h last=%b",CASE_ID,head,tx_data,expected[head],tx_last);
                if(tx_last) packets=packets+1;
                head=head+1;
            end
        end
    end
    task send_frame;
        input integer uid,index,f,defer;
        integer i,offset,len;
        begin
            offset=0;
            while(offset<FP) begin
                len=FP-offset>CP ? CP : FP-offset;
                expect_packet(1,defer+(offset+len==FP ? 4 : 0),uid,index,f,offset,len,0);
                offset=offset+len;
            end
            for(i=0;i<FP;i=i+1) begin
                @(negedge clk);out_valid=1;out_data=f*103+i;out_sof=i==0;out_last=i==FP-1;
                out_event=identity(uid);out_meta=meta(f);out_deferred=defer;
                @(posedge clk);while(!out_ready) @(posedge clk);
                @(negedge clk);out_valid=0;
                if((i%5)==0) repeat(2) @(negedge clk);
            end
        end
    endtask
    task result;
        input integer uid,okay,defer,planned,observed,bad;
        begin
            expect_packet(2,defer+okay*2+bad*8,uid,observed,0,0,0,planned);
            @(negedge clk);result_valid=1;result_event=identity(uid);
            result_ok=okay;result_deferred=defer;result_frames=planned;
            @(posedge clk);while(!result_ready) @(posedge clk);
            @(negedge clk);result_valid=0;result_event=~identity(uid);
            wait(head==tail);@(negedge clk);
        end
    endtask
    initial begin
        repeat(5) @(negedge clk);rst=0;
        send_frame(1,0,10,0);send_frame(1,1,11,0);result(1,1,0,2,2,0);
        result(2,0,1,4,0,0); // failed B before any output
        send_frame(3,0,12,1);result(3,0,1,1,1,0); // full pixels, failed R
        // A successful verdict with the wrong count must be visibly unusable.
        send_frame(4,0,13,0);result(4,1,0,2,1,1);
        if(!protocol_fault || results_sent!=4 || packets_sent!=packets)
            $fatal(1,"FAIL: consumer result/fault conservation");
        // Reset during a stalled header cancels the whole unpublished packet.
        checking=0;force_stall=1;
        @(negedge clk);out_valid=1;out_sof=1;out_last=1;out_data=16'hffff;out_meta=meta(99);out_event=identity(99);
        @(posedge clk);while(!out_ready) @(posedge clk);
        @(negedge clk);out_valid=0;
        wait(tx_valid);repeat(5) @(negedge clk);rst=1;
        repeat(3) @(negedge clk);rst=0;force_stall=0;checking=1;
        result(5,0,0,0,0,0);
        if(protocol_fault || results_sent!=1 || packets_sent!=1)
            $fatal(1,"FAIL: old packet/result after reset");
        // Failed engine may end with a partial buffered chunk. Flush bytes but
        // leave the result marked bad because no full frame exists.
        if(FP>1 && CP>1) begin
            expect_packet(1,0,6,0,14,0,1,0);
            @(negedge clk);out_valid=1;out_sof=1;out_last=0;out_data=14*103;
            out_meta=meta(14);out_event=identity(6);out_deferred=0;
            @(posedge clk);while(!out_ready) @(posedge clk);
            @(negedge clk);out_valid=0;
            result(6,0,0,1,0,1);
        end
        if(FP>1) begin
            // Early LAST + missing SOF: publish diagnostic bytes with STREAM_BAD,
            // never turn a later "OK" verdict into usable evidence.
            expect_packet(1,12,7,0,15,0,1,0);
            @(negedge clk);out_valid=1;out_sof=0;out_last=1;out_data=15*103;
            out_meta=meta(15);out_event=identity(7);out_deferred=0;
            @(posedge clk);while(!out_ready) @(posedge clk);
            @(negedge clk);out_valid=0;
            result(7,1,0,1,1,1);
        end
        // Empty "success" cannot establish a real window. Counters saturate.
        @(negedge clk);dut.packets_sent=32'hffffffff;dut.results_sent=32'hffffffff;
        result(8,1,0,0,0,1);
        if(dut.packets_sent!=32'hffffffff || dut.results_sent!=32'hffffffff)
            $fatal(1,"FAIL: consumer statistics wrapped");
        $display("window packet case=%0d FP=%0d chunk=%0d checked_bytes=%0d packets=%0d",CASE_ID,FP,CP,head,packets);
        done=1;
    end
    initial begin #10000000;$fatal(1,"FAIL: packetizer timeout case=%0d head=%0d tail=%0d",CASE_ID,head,tail);end
endmodule
module evidence_window_packetizer_tb;
    wire [2:0] done;
    window_packet_case #(.FP(1),.CP(1),.CASE_ID(0)) a(done[0]);
    window_packet_case #(.FP(7),.CP(3),.CASE_ID(1)) b(done[1]);
    window_packet_case #(.FP(517),.CP(512),.CASE_ID(2)) c(done[2]);
    initial begin wait(&done);$display("PASS: evidence_window_packetizer wire/CRC/identity/results/backpressure/reset");$finish;end
endmodule
