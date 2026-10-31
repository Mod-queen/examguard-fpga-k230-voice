`timescale 1ns/1ps

module image_evidence_udp_tx_bridge_tb;

    reg clk;
    reg rst;
    reg start_frame;
    reg [7:0] event_seq;
    reg [7:0] frame_index;
    reg [15:0] frame_count;
    reg [31:0] frame_id;
    reg [31:0] timestamp_ms;
    reg [7:0] config_version;
    reg [15:0] frame_width;
    reg [15:0] frame_height;
    reg [31:0] frame_length;
    wire start_ready;
    reg frame_byte_valid;
    reg [7:0] frame_byte;
    wire frame_byte_ready;
    wire tx_en_pulse;
    reg tx_done;
    wire [15:0] data_length;
    reg payload_req;
    wire [7:0] payload_data;
    wire frame_done;

    reg [7:0] sent [0:127];
    reg [15:0] packet_lengths [0:7];
    integer sent_count;
    integer packet_count;
    integer i;
    integer wait_count;

    image_evidence_udp_tx_bridge #(
        .MAX_PAYLOAD_BYTES(4)
    ) dut (
        .clk(clk),
        .rst(rst),
        .start_frame(start_frame),
        .event_seq(event_seq),
        .frame_index(frame_index),
        .frame_count(frame_count),
        .frame_id(frame_id),
        .timestamp_ms(timestamp_ms),
        .config_version(config_version),
        .frame_width(frame_width),
        .frame_height(frame_height),
        .frame_length(frame_length),
        .start_ready(start_ready),
        .frame_byte_valid(frame_byte_valid),
        .frame_byte(frame_byte),
        .frame_byte_ready(frame_byte_ready),
        .tx_en_pulse(tx_en_pulse),
        .tx_done(tx_done),
        .data_length(data_length),
        .payload_req(payload_req),
        .payload_data(payload_data),
        .frame_done(frame_done)
    );

    always #5 clk = ~clk;

    task service_udp_packet;
        integer j;
        begin
            wait_count = 0;
            while (!tx_en_pulse && wait_count < 500) begin
                @(posedge clk);
                #1;
                wait_count = wait_count + 1;
            end
            if (!tx_en_pulse) begin
                $display("FAIL: UDP start timeout");
                $finish;
            end
            packet_lengths[packet_count] = data_length;
            packet_count = packet_count + 1;
            for (j = 0; j < data_length; j = j + 1) begin
                @(negedge clk);
                payload_req = 1'b1;
                #1;
                sent[sent_count] = payload_data;
                sent_count = sent_count + 1;
                @(posedge clk);
                @(negedge clk);
                payload_req = 1'b0;
            end
            tx_done = 1'b1;
            @(posedge clk);
            #1;
            tx_done = 1'b0;
        end
    endtask

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        start_frame = 1'b0;
        event_seq = 8'd9;
        frame_index = 8'd2;
        frame_count = 16'd3;
        frame_id = 32'd100;
        timestamp_ms = 32'd456;
        config_version = 8'd4;
        frame_width = 16'd5;
        frame_height = 16'd2;
        frame_length = 32'd10;
        frame_byte_valid = 1'b0;
        frame_byte = 8'd0;
        tx_done = 1'b0;
        payload_req = 1'b0;
        sent_count = 0;
        packet_count = 0;

        repeat (2) @(negedge clk);
        rst = 1'b0;
        @(negedge clk);
        start_frame = 1'b1;
        @(posedge clk);
        @(negedge clk);
        start_frame = 1'b0;

        for (i = 0; i < 10; i = i + 1) begin
            while (!frame_byte_ready) @(negedge clk);
            frame_byte = i[7:0];
            frame_byte_valid = 1'b1;
            @(posedge clk);
            @(negedge clk);
            frame_byte_valid = 1'b0;
            if ((i == 3) || (i == 7) || (i == 9))
                service_udp_packet;
        end

        if (packet_count !== 3 || packet_lengths[0] !== 16'd40 ||
            packet_lengths[1] !== 16'd40 || packet_lengths[2] !== 16'd38 ||
            sent_count !== 118 || sent[0] !== 8'h50 || sent[1] !== 8'h47 ||
            sent[6] !== 8'd9 || sent[7] !== 8'd2 || sent[40 + 10] !== 8'd0 ||
            sent[40 + 13] !== 8'd4 || sent[80 + 10] !== 8'd0 ||
            sent[80 + 13] !== 8'd8 || !frame_done) begin
            $display("FAIL: bridged packets=%0d lengths=%0d,%0d,%0d bytes=%0d done=%b",
                     packet_count, packet_lengths[0], packet_lengths[1],
                     packet_lengths[2], sent_count, frame_done);
            $display("DEBUG: first=%02x second_offset=%02x/%02x third_offset=%02x/%02x",
                     sent[32], sent[50], sent[53], sent[90], sent[93]);
            $finish;
        end

        $display("PASS: image evidence UDP TX bridge");
        $finish;
    end

    initial begin
        #100000;
        $display("DEBUG: bridge_state=%0d capture_count=%0d packetizer_state=%0d header_pos=%0d frame_remaining=%0d packet_len=%0d packetizer_ready=%b packetizer_valid=%b packetizer_busy=%b frame_ready=%b frame_done=%b",
                 dut.state, dut.capture_count, dut.packetizer.state,
                 dut.packetizer.header_pos, dut.packetizer.frame_remaining,
                 dut.packetizer.packet_payload_len, dut.packetizer_ready,
                 dut.packetizer_valid, dut.packetizer_busy, frame_byte_ready,
                 dut.packetizer_frame_done);
        $display("FAIL: bridge timeout");
        $finish;
    end

endmodule
