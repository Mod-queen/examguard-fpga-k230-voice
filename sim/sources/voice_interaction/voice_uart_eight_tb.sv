`timescale 1ns/1ps
// Real eight-bank mux and physical UART, all sources pending together.
module voice_uart_eight_tb;
    reg clk=0;always #10 clk=~clk;
    reg rst=1;
    reg [7:0] in_valid=0;
    wire [7:0] in_last,in_ready;
    wire [63:0] in_data;
    wire uart_txd,protocol_fault;
    wire [31:0] packets_sent,packets_dropped;
    integer counts[0:7],received=0,i;
    reg [7:0] captured;
    uart_packet_mux #(.SOURCES(8),.MAX_BYTES(384),.CLK_FREQ_HZ(50000000),.BAUD_RATE(5000000)) dut(
        .clk(clk),.rst(rst),.in_valid(in_valid),.in_last(in_last),.in_data(in_data),.in_ready(in_ready),
        .source_cancel(8'd0),.uart_txd(uart_txd),.protocol_fault(protocol_fault),
        .packets_sent(packets_sent),.packets_dropped(packets_dropped));
    genvar g;
    generate for(g=0;g<8;g=g+1) begin:source
        assign in_data[g*8 +:8]=counts[g]==0 ? (8'h41+g) : counts[g]==195 ? 8'h0a : 8'h30+g;
        assign in_last[g]=counts[g]==195;
        always @(posedge clk) begin
            if(rst) counts[g]<=0;
            else if(in_valid[g] && in_ready[g]) begin
                counts[g]<=counts[g]+1;
                if(in_last[g]) in_valid[g]<=0;
            end
        end
    end endgenerate
    initial begin
        repeat(4)@(negedge clk);rst=0;in_valid=8'hff;
        wait(received==8*196);repeat(20)@(negedge clk);
        if(protocol_fault || packets_dropped || packets_sent!=8) $fatal(1,"mux packet fault");
        $display("PASS: voice_uart_eight packets=8 bytes=1568");$finish;
    end
    initial begin
        wait(!rst);
        forever begin
            @(negedge uart_txd);repeat(5)@(posedge clk);
            for(i=0;i<8;i=i+1) begin repeat(10)@(posedge clk);#1;captured[i]=uart_txd;end
            repeat(10)@(posedge clk);#1;if(!uart_txd) $fatal(1,"UART stop bit");
            if(captured!==(received%196==0 ? 8'h41+received/196 : received%196==195 ? 8'h0a : 8'h30+received/196))
                $fatal(1,"packet interleave byte=%0d data=%h",received,captured);
            received=received+1;
        end
    end
    initial begin #10000000;$fatal(1,"test timeout");end
endmodule
