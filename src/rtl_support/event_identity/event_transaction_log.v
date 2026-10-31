`timescale 1ns/1ps
// ET,<entire256bit transaction as64hex>\n. One source-accepted event record,
// NOT a successful window verdict. Caller may queue records under backpressure.
// Hold this serializer through transport cancellation (system reset only) so
// an old-epoch record already accepted here completes with its ORIGINAL ID.
module event_transaction_log(
    input wire clk,rst,event_valid,
    input wire [255:0] event_data,
    output wire event_ready,
    output wire byte_valid,byte_last,
    output wire [7:0] byte_data,
    input wire byte_ready
);
    reg active;
    reg [6:0] index;
    reg [255:0] held;
    wire [3:0] nibble=held[255-(index-3)*4 -: 4];
    assign event_ready=!rst && !active;
    assign byte_valid=!rst && active;
    assign byte_last=index==67;
    assign byte_data=index==0 ? "E" : index==1 ? "T" : index==2 ? "," : index==67 ? 8'h0a :
        nibble<10 ? 8'h30+nibble : 8'h41+nibble-10;
    always @(posedge clk) begin
        if(rst) begin active<=0;index<=0;held<=0;end
        else begin
            if(event_valid && event_ready) begin active<=1;held<=event_data;index<=0;end
            if(byte_valid && byte_ready) begin
                if(byte_last) active<=0;else index<=index+1'b1;
            end
        end
    end
endmodule
