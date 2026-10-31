`timescale 1ns/1ps
module ddr_evidence_probe_tb;
    reg clk=0, rst=1;
    always #5 clk=~clk;
    wire uart_txd, result_ready, test_good, finished;
    reg hold_b=0, inject_b=0, inject_r=0;
    `include "axi_frame_tb_wires.vh"
    ddr_evidence_probe #(.BASE_ADDR(4080),.BAUD_RATE(1000000)) dut (.*);
    axi_frame_slave_model #(.MEM_BYTES(262144)) memory (.*);
    reg [7:0] ch;
    reg [7:0] chars [0:140];
    integer count=0, bitnum, i;
    reg [7:0] expected;
    reg [31:0] word_value;
    // Decode REAL uart_txd, then compare the complete immutable report.
    initial forever begin
        @(negedge uart_txd);
        #1500;
        for(bitnum=0;bitnum<8;bitnum=bitnum+1) begin ch[bitnum]=uart_txd; #1000; end
        if(!uart_txd || count>140) $fatal(1,"FAIL: UART report framing/length");
        chars[count]=ch; count=count+1;
    end
    function [7:0] hex_digit;
        input [3:0] n;
        begin hex_digit=n<10 ? "0"+n : "A"+n-10; end
    endfunction
    initial begin
        repeat(8) @(negedge clk); rst=0;
        wait(finished); repeat(200) @(negedge clk);
        if(!result_ready || !test_good || count!=141) $fatal(1,"FAIL: probe result/count count=%d",count);
        for(i=0;i<141;i=i+1) begin
            if(i<15) expected=(120'h45564944454e434520415849310d0a >> ((14-i)*8));
            else if(i>=135) expected=(48'h504153530d0a >> ((140-i)*8));
            else begin
                case((i-15)/12)
                    0: word_value=24; 1: word_value=0; 2: word_value=2; 3: word_value=0;
                    4: word_value=43224; 5: word_value=14408; 6: word_value=2;
                    7,8: word_value=0; default: word_value=dut.report_words[9];
                endcase
                case((i-15)%12)
                    0: expected=(80'h43464e455752534a5154 >> ((9-(i-15)/12)*8));
                    1: expected="=";
                    10: expected=13;
                    11: expected=10;
                    default: expected=hex_digit(word_value >> ((9-(i-15)%12)*4));
                endcase
            end
            if(chars[i]!==expected) $fatal(1,"FAIL: UART report byte %d got=%h expected=%h",i,chars[i],expected);
        end
        $display("probe commits=%d windows=%d write/read beats=%d/%d UART=%d bytes",dut.frames_committed,dut.windows_completed,dut.write_beats,dut.read_beats,count);
        $display("PASS: ddr_evidence_probe all checks"); $finish;
    end
    initial begin #20000000; $fatal(1,"FAIL: probe timeout"); end
endmodule
