`timescale 1ns/1ps

// Original ExamGuard transaction formatter + synchronous multi-insert queue.
// All inputs are clk-domain values ALIGNED TO request (including its timestamp).
// One pulse is one attempt; rejected events are counted, never silently retried.
module event_transaction_queue #(
    parameter DEPTH = 16,
    parameter ID_WIDTH = 64,
    parameter SEPARATE_ID_RESET = 0,
    parameter COUNT_WIDTH = $clog2(DEPTH + 1)
)(
    input wire clk,
    input wire rst,
    input wire id_rst, // used only with SEPARATE_ID_RESET=1; common system reset
    input wire [3:0] request,
    input wire [63:0] request_data,
    input wire [31:0] device_id,
    input wire [31:0] boot_id,
    input wire [31:0] session_id,
    input wire [63:0] request_time_ms,
    output wire [3:0] accepted,
    output wire [3:0] rejected,
    output wire event_valid,
    input wire event_ready,
    output wire [255:0] event_data,
    output wire [COUNT_WIDTH-1:0] occupancy,
    output wire [COUNT_WIDTH-1:0] high_water,
    output wire [31:0] accepted_count,
    output reg [31:0] rejected_count,
    output wire [31:0] delivered_count,
    output wire id_exhausted
);
    localparam [63:0] ID_MAX = {64{1'b1}} >> (64-ID_WIDTH);
    reg [63:0] last_id;
    reg [3:0] eligible;
    wire [3:0] fifo_rejected;
    reg [1023:0] payload;
    reg [63:0] next_id;
    integer i, candidates, drops;

    initial begin
        if (ID_WIDTH < 1 || ID_WIDTH > 64) begin
            $error("Invalid event_transaction_queue ID_WIDTH");
            $finish;
        end
    end

    assign id_exhausted = (last_id == ID_MAX);
    assign rejected = !rst ? (fifo_rejected | (request & ~eligible)) : 4'b0;

    // Never reuse an event ID within a reset epoch. A deliberately small
    // ID_WIDTH makes the exhaustion behaviour verifiable in simulation.
    always @* begin
        eligible = 0;
        candidates = 0;
        for (i = 0; i < 4; i = i + 1) begin
            if (request[i] && !rst && (ID_MAX - last_id > candidates)) begin
                eligible[i] = 1'b1;
                candidates = candidates + 1;
            end
        end
    end

    integer source;
    always @* begin
        payload = 0;
        next_id = last_id;
        for (source = 0; source < 4; source = source + 1) begin
            if (accepted[source]) next_id = next_id + 64'd1;
            // [255:224] device, [223:192] boot, [191:160] exam session,
            // [159:96] event ID, [95:32] source time (ms), [31:24] source,
            // [23:16] reserved=0, [15:0] FSM lane (stage/auth/risk/code).
            payload[source*256 +: 256] = {device_id, boot_id, session_id,
                next_id, request_time_ms, source[7:0], 8'd0,
                request_data[source*16 +: 16]};
        end
        drops = 0;
        for (source = 0; source < 4; source = source + 1)
            if (rejected[source]) drops = drops + 1;
    end

    always @(posedge clk) begin
        if (SEPARATE_ID_RESET ? id_rst : rst) last_id <= 0;
        else last_id <= next_id;
        if (rst) begin
            rejected_count <= 0;
        end else begin
            if (32'hffffffff - rejected_count < drops)
                rejected_count <= 32'hffffffff;
            else rejected_count <= rejected_count + drops;
        end
    end

    event_request_fifo #(.SOURCES(4), .DATA_WIDTH(256), .DEPTH(DEPTH),
        .COUNT_WIDTH(COUNT_WIDTH)) queue (
        .clk(clk), .rst(rst), .request(eligible), .request_data(payload),
        .accepted(accepted), .rejected(fifo_rejected),
        .event_valid(event_valid), .event_ready(event_ready), .event_data(event_data),
        .occupancy(occupancy), .high_water(high_water),
        .accepted_count(accepted_count), .rejected_count(),
        .delivered_count(delivered_count)
    );
endmodule
