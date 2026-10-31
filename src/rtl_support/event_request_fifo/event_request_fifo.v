`timescale 1ns / 1ps

// ExamGuard synchronous pulse-request queue. Original project implementation.
// All request payloads must already be in clk's domain. Each asserted bit is
// one new request, not a ready/valid retry. Low source index wins when capacity
// is insufficient. Accepted requests retain their complete payload and order.
module event_request_fifo #(
    parameter SOURCES = 4,
    parameter DATA_WIDTH = 128,
    parameter DEPTH = 16,
    parameter COUNTER_WIDTH = 32,
    parameter COUNT_WIDTH = $clog2(DEPTH + 1)
)(
    input wire clk,
    input wire rst,
    input wire [SOURCES-1:0] request,
    input wire [SOURCES*DATA_WIDTH-1:0] request_data,
    output reg [SOURCES-1:0] accepted,
    output reg [SOURCES-1:0] rejected,
    output wire event_valid,
    input wire event_ready,
    output wire [DATA_WIDTH-1:0] event_data,
    output reg [COUNT_WIDTH-1:0] occupancy,
    output reg [COUNT_WIDTH-1:0] high_water,
    output reg [COUNTER_WIDTH-1:0] accepted_count,
    output reg [COUNTER_WIDTH-1:0] rejected_count,
    output reg [COUNTER_WIDTH-1:0] delivered_count
);
    localparam PTR_WIDTH = (DEPTH > 1) ? $clog2(DEPTH) : 1;
    localparam [COUNTER_WIDTH-1:0] COUNT_MAX = {COUNTER_WIDTH{1'b1}};
    reg [DATA_WIDTH-1:0] storage [0:DEPTH-1];
    reg [PTR_WIDTH-1:0] rd_ptr, wr_ptr;
    wire pop = event_valid && event_ready;
    integer i, slots, pushes, drops, next_occupancy;
    reg [PTR_WIDTH-1:0] write_address [0:SOURCES-1];
    reg [PTR_WIDTH-1:0] write_end;

    initial begin
        if (SOURCES < 1 || DEPTH < 1 || DATA_WIDTH < 1 || COUNTER_WIDTH < 1 ||
            COUNT_WIDTH < $clog2(DEPTH+1)) begin
            $error("Invalid event_request_fifo parameters");
            $finish;
        end
    end

    assign event_valid = !rst && (occupancy != 0);
    assign event_data = storage[rd_ptr];

    function [COUNTER_WIDTH-1:0] sat_add;
        input [COUNTER_WIDTH-1:0] value;
        input integer increment;
        begin
            if (increment > (COUNT_MAX - value)) sat_add = COUNT_MAX;
            else sat_add = value + increment;
        end
    endfunction

    always @* begin
        accepted = 0;
        rejected = 0;
        slots = DEPTH - occupancy + (pop ? 1 : 0);
        pushes = 0;
        drops = 0;
        write_end = wr_ptr;
        for (i = 0; i < SOURCES; i = i + 1) begin
            write_address[i] = write_end;
            if (!rst && request[i]) begin
                if (slots > 0) begin
                    accepted[i] = 1'b1;
                    slots = slots - 1;
                    pushes = pushes + 1;
                    if (write_end == DEPTH-1) write_end = 0;
                    else write_end = write_end + 1'b1;
                end else begin
                    rejected[i] = 1'b1;
                    drops = drops + 1;
                end
            end
        end
        next_occupancy = occupancy + pushes - (pop ? 1 : 0);
    end

    // At most one accepted request targets each slot. A one-hot payload mux
    // avoids a priority mux across the entire array for every write port.
    genvar slot;
    generate for (slot = 0; slot < DEPTH; slot = slot + 1) begin : entries
        integer source;
        reg write_enable;
        reg [DATA_WIDTH-1:0] write_data;
        always @* begin
            write_enable = 1'b0;
            write_data = 0;
            for (source = 0; source < SOURCES; source = source + 1) begin
                write_data = write_data | (request_data[source*DATA_WIDTH +: DATA_WIDTH] &
                    {DATA_WIDTH{accepted[source] && write_address[source] == slot}});
                if (accepted[source] && write_address[source] == slot) begin
                    write_enable = 1'b1;
                end
            end
        end
        always @(posedge clk) begin
            if (!rst && write_enable) storage[slot] <= write_data;
        end
    end endgenerate

    always @(posedge clk) begin
        if (rst) begin
            rd_ptr <= 0;
            wr_ptr <= 0;
            occupancy <= 0;
            high_water <= 0;
            accepted_count <= 0;
            rejected_count <= 0;
            delivered_count <= 0;
        end else begin
            // A small multi-insert register queue, not a multi-port BRAM.
            // At full+pop the consumer samples the old head before replacement.
            wr_ptr <= write_end;
            if (pop) begin
                if (rd_ptr == DEPTH-1) rd_ptr <= 0;
                else rd_ptr <= rd_ptr + 1'b1;
            end
            occupancy <= next_occupancy;
            if (next_occupancy > high_water) high_water <= next_occupancy;
            accepted_count <= sat_add(accepted_count, pushes);
            rejected_count <= sat_add(rejected_count, drops);
            delivered_count <= sat_add(delivered_count, pop ? 1 : 0);
        end
    end
endmodule
