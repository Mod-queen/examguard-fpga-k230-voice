`timescale 1ns/1ps
module uart_packet_mux_tb;
    reg clk=0,rst=1;
    always #5 clk=~clk;
    reg [2:0] in_valid=0,in_last=0,source_cancel=0;
    reg [23:0] in_data=0;
    wire [2:0] in_ready;
    wire uart_txd,protocol_fault;
    wire [31:0] packets_sent,packets_dropped;
    uart_packet_mux #(.SOURCES(3),.MAX_BYTES(12),.CLK_FREQ_HZ(921600),.BAUD_RATE(115200)) dut(.*);
    string line="";
    reg [7:0] ch;
    integer b,lines=0;
    initial forever begin
        @(negedge uart_txd);#120;
        for(b=0;b<8;b=b+1) begin ch[b]=uart_txd;#80;end
        if(!uart_txd) $fatal(1,"FAIL: mux UART framing");
        if(ch==10) begin
            if(line!="AAA" && line!="BB" && line!="CCCC" && line!="D" && line!="LLLLLLLLLLL") $fatal(1,"FAIL: mux interleaved line %s",line);
            line="";lines=lines+1;
        end else line={line,ch};
    end
    task automatic packet;
        input integer s,len;
        input [7:0] data;
        integer p;
        begin
            for(p=0;p<len;p=p+1) begin
                @(negedge clk);in_valid[s]=1;in_data[s*8 +: 8]=p==len-1 ? 10 : data;in_last[s]=p==len-1;
                @(posedge clk);while(!in_ready[s]) @(posedge clk);
            end
            @(negedge clk);in_valid[s]=0;in_last[s]=0;
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        fork packet(0,4,"A");packet(1,3,"B");packet(2,5,"C");join
        wait(lines==3);
        // Incomplete source0 must never transmit; cancellation drops its prefix.
        @(negedge clk);in_valid[0]=1;in_data[7:0]="X";@(negedge clk);in_valid[0]=0;
        repeat(10) @(negedge clk);source_cancel[0]=1;@(negedge clk);source_cancel[0]=0;
        packet(1,14,"Z");packet(2,2,"D");wait(lines==4);
        if(!protocol_fault || packets_dropped!=2 || packets_sent!=4) $fatal(1,"FAIL: mux oversize/cancel counters");
        // Exact maximum length, cancellation of a COMPLETE/sending packet
        // must not retract the accepted packet or cut the physical UART.
        packet(0,12,"L");wait(dut.active && dut.owner==0);
        @(negedge clk);source_cancel[0]=1;repeat(9) @(negedge clk);source_cancel[0]=0;
        wait(lines==5);repeat(20) @(negedge clk);
        if(packets_sent!=5 || packets_dropped!=2) $fatal(1,"FAIL: mux complete cancel/maximum boundary");
        // Cancel an incomplete capture by system reset, then recover. No
        // partial buffer is ever exposed on UART (global reset mid-wire itself
        // necessarily aborts a UART character and is outside packet guarantee).
        @(negedge clk);in_valid[0]=1;in_data[7:0]="X";@(negedge clk);in_valid[0]=0;rst=1;
        repeat(3) @(negedge clk);rst=0;
        packet(2,2,"D");wait(lines==6);repeat(20) @(negedge clk);
        if(packets_sent!=1 || packets_dropped) $fatal(1,"FAIL: mux reset recovery");
        dut.packets_sent=32'hffffffff;dut.packets_dropped=32'hffffffff;
        packet(1,14,"Z");packet(2,2,"D");wait(lines==7);
        if(packets_sent!=32'hffffffff || packets_dropped!=32'hffffffff) $fatal(1,"FAIL: mux counter saturation");
        $display("PASS: uart_packet_mux complete-packet roundrobin/interleaved sources/incomplete cancel/oversize recovery");$finish;
    end
    initial begin #1000000;$fatal(1,"FAIL: mux timeout lines=%0d sent=%0d full=%b count0=%0d",lines,packets_sent,dut.full,dut.count[0]);end
endmodule
