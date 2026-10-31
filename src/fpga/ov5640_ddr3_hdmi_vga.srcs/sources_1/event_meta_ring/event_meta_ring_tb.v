`timescale 1ns/1ps

module event_meta_ring_tb;

    localparam integer RECORD_WIDTH = 132;

    reg clk;
    reg rst;
    reg sample_valid;
    reg [31:0] sample_frame_id;
    reg [31:0] sample_timestamp_ms;
    reg [3:0] sample_stage_id;
    reg [3:0] sample_risk_level;
    reg [3:0] sample_zone_id;
    reg [7:0] sample_event_code;
    reg [7:0] sample_motion_pickup;
    reg [7:0] sample_motion_operation;
    reg [7:0] sample_motion_forbidden;
    reg [7:0] sample_config_version;
    reg [7:0] sample_health_flags;
    reg [7:0] sample_event_seq;
    reg event_trigger;
    reg readout_active;
    wire event_busy;
    wire event_done;
    wire event_available;
    wire event_overrun;
    wire [7:0] snapshot_event_seq;
    reg read_req;
    reg [2:0] read_index;
    wire read_valid;
    wire [RECORD_WIDTH-1:0] read_data;

    event_meta_ring #(
        .ADDR_WIDTH(4),
        .PRE_SAMPLES(2),
        .POST_SAMPLES(2)
    ) dut (
        .clk(clk),
        .rst(rst),
        .sample_valid(sample_valid),
        .sample_frame_id(sample_frame_id),
        .sample_timestamp_ms(sample_timestamp_ms),
        .sample_stage_id(sample_stage_id),
        .sample_risk_level(sample_risk_level),
        .sample_zone_id(sample_zone_id),
        .sample_event_code(sample_event_code),
        .sample_motion_pickup(sample_motion_pickup),
        .sample_motion_operation(sample_motion_operation),
        .sample_motion_forbidden(sample_motion_forbidden),
        .sample_config_version(sample_config_version),
        .sample_health_flags(sample_health_flags),
        .sample_event_seq(sample_event_seq),
        .event_trigger(event_trigger),
        .readout_active(readout_active),
        .event_busy(event_busy),
        .event_done(event_done),
        .event_available(event_available),
        .event_overrun(event_overrun),
        .snapshot_event_seq(snapshot_event_seq),
        .read_req(read_req),
        .read_index(read_index),
        .read_valid(read_valid),
        .read_data(read_data)
    );

    always #5 clk = ~clk;

    task write_sample;
        input [31:0] frame_value;
        input trigger_value;
        begin
            @(negedge clk);
            sample_frame_id = frame_value;
            sample_timestamp_ms = frame_value * 10;
            sample_event_seq = trigger_value ? 8'd7 : 8'd0;
            event_trigger = trigger_value;
            sample_valid = 1'b1;
            @(posedge clk);
            #1;
            sample_valid = 1'b0;
            event_trigger = 1'b0;
        end
    endtask

    task read_sample;
        input [2:0] index_value;
        input [31:0] expected_frame;
        begin
            @(negedge clk);
            read_index = index_value;
            read_req = 1'b1;
            @(posedge clk);
            #1;
            if (!read_valid || read_data[131:100] !== expected_frame) begin
                $display("FAIL: read index %0d expected frame %0d got valid=%b frame=%0d",
                         index_value, expected_frame, read_valid, read_data[131:100]);
                $finish;
            end
            read_req = 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        sample_valid = 1'b0;
        sample_frame_id = 32'd0;
        sample_timestamp_ms = 32'd0;
        sample_stage_id = 4'd1;
        sample_risk_level = 4'd0;
        sample_zone_id = 4'd1;
        sample_event_code = 8'd0;
        sample_motion_pickup = 8'd10;
        sample_motion_operation = 8'd20;
        sample_motion_forbidden = 8'd30;
        sample_config_version = 8'd2;
        sample_health_flags = 8'd0;
        sample_event_seq = 8'd0;
        event_trigger = 1'b0;
        readout_active = 1'b0;
        read_req = 1'b0;
        read_index = 3'd0;

        repeat (2) @(negedge clk);
        rst = 1'b0;

        write_sample(32'd0, 1'b0);
        write_sample(32'd1, 1'b0);
        write_sample(32'd2, 1'b0);
        write_sample(32'd3, 1'b1);
        if (!event_busy || snapshot_event_seq !== 8'd7) begin
            $display("FAIL: event trigger was not captured");
            $finish;
        end

        // A second trigger during the post window must not replace the first.
        write_sample(32'd4, 1'b1);
        if (!event_overrun) begin
            $display("FAIL: overlapping event was not reported");
            $finish;
        end
        write_sample(32'd5, 1'b0);
        if (event_busy || !event_done || !event_available) begin
            $display("FAIL: event window did not complete");
            $finish;
        end

        // While a readout is in progress a new trigger must not replace the
        // snapshot or clear the read path, or the stream would stall forever.
        readout_active = 1'b1;
        write_sample(32'd6, 1'b1);
        if (!event_overrun) begin
            $display("FAIL: trigger during readout was not reported");
            $finish;
        end

        read_sample(3'd0, 32'd1);
        read_sample(3'd1, 32'd2);
        read_sample(3'd2, 32'd3);
        read_sample(3'd3, 32'd4);
        read_sample(3'd4, 32'd5);
        readout_active = 1'b0;

        $display("PASS: metadata evidence ring");
        $finish;
    end

endmodule
