`timescale 1ns/1ps

// Bundled-data ready/valid event channel, control clock -> MIG UI clock.
// One transaction in flight. Source payload is registered and held from source
// handshake until DESTINATION CONSUMPTION acknowledgement returns through two
// synchronizer stages. Destination payload is sampled one cycle AFTER seeing
// the synchronized request toggle; it remains stable throughout dst stall.
//
// Intended caller: event_transaction_queue (already ready/valid), NOT raw FSM
// pulses. Accepting into this channel is not DDR queue acceptance/window success.
// Both resets MUST be asserted together on epoch cancellation; deassert each
// synchronously to its local clock. Independent one-side reset is unsupported.
// Physical integration MUST constrain held payload max-delay and req/ack first
// stage CDC paths. No global asynchronous groups / per-bit data synchronizers.
module cdc_event_transaction #(
    parameter integer DATA_WIDTH=256
)(
    input wire src_clk,src_rst,
    input wire src_valid,
    input wire [DATA_WIDTH-1:0] src_data,
    output wire src_ready,
    output reg [31:0] src_accepted_count,
    input wire dst_clk,dst_rst,
    output reg dst_valid,
    output reg [DATA_WIDTH-1:0] dst_data,
    input wire dst_ready,
    output reg [31:0] dst_delivered_count
);
    reg req_toggle,ack_toggle;
    reg [DATA_WIDTH-1:0] payload_hold;
    (* ASYNC_REG="TRUE" *) reg ack_meta,ack_sync;
    (* ASYNC_REG="TRUE" *) reg req_meta,req_sync;
    reg sample_pending;
    assign src_ready=!src_rst && req_toggle==ack_sync;
    function [31:0] inc_sat;
        input [31:0] n;
        begin inc_sat=n==32'hffffffff ? n : n+1'b1;end
    endfunction
    always @(posedge src_clk) begin
        if(src_rst) begin
            req_toggle<=0;payload_hold<=0;ack_meta<=0;ack_sync<=0;src_accepted_count<=0;
        end else begin
            ack_meta<=ack_toggle;ack_sync<=ack_meta;
            if(src_valid && src_ready) begin
                payload_hold<=src_data;req_toggle<=!req_toggle;
                src_accepted_count<=inc_sat(src_accepted_count);
            end
        end
    end
    always @(posedge dst_clk) begin
        if(dst_rst) begin
            ack_toggle<=0;req_meta<=0;req_sync<=0;sample_pending<=0;
            dst_valid<=0;dst_data<=0;dst_delivered_count<=0;
        end else begin
            req_meta<=req_toggle;req_sync<=req_meta;
            if(!dst_valid && !sample_pending && req_sync!=ack_toggle) sample_pending<=1;
            if(sample_pending) begin
                dst_data<=payload_hold;dst_valid<=1;sample_pending<=0;
            end
            if(dst_valid && dst_ready) begin
                dst_valid<=0;ack_toggle<=req_sync;
                dst_delivered_count<=inc_sat(dst_delivered_count);
            end
        end
    end
endmodule
