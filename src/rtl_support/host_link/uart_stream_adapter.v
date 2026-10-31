`timescale 1ns/1ps
// Mimic uart_tx start/busy for existing sequencers, but deliver bytes to a
// holding stream. busy stays high until downstream accepts the captured byte.
module uart_stream_adapter(
    input wire clk,rst,tx_start,
    input wire [7:0] tx_data,
    input wire tx_last,
    output wire tx,
    output reg busy,
    output wire stream_valid,
    output reg [7:0] stream_data,
    output reg stream_last,
    input wire stream_ready
);
    assign tx=1'b1;
    assign stream_valid=!rst && busy;
    always @(posedge clk) begin
        if(rst) begin busy<=0;stream_data<=0;stream_last<=0;end
        else if(!busy) begin
            if(tx_start) begin busy<=1;stream_data<=tx_data;stream_last<=tx_last;end
        end else if(stream_ready) busy<=0;
    end
endmodule
