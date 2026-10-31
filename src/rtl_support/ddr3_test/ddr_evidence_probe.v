`timescale 1ns/1ps

// Standalone numbered-frame exerciser for real MIG. 24 frames -> >2 ring wraps;
// event after commit #20, plus one event during first readout. Expected windows:
// [18,19,20,21] and degraded pending window [20,21,22,23]. Default 14405 pixels
// deliberately exercises a partial final beat and multiple 4 KiB boundaries.
// On-board producer/FIFO use ui_clk; independent pipeline TB tests two clocks.
module ddr_evidence_probe #(
    parameter integer FRAME_PIXELS=14405,
    parameter integer CLK_FREQ_HZ=100000000,
    parameter integer BAUD_RATE=115200,
    parameter [29:0] BASE_ADDR=30'h10000ff0
)(
    input wire clk, rst,
    output wire uart_txd,
    output reg result_ready, test_good, finished,
    output wire [3:0] m_axi_awid,
    output wire [29:0] m_axi_awaddr,
    output wire [7:0] m_axi_awlen,
    output wire [2:0] m_axi_awsize,
    output wire [1:0] m_axi_awburst,
    output wire m_axi_awvalid,
    input wire m_axi_awready,
    output wire [127:0] m_axi_wdata,
    output wire [15:0] m_axi_wstrb,
    output wire m_axi_wlast, m_axi_wvalid,
    input wire m_axi_wready,
    input wire [3:0] m_axi_bid,
    input wire [1:0] m_axi_bresp,
    input wire m_axi_bvalid,
    output wire m_axi_bready,
    output wire [3:0] m_axi_arid,
    output wire [29:0] m_axi_araddr,
    output wire [7:0] m_axi_arlen,
    output wire [2:0] m_axi_arsize,
    output wire [1:0] m_axi_arburst,
    output wire m_axi_arvalid,
    input wire m_axi_arready,
    input wire [3:0] m_axi_rid,
    input wire [127:0] m_axi_rdata,
    input wire [1:0] m_axi_rresp,
    input wire m_axi_rlast, m_axi_rvalid,
    output wire m_axi_rready
);
    reg [5:0] source_frame;
    reg [31:0] source_pixel;
    reg source_wait, primary_sent, pending_sent, event_pulse;
    wire pix_ready, fifo_full, out_valid, out_sof, out_last;
    wire [15:0] out_data;
    wire busy, pending, overrun, window_done, window_ok;
    wire [31:0] frames_committed, frames_failed, windows_completed;
    wire [31:0] read_errors, rejected_events, write_beats, read_beats;
    reg [31:0] mismatches, elapsed_cycles, output_pixel;
    reg [3:0] output_frame;
    reg [15:0] rng;
    wire out_ready = rng[0] || rng[3];
    wire pix_valid = !rst && !result_ready && source_frame<24 && !source_wait;
    function [15:0] pattern;
        input [31:0] frame_number, pixel_number;
        begin pattern = (frame_number*16'h9e37) ^ pixel_number; end
    endfunction
    function [31:0] expected_frame;
        input [3:0] n;
        begin
            case(n)
                0: expected_frame=18; 1: expected_frame=19;
                2,4: expected_frame=20; 3,5: expected_frame=21;
                6: expected_frame=22; default: expected_frame=23;
            endcase
        end
    endfunction
    ddr_evidence_axi #(.FRAME_PIXELS(FRAME_PIXELS),.BASE_ADDR(BASE_ADDR)) pipeline (
        .cap_clk(clk),.cap_rst(rst),.clk(clk),.rst(rst),
        .pix_valid(pix_valid),.pix_data(pattern(source_frame,source_pixel)),
        .pix_sof(source_pixel==0),.pix_last(source_pixel==FRAME_PIXELS-1),
        .pix_meta(96'd0),
        .pix_ready(pix_ready),.fifo_full(fifo_full),.event_pulse(event_pulse),
        .out_valid(out_valid),.out_data(out_data),.out_sof(out_sof),.out_last(out_last),
        .out_ready(out_ready),.busy(busy),.pending(pending),.overrun(overrun),
        .window_done(window_done),.window_ok(window_ok),
        .frames_committed(frames_committed),.frames_failed(frames_failed),
        .windows_completed(windows_completed),.read_errors(read_errors),
        .rejected_events(rejected_events),.write_beats(write_beats),.read_beats(read_beats),
        .m_axi_awid(m_axi_awid),.m_axi_awaddr(m_axi_awaddr),.m_axi_awlen(m_axi_awlen),
        .m_axi_awsize(m_axi_awsize),.m_axi_awburst(m_axi_awburst),
        .m_axi_awvalid(m_axi_awvalid),.m_axi_awready(m_axi_awready),
        .m_axi_wdata(m_axi_wdata),.m_axi_wstrb(m_axi_wstrb),.m_axi_wlast(m_axi_wlast),
        .m_axi_wvalid(m_axi_wvalid),.m_axi_wready(m_axi_wready),
        .m_axi_bid(m_axi_bid),.m_axi_bresp(m_axi_bresp),.m_axi_bvalid(m_axi_bvalid),.m_axi_bready(m_axi_bready),
        .m_axi_arid(m_axi_arid),.m_axi_araddr(m_axi_araddr),.m_axi_arlen(m_axi_arlen),
        .m_axi_arsize(m_axi_arsize),.m_axi_arburst(m_axi_arburst),
        .m_axi_arvalid(m_axi_arvalid),.m_axi_arready(m_axi_arready),
        .m_axi_rid(m_axi_rid),.m_axi_rdata(m_axi_rdata),.m_axi_rresp(m_axi_rresp),
        .m_axi_rlast(m_axi_rlast),.m_axi_rvalid(m_axi_rvalid),.m_axi_rready(m_axi_rready));

    wire summary_good = frames_committed==24 && frames_failed==0 &&
        windows_completed==2 && read_errors==0 && rejected_events==0 &&
        !pending && overrun && output_frame==8 && output_pixel==0 && mismatches==0 &&
        write_beats==24*((FRAME_PIXELS+7)/8) && read_beats==8*((FRAME_PIXELS+7)/8);
    reg [31:0] report_words [0:9];
    always @(posedge clk) begin
        if(rst) begin
            source_frame<=0; source_pixel<=0; source_wait<=0;
            primary_sent<=0; pending_sent<=0; event_pulse<=0;
            output_frame<=0; output_pixel<=0; mismatches<=0; elapsed_cycles<=0;
            result_ready<=0; test_good<=0; rng<=16'hace1;
        end else begin
            event_pulse<=0;
            rng<={rng[14:0],rng[15]^rng[13]^rng[12]^rng[10]};
            if(!result_ready && elapsed_cycles!=32'hffffffff) elapsed_cycles<=elapsed_cycles+1'b1;
            if(pix_valid && pix_ready) begin
                if(source_pixel==FRAME_PIXELS-1) begin source_wait<=1; source_pixel<=0; end
                else source_pixel<=source_pixel+1'b1;
            end
            if(source_wait && frames_committed==source_frame+1'b1) begin
                source_frame<=source_frame+1'b1; source_wait<=0;
            end
            if(!primary_sent && frames_committed==20) begin
                primary_sent<=1; event_pulse<=1;
            end
            if(!pending_sent && out_valid && out_ready) begin
                pending_sent<=1; event_pulse<=1;
            end
            if(out_valid && out_ready) begin
                if(out_data!=pattern(expected_frame(output_frame),output_pixel) ||
                    out_sof!=(output_pixel==0) || out_last!=(output_pixel==FRAME_PIXELS-1)) begin
                    if(mismatches!=32'hffffffff) mismatches<=mismatches+1'b1;
                end
                if(output_pixel==FRAME_PIXELS-1) begin output_pixel<=0; output_frame<=output_frame+1'b1; end
                else output_pixel<=output_pixel+1'b1;
            end
            if(window_done && !window_ok && mismatches!=32'hffffffff) mismatches<=mismatches+1'b1;
            // Bounded watchdog also publishes a failed report on a stuck bus.
            if(!result_ready && ((windows_completed==2 && !busy) || elapsed_cycles==100000000)) begin
                result_ready<=1; test_good<=summary_good;
                report_words[0]<=frames_committed; report_words[1]<=frames_failed;
                report_words[2]<=windows_completed; report_words[3]<=mismatches;
                report_words[4]<=write_beats; report_words[5]<=read_beats;
                report_words[6]<={30'd0,overrun,pending}; report_words[7]<=rejected_events;
                report_words[8]<=read_errors; report_words[9]<=elapsed_cycles;
            end
        end
    end

    // One immutable ASCII report; unlike the phase mux this has no shared UART.
    // Header; C/F/N/E/W/R/S/J/Q/T in hex; PASS or FAIL. S bit1=overrun, bit0=pending.
    reg [3:0] line;
    reg [4:0] col;
    reg [1:0] tx_state;
    wire tx_busy;
    reg [7:0] tx_data;
    wire tx_start = result_ready && !finished && tx_state==0 && !tx_busy;
    reg [7:0] label_char;
    reg [3:0] nibble;
    always @* begin
        case(line)
            1: label_char="C"; 2: label_char="F"; 3: label_char="N"; 4: label_char="E";
            5: label_char="W"; 6: label_char="R"; 7: label_char="S"; 8: label_char="J";
            9: label_char="Q"; default: label_char="T";
        endcase
        nibble=0; tx_data=8'h0a;
        if(line==0) begin
            case(col)
                0: tx_data="E"; 1: tx_data="V"; 2: tx_data="I"; 3: tx_data="D";
                4: tx_data="E"; 5: tx_data="N"; 6: tx_data="C"; 7: tx_data="E";
                8: tx_data=" "; 9: tx_data="A"; 10: tx_data="X"; 11: tx_data="I";
                12: tx_data="1"; 13: tx_data=8'h0d; default: tx_data=8'h0a;
            endcase
        end else if(line<=10) begin
            if(col==0) tx_data=label_char;
            else if(col==1) tx_data="=";
            else if(col<=9) begin
                nibble=(report_words[line-1] >> ((9-col)*4));
                tx_data=(nibble<10) ? "0"+nibble : "A"+nibble-10;
            end else if(col==10) tx_data=8'h0d;
        end else begin
            case(col)
                0: tx_data=test_good ? "P" : "F";
                1: tx_data="A";
                2: tx_data=test_good ? "S" : "I";
                3: tx_data=test_good ? "S" : "L";
                4: tx_data=8'h0d; default: tx_data=8'h0a;
            endcase
        end
    end
    uart_tx #(.CLK_FREQ_HZ(CLK_FREQ_HZ),.BAUD_RATE(BAUD_RATE)) serial (
        .clk(clk),.rst(rst),.tx_start(tx_start),.tx_data(tx_data),.tx(uart_txd),.busy(tx_busy));
    wire last_col = (line==0) ? col==14 : (line<=10 ? col==11 : col==5);
    always @(posedge clk) begin
        if(rst) begin line<=0; col<=0; tx_state<=0; finished<=0; end
        else if(!finished) begin
            case(tx_state)
                0: if(tx_start) tx_state<=1;
                1: if(tx_busy) tx_state<=2;
                2: if(!tx_busy) begin
                    tx_state<=0;
                    if(last_col) begin
                        col<=0;
                        if(line==11) finished<=1; else line<=line+1'b1;
                    end else col<=col+1'b1;
                end
                default: tx_state<=0;
            endcase
        end
    end
endmodule
