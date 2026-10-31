`timescale 1ns/1ps

module image_evidence_udp_packetizer_tb;

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
    wire tx_valid;
    wire [7:0] tx_data;
    wire tx_last;
    reg tx_ready;
    wire busy;
    wire frame_done;

    reg [7:0] captured [0:255];
    integer captured_count;
    integer i;
    integer payload_index;
    integer packet_index;
    integer expected_len;
    reg [31:0] crc_check;

    image_evidence_udp_packetizer #(
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
        .tx_valid(tx_valid),
        .tx_data(tx_data),
        .tx_last(tx_last),
        .tx_ready(tx_ready),
        .busy(busy),
        .frame_done(frame_done)
    );

    always #5 clk = ~clk;

    function [31:0] crc32_byte;
        input [31:0] crc_in;
        input [7:0] data_in;
        reg [31:0] c;
        reg mix;
        integer bit_index;
        begin
            c = crc_in;
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                mix = c[0] ^ data_in[bit_index];
                c = c >> 1;
                if (mix)
                    c = c ^ 32'hEDB88320;
            end
            crc32_byte = c;
        end
    endfunction

    always @(posedge clk) begin
        if (tx_valid && tx_ready) begin
            captured[captured_count] <= tx_data;
            captured_count <= captured_count + 1;
        end
    end

    task check_packet;
        input integer start;
        input integer length;
        input integer offset;
        input integer payload_length;
        integer j;
        reg [31:0] crc_value;
        begin
            if (captured[start + 0] !== 8'h50 || captured[start + 1] !== 8'h47 ||
                captured[start + 2] !== 8'd1 || captured[start + 3] !== 8'd1 ||
                captured[start + 4] !== 8'd0 || captured[start + 5] !== 8'd32 ||
                captured[start + 6] !== 8'd9 || captured[start + 7] !== 8'd2 ||
                captured[start + 8] !== 8'd0 || captured[start + 9] !== 8'd3 ||
                captured[start + 10] !== (offset >> 24) ||
                captured[start + 13] !== offset[7:0] ||
                captured[start + 14] !== (payload_length >> 8) ||
                captured[start + 15] !== payload_length[7:0]) begin
                $display("FAIL: packet header %0d", offset);
                $finish;
            end
            for (j = 0; j < payload_length; j = j + 1) begin
                if (captured[start + 32 + j] !== offset[7:0] + j[7:0]) begin
                    $display("FAIL: packet payload offset=%0d byte=%0d got=%0d",
                             offset, j, captured[start + 32 + j]);
                    $finish;
                end
            end
            crc_value = 32'hFFFFFFFF;
            for (j = 0; j < 32 + payload_length; j = j + 1)
                crc_value = crc32_byte(crc_value, captured[start + j]);
            crc_value = ~crc_value;
            if (captured[start + 32 + payload_length] !== crc_value[31:24] ||
                captured[start + 33 + payload_length] !== crc_value[23:16] ||
                captured[start + 34 + payload_length] !== crc_value[15:8] ||
                captured[start + 35 + payload_length] !== crc_value[7:0]) begin
                $display("FAIL: packet CRC offset=%0d", offset);
                $finish;
            end
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
        tx_ready = 1'b1;
        captured_count = 0;

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
        end

        i = 0;
        while (!frame_done && i < 100) begin
            @(posedge clk);
            i = i + 1;
        end
        if (!frame_done || captured_count !== 118) begin
            $display("FAIL: packet stream done=%b bytes=%0d", frame_done, captured_count);
            $finish;
        end

        check_packet(0, 40, 0, 4);
        check_packet(40, 40, 4, 4);
        check_packet(80, 38, 8, 2);
        $display("PASS: image evidence UDP packetizer");
        $finish;
    end

    initial begin
        #100000;
        $display("FAIL: packetizer timeout");
        $finish;
    end

endmodule
