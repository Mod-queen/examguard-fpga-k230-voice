`timescale 1ns/1ps

// Periodic ST packet and event-driven AL packet transmitter.
// Numeric fields use fixed-width decimal digits. Leading zeroes are accepted
// by the host decoder and keep the serializer deterministic in hardware.
//
// Protocol v2 (additive): after each AL event line the module emits one EI
// (event identity) line carrying device/boot/session/event-uid as fixed-width
// hexadecimal. ST and AL bytes are unchanged, so a v1 host that ignores the
// extra EI line keeps working. EI hex is self-delimiting; fields are never
// negative and carry no separators beyond the comma.
module status_uart_tx #(
    parameter integer CLK_FREQ_HZ          = 50000000,
    parameter integer BAUD_RATE            = 115200,
    parameter integer STATUS_PERIOD_CYCLES = 5000000,
    parameter integer ENABLE_TIMER = 0,
    parameter integer ENABLE_EVIDENCE_HEALTH = 0,
    parameter integer STREAM_OUTPUT = 0
) (
    input         clk,
    input         rst,
    input         status_valid,
    input  [31:0] status_frame_id,
    input  [3:0]  status_stage_id,
    input  [3:0]  status_risk_level,
    input  [3:0]  status_zone_id,
    input  [31:0] status_timestamp,
    input  [7:0]  status_event_code,
    input  [7:0]  status_motion_pickup,
    input  [7:0]  status_motion_operation,
    input  [7:0]  status_motion_forbidden,
    // Event identity snapshot (v2). Latched with the AL it belongs to.
    input  [31:0] event_device_id,
    input  [31:0] event_boot_id,
    input  [31:0] event_session_id,
    input  [63:0] event_uid,
    // Same per-event sequence the image evidence window carries, so a host can
    // bind an AL/EI to its window exactly instead of by time+frame only.
    input  [7:0]  event_seq,
    // C04: health flags appended to each ST packet. Zero is fully healthy.
    input  [7:0]  health_flags,
    // v2.3: same clk-domain exam FSM timer used by the seven-segment display.
    input  [15:0] remaining_s,
    input  [15:0] exam_duration_s,
    input  [1023:0] evidence_health_data,
    output        uart_txd,
    output        uart_busy,
    output        stream_valid,stream_last,
    output [7:0]  stream_data,
    input         stream_ready
);

    localparam integer STATUS_PERIOD_SAFE =
        (STATUS_PERIOD_CYCLES < 1) ? 1 : STATUS_PERIOD_CYCLES;

    localparam [2:0] TX_IDLE          = 3'd0;
    localparam [2:0] TX_CONVERT_START = 3'd1;
    localparam [2:0] TX_CONVERT_WAIT  = 3'd2;
    localparam [2:0] TX_SEND          = 3'd3;

    reg [2:0] tx_state;
    reg [31:0] status_timer;
    reg        status_due;
    reg        have_status;

    reg [31:0] latest_frame_id;
    reg [3:0]  latest_stage_id;
    reg [3:0]  latest_risk_level;
    reg [3:0]  latest_zone_id;
    reg [31:0] latest_timestamp;
    reg [7:0]  latest_event_code;
    reg [7:0]  latest_motion_pickup;
    reg [7:0]  latest_motion_operation;
    reg [7:0]  latest_motion_forbidden;
    reg [15:0] latest_remaining_s, latest_duration_s;

    reg [7:0]  event_active_code;
    reg        event_pending;
    reg [31:0] pending_frame_id;
    reg [3:0]  pending_stage_id;
    reg [3:0]  pending_risk_level;
    reg [3:0]  pending_zone_id;
    reg [31:0] pending_timestamp;
    reg [7:0]  pending_event_code;
    reg [31:0] pending_device_id;
    reg [31:0] pending_boot_id;
    reg [31:0] pending_session_id;
    reg [63:0] pending_uid;
    reg [7:0]  pending_seq;
    reg [7:0]  pending_health;

    reg        packet_is_event;
    reg        packet_is_identity;
    reg [31:0] packet_frame_id;
    reg [3:0]  packet_stage_id;
    reg [3:0]  packet_risk_level;
    reg [3:0]  packet_zone_id;
    reg [31:0] packet_timestamp;
    reg [7:0]  packet_event_code;
    reg [7:0]  packet_motion_pickup;
    reg [7:0]  packet_motion_operation;
    reg [7:0]  packet_motion_forbidden;
    reg [31:0] packet_device_id;
    reg [31:0] packet_boot_id;
    reg [31:0] packet_session_id;
    reg [63:0] packet_uid;
    reg [7:0]  packet_seq;
    reg [7:0]  packet_health;
    reg [15:0] packet_remaining_s, packet_duration_s;
    reg [8:0]  byte_index;
    reg [1023:0] packet_evidence_health;

    wire        frame_bcd_start;
    wire        timestamp_bcd_start;
    wire        frame_bcd_busy;
    wire        timestamp_bcd_busy;
    wire        frame_bcd_done;
    wire        timestamp_bcd_done;
    wire [39:0] frame_bcd;
    wire [39:0] timestamp_bcd;
    wire [39:0] remaining_bcd, duration_bcd;
    wire remaining_done, duration_done;
    u32_to_bcd remaining_converter (
        .clk(clk), .rst(rst), .start(frame_bcd_start), .value({16'd0,packet_remaining_s}),
        .busy(), .done(remaining_done), .digits(remaining_bcd));
    u32_to_bcd duration_converter (
        .clk(clk), .rst(rst), .start(frame_bcd_start), .value({16'd0,packet_duration_s}),
        .busy(), .done(duration_done), .digits(duration_bcd));

    assign frame_bcd_start     = (tx_state == TX_CONVERT_START);
    assign timestamp_bcd_start = (tx_state == TX_CONVERT_START);

    u32_to_bcd frame_converter (
        .clk    (clk),
        .rst    (rst),
        .start  (frame_bcd_start),
        .value  (packet_frame_id),
        .busy   (frame_bcd_busy),
        .done   (frame_bcd_done),
        .digits (frame_bcd)
    );

    u32_to_bcd timestamp_converter (
        .clk    (clk),
        .rst    (rst),
        .start  (timestamp_bcd_start),
        .value  (packet_timestamp),
        .busy   (timestamp_bcd_busy),
        .done   (timestamp_bcd_done),
        .digits (timestamp_bcd)
    );

    wire       uart_start;
    reg  [7:0] uart_data;

    assign uart_start = (tx_state == TX_SEND) && !uart_busy;

    wire packet_last_byte=(packet_is_identity && byte_index==50) ||
        (!packet_is_identity && !packet_is_event && byte_index==(ENABLE_EVIDENCE_HEALTH ? 319 : ENABLE_TIMER ? 62 : 50));
    generate if(STREAM_OUTPUT) begin: holding_stream
        uart_stream_adapter adapter(.clk(clk),.rst(rst),.tx_start(uart_start),.tx_data(uart_data),.tx_last(packet_last_byte),
            .tx(uart_txd),.busy(uart_busy),.stream_valid(stream_valid),.stream_data(stream_data),.stream_last(stream_last),.stream_ready(stream_ready));
    end else begin: physical_output
    assign stream_valid=1'b0;assign stream_data=0;assign stream_last=0;
    uart_tx #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .BAUD_RATE   (BAUD_RATE)
    ) uart_tx_inst (
        .clk       (clk),
        .rst       (rst),
        .tx_start  (uart_start),
        .tx_data   (uart_data),
        .tx        (uart_txd),
        .busy      (uart_busy)
    );
    end endgenerate

    function [7:0] nibble_ascii;
        input [3:0] value;
        begin
            nibble_ascii = 8'h30 + value;
        end
    endfunction

    function [7:0] byte_digit;
        input [7:0] value;
        input [1:0] position;
        begin
            case (position)
                2'd0: byte_digit = 8'h30 + (value / 8'd100);
                2'd1: byte_digit = 8'h30 + ((value / 8'd10) % 8'd10);
                default: byte_digit = 8'h30 + (value % 8'd10);
            endcase
        end
    endfunction

    function [7:0] bcd_ascii;
        input [39:0] value;
        input [3:0]  position;
        begin
            case (position)
                4'd0: bcd_ascii = 8'h30 + value[39:36];
                4'd1: bcd_ascii = 8'h30 + value[35:32];
                4'd2: bcd_ascii = 8'h30 + value[31:28];
                4'd3: bcd_ascii = 8'h30 + value[27:24];
                4'd4: bcd_ascii = 8'h30 + value[23:20];
                4'd5: bcd_ascii = 8'h30 + value[19:16];
                4'd6: bcd_ascii = 8'h30 + value[15:12];
                4'd7: bcd_ascii = 8'h30 + value[11:8];
                4'd8: bcd_ascii = 8'h30 + value[7:4];
                default: bcd_ascii = 8'h30 + value[3:0];
            endcase
        end
    endfunction

    // One hex nibble: 0-9 then A-F, always uppercase.
    function [7:0] hex_digit;
        input [3:0] value;
        begin
            hex_digit = (value < 4'd10) ? (8'h30 + value) : (8'h41 + value - 4'd10);
        end
    endfunction

    always @* begin
        uart_data = 8'h20;

        if (packet_is_identity) begin
            // EI,<device:8>,<boot:8>,<session:8>,<uid:16>\n
            case (byte_index)
                7'd0:  uart_data = "E";
                7'd1:  uart_data = "I";
                7'd2:  uart_data = ",";
                7'd3:  uart_data = hex_digit(packet_device_id[31:28]);
                7'd4:  uart_data = hex_digit(packet_device_id[27:24]);
                7'd5:  uart_data = hex_digit(packet_device_id[23:20]);
                7'd6:  uart_data = hex_digit(packet_device_id[19:16]);
                7'd7:  uart_data = hex_digit(packet_device_id[15:12]);
                7'd8:  uart_data = hex_digit(packet_device_id[11:8]);
                7'd9:  uart_data = hex_digit(packet_device_id[7:4]);
                7'd10: uart_data = hex_digit(packet_device_id[3:0]);
                7'd11: uart_data = ",";
                7'd12: uart_data = hex_digit(packet_boot_id[31:28]);
                7'd13: uart_data = hex_digit(packet_boot_id[27:24]);
                7'd14: uart_data = hex_digit(packet_boot_id[23:20]);
                7'd15: uart_data = hex_digit(packet_boot_id[19:16]);
                7'd16: uart_data = hex_digit(packet_boot_id[15:12]);
                7'd17: uart_data = hex_digit(packet_boot_id[11:8]);
                7'd18: uart_data = hex_digit(packet_boot_id[7:4]);
                7'd19: uart_data = hex_digit(packet_boot_id[3:0]);
                7'd20: uart_data = ",";
                7'd21: uart_data = hex_digit(packet_session_id[31:28]);
                7'd22: uart_data = hex_digit(packet_session_id[27:24]);
                7'd23: uart_data = hex_digit(packet_session_id[23:20]);
                7'd24: uart_data = hex_digit(packet_session_id[19:16]);
                7'd25: uart_data = hex_digit(packet_session_id[15:12]);
                7'd26: uart_data = hex_digit(packet_session_id[11:8]);
                7'd27: uart_data = hex_digit(packet_session_id[7:4]);
                7'd28: uart_data = hex_digit(packet_session_id[3:0]);
                7'd29: uart_data = ",";
                7'd30: uart_data = hex_digit(packet_uid[63:60]);
                7'd31: uart_data = hex_digit(packet_uid[59:56]);
                7'd32: uart_data = hex_digit(packet_uid[55:52]);
                7'd33: uart_data = hex_digit(packet_uid[51:48]);
                7'd34: uart_data = hex_digit(packet_uid[47:44]);
                7'd35: uart_data = hex_digit(packet_uid[43:40]);
                7'd36: uart_data = hex_digit(packet_uid[39:36]);
                7'd37: uart_data = hex_digit(packet_uid[35:32]);
                7'd38: uart_data = hex_digit(packet_uid[31:28]);
                7'd39: uart_data = hex_digit(packet_uid[27:24]);
                7'd40: uart_data = hex_digit(packet_uid[23:20]);
                7'd41: uart_data = hex_digit(packet_uid[19:16]);
                7'd42: uart_data = hex_digit(packet_uid[15:12]);
                7'd43: uart_data = hex_digit(packet_uid[11:8]);
                7'd44: uart_data = hex_digit(packet_uid[7:4]);
                7'd45: uart_data = hex_digit(packet_uid[3:0]);
                7'd46: uart_data = ",";
                7'd47: uart_data = byte_digit(packet_seq, 2'd0);
                7'd48: uart_data = byte_digit(packet_seq, 2'd1);
                7'd49: uart_data = byte_digit(packet_seq, 2'd2);
                default: uart_data = 8'h0a;
            endcase
        end else if (packet_is_event) begin
            case (byte_index)
                7'd0:  uart_data = "A";
                7'd1:  uart_data = "L";
                7'd2:  uart_data = ",";
                7'd3:  uart_data = bcd_ascii(frame_bcd, 4'd0);
                7'd4:  uart_data = bcd_ascii(frame_bcd, 4'd1);
                7'd5:  uart_data = bcd_ascii(frame_bcd, 4'd2);
                7'd6:  uart_data = bcd_ascii(frame_bcd, 4'd3);
                7'd7:  uart_data = bcd_ascii(frame_bcd, 4'd4);
                7'd8:  uart_data = bcd_ascii(frame_bcd, 4'd5);
                7'd9:  uart_data = bcd_ascii(frame_bcd, 4'd6);
                7'd10: uart_data = bcd_ascii(frame_bcd, 4'd7);
                7'd11: uart_data = bcd_ascii(frame_bcd, 4'd8);
                7'd12: uart_data = bcd_ascii(frame_bcd, 4'd9);
                7'd13: uart_data = ",";
                7'd14: uart_data = bcd_ascii(timestamp_bcd, 4'd0);
                7'd15: uart_data = bcd_ascii(timestamp_bcd, 4'd1);
                7'd16: uart_data = bcd_ascii(timestamp_bcd, 4'd2);
                7'd17: uart_data = bcd_ascii(timestamp_bcd, 4'd3);
                7'd18: uart_data = bcd_ascii(timestamp_bcd, 4'd4);
                7'd19: uart_data = bcd_ascii(timestamp_bcd, 4'd5);
                7'd20: uart_data = bcd_ascii(timestamp_bcd, 4'd6);
                7'd21: uart_data = bcd_ascii(timestamp_bcd, 4'd7);
                7'd22: uart_data = bcd_ascii(timestamp_bcd, 4'd8);
                7'd23: uart_data = bcd_ascii(timestamp_bcd, 4'd9);
                7'd24: uart_data = ",";
                7'd25: uart_data = nibble_ascii(packet_stage_id);
                7'd26: uart_data = ",";
                7'd27: uart_data = nibble_ascii(packet_zone_id);
                7'd28: uart_data = ",";
                7'd29: uart_data = nibble_ascii(packet_risk_level);
                7'd30: uart_data = ",";
                7'd31: uart_data = byte_digit(packet_event_code, 2'd0);
                7'd32: uart_data = byte_digit(packet_event_code, 2'd1);
                7'd33: uart_data = byte_digit(packet_event_code, 2'd2);
                default: uart_data = 8'h0a;
            endcase
        end else begin
            case (byte_index)
                7'd0:  uart_data = "S";
                7'd1:  uart_data = "T";
                7'd2:  uart_data = ",";
                7'd3:  uart_data = bcd_ascii(frame_bcd, 4'd0);
                7'd4:  uart_data = bcd_ascii(frame_bcd, 4'd1);
                7'd5:  uart_data = bcd_ascii(frame_bcd, 4'd2);
                7'd6:  uart_data = bcd_ascii(frame_bcd, 4'd3);
                7'd7:  uart_data = bcd_ascii(frame_bcd, 4'd4);
                7'd8:  uart_data = bcd_ascii(frame_bcd, 4'd5);
                7'd9:  uart_data = bcd_ascii(frame_bcd, 4'd6);
                7'd10: uart_data = bcd_ascii(frame_bcd, 4'd7);
                7'd11: uart_data = bcd_ascii(frame_bcd, 4'd8);
                7'd12: uart_data = bcd_ascii(frame_bcd, 4'd9);
                7'd13: uart_data = ",";
                7'd14: uart_data = nibble_ascii(packet_stage_id);
                7'd15: uart_data = ",";
                7'd16: uart_data = nibble_ascii(packet_risk_level);
                7'd17: uart_data = ",";
                7'd18: uart_data = nibble_ascii(packet_zone_id);
                7'd19: uart_data = ",";
                7'd20: uart_data = bcd_ascii(timestamp_bcd, 4'd0);
                7'd21: uart_data = bcd_ascii(timestamp_bcd, 4'd1);
                7'd22: uart_data = bcd_ascii(timestamp_bcd, 4'd2);
                7'd23: uart_data = bcd_ascii(timestamp_bcd, 4'd3);
                7'd24: uart_data = bcd_ascii(timestamp_bcd, 4'd4);
                7'd25: uart_data = bcd_ascii(timestamp_bcd, 4'd5);
                7'd26: uart_data = bcd_ascii(timestamp_bcd, 4'd6);
                7'd27: uart_data = bcd_ascii(timestamp_bcd, 4'd7);
                7'd28: uart_data = bcd_ascii(timestamp_bcd, 4'd8);
                7'd29: uart_data = bcd_ascii(timestamp_bcd, 4'd9);
                7'd30: uart_data = ",";
                7'd31: uart_data = byte_digit(packet_event_code, 2'd0);
                7'd32: uart_data = byte_digit(packet_event_code, 2'd1);
                7'd33: uart_data = byte_digit(packet_event_code, 2'd2);
                7'd34: uart_data = ",";
                7'd35: uart_data = byte_digit(packet_motion_pickup, 2'd0);
                7'd36: uart_data = byte_digit(packet_motion_pickup, 2'd1);
                7'd37: uart_data = byte_digit(packet_motion_pickup, 2'd2);
                7'd38: uart_data = ",";
                7'd39: uart_data = byte_digit(packet_motion_operation, 2'd0);
                7'd40: uart_data = byte_digit(packet_motion_operation, 2'd1);
                7'd41: uart_data = byte_digit(packet_motion_operation, 2'd2);
                7'd42: uart_data = ",";
                7'd43: uart_data = byte_digit(packet_motion_forbidden, 2'd0);
                7'd44: uart_data = byte_digit(packet_motion_forbidden, 2'd1);
                7'd45: uart_data = byte_digit(packet_motion_forbidden, 2'd2);
                7'd46: uart_data = ",";
                7'd47: uart_data = byte_digit(packet_health, 2'd0);
                7'd48: uart_data = byte_digit(packet_health, 2'd1);
                7'd49: uart_data = byte_digit(packet_health, 2'd2);
                7'd50: uart_data = ENABLE_TIMER ? "," : 8'h0a;
                7'd51: uart_data = bcd_ascii(remaining_bcd, 4'd5);
                7'd52: uart_data = bcd_ascii(remaining_bcd, 4'd6);
                7'd53: uart_data = bcd_ascii(remaining_bcd, 4'd7);
                7'd54: uart_data = bcd_ascii(remaining_bcd, 4'd8);
                7'd55: uart_data = bcd_ascii(remaining_bcd, 4'd9);
                7'd56: uart_data = ",";
                7'd57: uart_data = bcd_ascii(duration_bcd, 4'd5);
                7'd58: uart_data = bcd_ascii(duration_bcd, 4'd6);
                7'd59: uart_data = bcd_ascii(duration_bcd, 4'd7);
                7'd60: uart_data = bcd_ascii(duration_bcd, 4'd8);
                7'd61: uart_data = bcd_ascii(duration_bcd, 4'd9);
                7'd62: uart_data = ENABLE_EVIDENCE_HEALTH ? "," : 8'h0a;
                default: begin
                    if(ENABLE_EVIDENCE_HEALTH && byte_index>=63 && byte_index<319)
                        uart_data=hex_digit(packet_evidence_health[1023-(byte_index-63)*4 -: 4]);
                    else uart_data=8'h0a;
                end
            endcase
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            tx_state                <= TX_IDLE;
            status_timer            <= 32'd0;
            status_due              <= 1'b0;
            have_status             <= 1'b0;
            latest_frame_id         <= 32'd0;
            latest_stage_id         <= 4'd0;
            latest_risk_level       <= 4'd0;
            latest_zone_id          <= 4'd0;
            latest_timestamp        <= 32'd0;
            latest_event_code       <= 8'd0;
            latest_motion_pickup    <= 8'd0;
            latest_motion_operation <= 8'd0;
            latest_motion_forbidden <= 8'd0;
            event_active_code       <= 8'd0;
            event_pending           <= 1'b0;
            pending_frame_id        <= 32'd0;
            pending_stage_id        <= 4'd0;
            pending_risk_level      <= 4'd0;
            pending_zone_id         <= 4'd0;
            pending_timestamp       <= 32'd0;
            pending_event_code      <= 8'd0;
            pending_device_id       <= 32'd0;
            pending_boot_id         <= 32'd0;
            pending_session_id      <= 32'd0;
            pending_uid             <= 64'd0;
            pending_seq             <= 8'd0;
            pending_health          <= 8'd0;
            packet_is_event         <= 1'b0;
            packet_is_identity      <= 1'b0;
            packet_frame_id         <= 32'd0;
            packet_stage_id         <= 4'd0;
            packet_risk_level       <= 4'd0;
            packet_zone_id          <= 4'd0;
            packet_timestamp        <= 32'd0;
            packet_event_code       <= 8'd0;
            packet_motion_pickup    <= 8'd0;
            packet_motion_operation <= 8'd0;
            packet_motion_forbidden <= 8'd0;
            packet_device_id        <= 32'd0;
            packet_boot_id          <= 32'd0;
            packet_session_id       <= 32'd0;
            packet_uid              <= 64'd0;
            packet_seq              <= 8'd0;
            packet_health           <= 8'd0;
            byte_index              <= 7'd0;
            latest_remaining_s <= 0; latest_duration_s <= 0;
            packet_remaining_s <= 0; packet_duration_s <= 0;
            packet_evidence_health<=0;
        end else begin
            if (have_status && !status_due) begin
                if (status_timer >= STATUS_PERIOD_SAFE - 1) begin
                    status_timer <= 32'd0;
                    status_due   <= 1'b1;
                end else begin
                    status_timer <= status_timer + 32'd1;
                end
            end

            if (tx_state == TX_IDLE) begin
                if (event_pending) begin
                    packet_is_event         <= 1'b1;
                    packet_is_identity      <= 1'b0;
                    packet_frame_id         <= pending_frame_id;
                    packet_stage_id         <= pending_stage_id;
                    packet_risk_level       <= pending_risk_level;
                    packet_zone_id          <= pending_zone_id;
                    packet_timestamp        <= pending_timestamp;
                    packet_event_code       <= pending_event_code;
                    packet_motion_pickup    <= 8'd0;
                    packet_motion_operation <= 8'd0;
                    packet_motion_forbidden <= 8'd0;
                    packet_device_id        <= pending_device_id;
                    packet_boot_id          <= pending_boot_id;
                    packet_session_id       <= pending_session_id;
                    packet_uid              <= pending_uid;
                    packet_seq              <= pending_seq;
                    byte_index              <= 7'd0;
                    event_pending           <= 1'b0;
                    tx_state                <= TX_CONVERT_START;
                end else if (status_due && have_status) begin
                    packet_is_event         <= 1'b0;
                    packet_is_identity      <= 1'b0;
                    packet_frame_id         <= latest_frame_id;
                    packet_stage_id         <= latest_stage_id;
                    packet_risk_level       <= latest_risk_level;
                    packet_zone_id          <= latest_zone_id;
                    packet_timestamp        <= latest_timestamp;
                    packet_event_code       <= latest_event_code;
                    packet_motion_pickup    <= latest_motion_pickup;
                    packet_motion_operation <= latest_motion_operation;
                    packet_motion_forbidden <= latest_motion_forbidden;
                    packet_health           <= pending_health;
                    packet_remaining_s      <= latest_remaining_s;
                    packet_duration_s       <= latest_duration_s;
                    packet_evidence_health  <= evidence_health_data;
                    byte_index              <= 7'd0;
                    status_due              <= 1'b0;
                    status_timer            <= 32'd0;
                    tx_state                <= TX_CONVERT_START;
                end
            end else if (tx_state == TX_CONVERT_START) begin
                tx_state <= TX_CONVERT_WAIT;
            end else if (tx_state == TX_CONVERT_WAIT) begin
                if (frame_bcd_done && timestamp_bcd_done && (!ENABLE_TIMER || (remaining_done && duration_done)))
                    tx_state <= TX_SEND;
            end else if (tx_state == TX_SEND) begin
                if (!uart_busy) begin
                    if (packet_is_identity && (byte_index == 7'd50)) begin
                        // EI done; only here does the line really finish.
                        packet_is_identity <= 1'b0;
                        byte_index         <= 7'd0;
                        tx_state           <= TX_IDLE;
                    end else if (packet_is_event && (byte_index == 7'd34)) begin
                        // AL done; the v2 identity line always follows it.
                        packet_is_event    <= 1'b0;
                        packet_is_identity <= 1'b1;
                        byte_index         <= 7'd0;
                        tx_state           <= TX_SEND;
                    end else if (!packet_is_event && !packet_is_identity &&
                                   (byte_index == (ENABLE_EVIDENCE_HEALTH ? 9'd319 : ENABLE_TIMER ? 9'd62 : 9'd50))) begin
                        byte_index <= 7'd0;
                        tx_state   <= TX_IDLE;
                    end else begin
                        byte_index <= byte_index + 9'd1;
                    end
                end
            end

            // Update the latest snapshot after scheduling so an event arriving
            // on the same clock is retained rather than cleared by a launch.
            if (status_valid) begin
                latest_frame_id         <= status_frame_id;
                latest_stage_id         <= status_stage_id;
                latest_risk_level       <= status_risk_level;
                latest_zone_id          <= status_zone_id;
                latest_timestamp        <= status_timestamp;
                latest_event_code       <= status_event_code;
                latest_motion_pickup    <= status_motion_pickup;
                latest_motion_operation <= status_motion_operation;
                latest_motion_forbidden <= status_motion_forbidden;
                have_status             <= 1'b1;
                pending_health          <= health_flags;
                latest_remaining_s      <= remaining_s;
                latest_duration_s       <= exam_duration_s;

                if (status_event_code == 8'd0) begin
                    event_active_code <= 8'd0;
                end else if (status_event_code != event_active_code) begin
                    event_active_code <= status_event_code;
                    event_pending     <= 1'b1;
                    pending_frame_id  <= status_frame_id;
                    pending_stage_id  <= status_stage_id;
                    pending_risk_level <= status_risk_level;
                    pending_zone_id   <= status_zone_id;
                    pending_timestamp <= status_timestamp;
                    pending_event_code <= status_event_code;
                    pending_device_id <= event_device_id;
                    pending_boot_id   <= event_boot_id;
                    pending_session_id <= event_session_id;
                    pending_uid       <= event_uid;
                    pending_seq       <= event_seq;
                end
            end
        end
    end

endmodule
