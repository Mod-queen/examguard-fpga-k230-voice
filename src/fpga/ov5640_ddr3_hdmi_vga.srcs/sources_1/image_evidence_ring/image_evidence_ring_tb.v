`timescale 1ns/1ps

module image_evidence_ring_tb;

    localparam integer FRAME_PIXELS = 8;
    localparam integer PRE_FRAMES = 2;
    localparam integer POST_FRAMES = 2;

    reg clk;
    reg rst;
    reg sample_valid;
    reg frame_last;
    reg [2:0] sample_pixel_index;
    reg [7:0] sample_pixel;
    reg [31:0] sample_frame_id;
    reg [31:0] sample_timestamp_ms;
    reg [7:0] sample_config_version;
    reg [7:0] sample_event_seq;
    reg event_trigger;
    reg readout_active;
    wire frame_busy;
    wire frame_done;
    wire frame_available;
    wire image_evidence_overrun;
    wire [7:0] snapshot_event_seq;
    reg read_req;
    reg [2:0] read_frame_index;
    reg [2:0] read_pixel_index;
    wire read_valid;
    wire [7:0] read_pixel;
    wire [31:0] read_frame_id;
    wire [31:0] read_timestamp_ms;
    wire [7:0] read_config_version;

    image_evidence_ring #(
        .FRAME_WIDTH(4),
        .FRAME_HEIGHT(2),
        .PIXEL_WIDTH(8),
        .PRE_FRAMES(PRE_FRAMES),
        .POST_FRAMES(POST_FRAMES),
        .RING_DEPTH(8)
    ) dut (
        .clk(clk),
        .rst(rst),
        .sample_valid(sample_valid),
        .frame_last(frame_last),
        .sample_pixel_index(sample_pixel_index),
        .sample_pixel(sample_pixel),
        .sample_frame_id(sample_frame_id),
        .sample_timestamp_ms(sample_timestamp_ms),
        .sample_config_version(sample_config_version),
        .sample_event_seq(sample_event_seq),
        .event_trigger(event_trigger),
        .readout_active(readout_active),
        .frame_busy(frame_busy),
        .frame_done(frame_done),
        .frame_available(frame_available),
        .image_evidence_overrun(image_evidence_overrun),
        .snapshot_event_seq(snapshot_event_seq),
        .read_req(read_req),
        .read_frame_index(read_frame_index),
        .read_pixel_index(read_pixel_index),
        .read_valid(read_valid),
        .read_pixel(read_pixel),
        .read_frame_id(read_frame_id),
        .read_timestamp_ms(read_timestamp_ms),
        .read_config_version(read_config_version)
    );

    always #5 clk = ~clk;

    task write_frame;
        input [31:0] frame_value;
        input trigger_value;
        integer pixel;
        begin
            for (pixel = 0; pixel < FRAME_PIXELS; pixel = pixel + 1) begin
                @(negedge clk);
                sample_valid = 1'b1;
                frame_last = (pixel == FRAME_PIXELS - 1);
                sample_pixel_index = pixel[2:0];
                sample_pixel = frame_value[7:0] + pixel[7:0];
                sample_frame_id = frame_value;
                sample_timestamp_ms = frame_value * 100;
                sample_config_version = frame_value[7:0] + 8'd1;
                sample_event_seq = trigger_value ? 8'd7 : 8'd0;
                event_trigger = trigger_value && frame_last;
                @(posedge clk);
            end
            @(negedge clk);
            sample_valid = 1'b0;
            frame_last = 1'b0;
            event_trigger = 1'b0;
        end
    endtask

    task read_pixel_at;
        input [2:0] frame_index_value;
        input [2:0] pixel_index_value;
        input [31:0] expected_frame;
        input [7:0] expected_pixel;
        begin
            @(negedge clk);
            read_frame_index = frame_index_value;
            read_pixel_index = pixel_index_value;
            read_req = 1'b1;
            @(posedge clk);
            #1;
            if (!read_valid || read_frame_id !== expected_frame ||
                read_pixel !== expected_pixel ||
                read_timestamp_ms !== expected_frame * 100 ||
                read_config_version !== expected_frame[7:0] + 8'd1) begin
                $display("FAIL: frame=%0d pixel=%0d valid=%b id=%0d pixel=%0d ts=%0d cfg=%0d",
                         frame_index_value, pixel_index_value, read_valid,
                         read_frame_id, read_pixel, read_timestamp_ms,
                         read_config_version);
                $finish;
            end
            read_req = 1'b0;
        end
    endtask

    integer pixel;
    reg test_done;
    initial begin
        clk = 1'b0;
        rst = 1'b1;
        sample_valid = 1'b0;
        frame_last = 1'b0;
        sample_pixel_index = 3'd0;
        sample_pixel = 8'd0;
        sample_frame_id = 32'd0;
        sample_timestamp_ms = 32'd0;
        sample_config_version = 8'd0;
        sample_event_seq = 8'd0;
        event_trigger = 1'b0;
        readout_active = 1'b0;
        read_req = 1'b0;
        read_frame_index = 3'd0;
        read_pixel_index = 3'd0;
        test_done = 1'b0;

        repeat (2) @(negedge clk);
        rst = 1'b0;

        write_frame(32'd0, 1'b0);
        write_frame(32'd1, 1'b0);
        write_frame(32'd2, 1'b1);
        if (!frame_busy || snapshot_event_seq !== 8'd7) begin
            $display("FAIL: trigger did not lock the image window");
            $finish;
        end

        // A second trigger during the post window must not replace it.
        write_frame(32'd3, 1'b1);
        if (!image_evidence_overrun) begin
            $display("FAIL: overlapping image event was not reported");
            $finish;
        end
        write_frame(32'd4, 1'b0);
        if (frame_busy || !frame_done || !frame_available) begin
            $display("FAIL: image window did not complete");
            $finish;
        end

        // Hold the snapshot while it is read and reject a new trigger.
        readout_active = 1'b1;
        write_frame(32'd5, 1'b1);
        if (!image_evidence_overrun) begin
            $display("FAIL: trigger during image readout was not reported");
            $finish;
        end

        for (pixel = 0; pixel < FRAME_PIXELS; pixel = pixel + 1) begin
            read_pixel_at(3'd0, pixel[2:0], 32'd0, pixel[7:0]);
            read_pixel_at(3'd1, pixel[2:0], 32'd1, 8'd1 + pixel[7:0]);
            read_pixel_at(3'd2, pixel[2:0], 32'd2, 8'd2 + pixel[7:0]);
            read_pixel_at(3'd3, pixel[2:0], 32'd3, 8'd3 + pixel[7:0]);
            read_pixel_at(3'd4, pixel[2:0], 32'd4, 8'd4 + pixel[7:0]);
        end
        readout_active = 1'b0;

        test_done = 1'b1;
        $display("PASS: image evidence ring");
        $finish;
    end

    initial begin
        #100000;
        if (!test_done)
            $display("FAIL: image evidence ring simulation timeout");
        $finish;
    end

endmodule
