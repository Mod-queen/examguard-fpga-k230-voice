`timescale 1ns/1ps

// One-byte handshake across two asynchronous clock domains: a two-way toggle
// protocol identical in spirit to the evidence_dump UART byte path. The data
// bus is held stable while the request toggle crosses through two flops, and
// the source only reloads it after the acknowledge toggle returns.
module cdc_byte_channel (
    input             src_clk,
    input             src_rst,
    input             src_valid,
    input      [7:0]  src_data,
    output            src_ready,

    input             dst_clk,
    input             dst_rst,
    output            dst_valid,
    output     [7:0]  dst_data,
    input             dst_ack
);

    reg [7:0] hold;
    reg       req;

    (* ASYNC_REG = "TRUE" *) reg req_meta;
    (* ASYNC_REG = "TRUE" *) reg req_sync;

    reg       ack;
    (* ASYNC_REG = "TRUE" *) reg ack_meta;
    (* ASYNC_REG = "TRUE" *) reg ack_sync;

    // Source side: latch a byte and flip the request toggle when the channel
    // is idle, i.e. when the previous byte has been acknowledged.
    always @(posedge src_clk) begin
        if (src_rst) begin
            hold <= 8'd0;
            req  <= 1'b0;
        end else if (src_valid && src_ready) begin
            hold <= src_data;
            req  <= ~req;
        end
    end

    assign src_ready = (req == ack_sync);

    // Destination side: present the byte until the consumer acknowledges it.
    always @(posedge dst_clk) begin
        if (dst_rst) begin
            req_meta <= 1'b0;
            req_sync <= 1'b0;
            ack      <= 1'b0;
        end else begin
            req_meta <= req;
            req_sync <= req_meta;
            if (dst_valid && dst_ack)
                ack <= req_sync;
        end
    end

    always @(posedge src_clk) begin
        if (src_rst) begin
            ack_meta <= 1'b0;
            ack_sync <= 1'b0;
        end else begin
            ack_meta <= ack;
            ack_sync <= ack_meta;
        end
    end

    assign dst_valid = (req_sync != ack);
    assign dst_data  = hold;

endmodule
