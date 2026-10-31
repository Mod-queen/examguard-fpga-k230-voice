`timescale 1ns / 1ps

module event_request_fifo_case #(parameter DEPTH = 3, SOURCES = 3, WIDTH = 32)(output reg done = 0);
    localparam CW = $clog2(DEPTH+1);
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg [SOURCES-1:0] request = 0;
    reg [SOURCES*WIDTH-1:0] request_data = 0;
    reg event_ready = 0;
    wire [SOURCES-1:0] accepted, rejected;
    wire event_valid;
    wire [WIDTH-1:0] event_data;
    wire [CW-1:0] occupancy, high_water;
    wire [7:0] accepted_count, rejected_count, delivered_count;
    event_request_fifo #(.SOURCES(SOURCES), .DATA_WIDTH(WIDTH), .DEPTH(DEPTH),
        .COUNTER_WIDTH(8)) dut (.*);

    // Reference is a shifting list, independent of DUT circular pointers.
    reg [WIDTH-1:0] expected [0:DEPTH-1];
    integer size = 0, peak = 0, total_in = 0, total_drop = 0, total_out = 0;
    integer full_pop = 0, collisions = 0, stalled = 0;
    integer j, k;
    reg [SOURCES-1:0] want_accept, want_reject;
    reg [31:0] rng = 32'h19ab3571 + DEPTH;

    task step;
        input reset_value;
        input [SOURCES-1:0] requests;
        input ready_value;
        input [31:0] payload;
        begin
            @(negedge clk);
            rst = reset_value;
            request = requests;
            event_ready = ready_value;
            for (k = 0; k < SOURCES; k = k+1) request_data[k*WIDTH +: WIDTH] = {WIDTH/32{payload+k}};
            #1;
            want_accept = 0;
            want_reject = 0;
            if (event_valid !== (!rst && size != 0))
                $fatal(1, "depth %0d: valid", DEPTH);
            if (!rst) begin
                if (size != 0) begin
                    if (event_data !== expected[0])
                        $fatal(1, "depth %0d: payload/order", DEPTH);
                    if (ready_value) begin
                        if (size == DEPTH && requests != 0) full_pop = full_pop + 1;
                        for (j = 0; j < size-1; j = j+1) expected[j] = expected[j+1];
                        size = size - 1;
                        if (total_out < 255) total_out = total_out + 1;
                    end else stalled = stalled + 1;
                end
                if ((requests & (requests-1)) != 0) collisions = collisions + 1;
                for (k = 0; k < SOURCES; k = k+1) begin
                    if (requests[k]) begin
                        if (size < DEPTH) begin
                            want_accept[k] = 1;
                            expected[size] = {WIDTH/32{payload+k}};
                            size = size + 1;
                            if (total_in < 255) total_in = total_in + 1;
                        end else begin
                            want_reject[k] = 1;
                            if (total_drop < 255) total_drop = total_drop + 1;
                        end
                    end
                end
                if (size > peak) peak = size;
            end else begin
                size = 0; peak = 0;
                total_in = 0; total_drop = 0; total_out = 0;
            end
            if (accepted !== want_accept || rejected !== want_reject)
                $fatal(1, "depth %0d: acceptance/accounting", DEPTH);
            @(posedge clk); #1;
            if (occupancy !== size || high_water !== peak ||
                accepted_count !== total_in || rejected_count !== total_drop ||
                delivered_count !== total_out)
                $fatal(1, "depth %0d: counters/occupancy", DEPTH);
        end
    endtask

    integer n;
    initial begin
        step(1, 7, 1, 0); // reset masks requests and output
        step(0, 0, 1, 0); // empty dequeue
        for (n = 0; n < DEPTH+2; n = n+1) step(0, {SOURCES{1'b1}}, 0, 32'h5000+n*SOURCES);
        step(0, {SOURCES{1'b1}}, 1, 32'h6000); // full + pop + burst
        for (n = 0; n < DEPTH+2; n = n+1) step(0, 0, 1, 0);
        for (n = 0; n < 20; n = n+1) step(0, 1, 1, 32'h6464); // identical retriggers
        step(0, 7, 0, 32'h7000);
        step(1, 7, 1, 0); // reset nonempty, discard old generation
        for (n = 0; n < 6000; n = n+1) begin
            rng = rng * 32'd1664525 + 32'd1013904223;
            step(0, rng[16 +: SOURCES], rng[24], n*SOURCES);
        end
        for (n = 0; n < DEPTH+2; n = n+1) step(0, 0, 1, 0);
        if (size != 0 || total_in != 255 || (SOURCES > 1 && total_drop != 255) || (SOURCES == 1 && total_drop == 0) ||
            total_out != 255 || full_pop == 0 || (SOURCES > 1 && collisions == 0) || stalled == 0)
            $fatal(1, "depth %0d: coverage/saturation", DEPTH);
        $display("PASS event_request_fifo depth=%0d full_pop=%0d collisions=%0d stalled=%0d",
                 DEPTH, full_pop, collisions, stalled);
        done = 1;
    end
endmodule

module event_request_fifo_optimized_tb;
    wire d1, d3, d8, d16, s1, s3, s8, s16;
    reg all_pass = 0;
    event_request_fifo_case #(.DEPTH(1)) c1(d1);
    event_request_fifo_case #(.DEPTH(3)) c3(d3);
    event_request_fifo_case #(.DEPTH(8)) c8(d8);
    event_request_fifo_case #(.DEPTH(16), .SOURCES(4)) c16(d16);
    event_request_fifo_case #(.DEPTH(1), .SOURCES(1), .WIDTH(256)) single1(s1);
    event_request_fifo_case #(.DEPTH(3), .SOURCES(1), .WIDTH(256)) single3(s3);
    event_request_fifo_case #(.DEPTH(8), .SOURCES(1), .WIDTH(256)) single8(s8);
    event_request_fifo_case #(.DEPTH(16), .SOURCES(1), .WIDTH(256)) single16(s16);
    initial begin
        wait(s1 && s3 && s8 && s16 && d1 && d3 && d8 && d16);
        all_pass = 1;
        $display("PASS event_request_fifo_tb ALL");
        $finish;
    end
    initial begin
        #200000;
        $fatal(1, "watchdog timeout");
    end
endmodule
