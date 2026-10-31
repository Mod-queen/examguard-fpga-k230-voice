`timescale 1ns/1ps
////////////////////////////////////////////////////////////////////////////////////
// ai_link_rx - Yahboom K230 ASCII protocol parser (ExamGuard).
//
// Frame:  $ <length> , <algorithm_id> , <field0> , <field1> ... # \n   @ BAUD
//   - <length> is the whole frame char count (parsed but not enforced here).
//   - <algorithm_id> is 2 ASCII digits: 08 = face recognition,
//     14 = object detection (see docs/examguard_final_plan.md section 4.4).
//   - Fields are comma separated; '#' ends the data; '\n' ends the line.
//
// Recognised payloads:
//   07: start_x, start_y, end_x, end_y   (eye-gaze; face centre -> gaze target)
//   08: x, y, w, h, name, score
//   14: x, y, w, h, msg
//
// Outputs hold the last recognised frame and pulse result_valid for one cycle.
// This module is self-contained (its own UART receiver) and only parses; any
// authorisation policy lives above it.
////////////////////////////////////////////////////////////////////////////////////
module ai_link_rx #(
    parameter integer CLK_FREQ  = 50_000_000,
    parameter integer BAUD      = 115200,
    parameter integer TEXT_MAX  = 16
) (
    input               clk,
    input               rst,
    input               rx,

    output reg          result_valid,
    output reg  [1:0]   msg_type,       // 1 = face, 2 = object
    output reg  [15:0]  bbox_x,
    output reg  [15:0]  bbox_y,
    output reg  [15:0]  bbox_w,
    output reg  [15:0]  bbox_h,
    output reg  [(TEXT_MAX*8)-1:0] msg_text,
    output reg  [4:0]   msg_text_len,
    output reg  [7:0]   msg_score,
    output reg  [15:0]  frame_count
);

    localparam [1:0] MSG_NONE = 2'd0;
    localparam [1:0] MSG_FACE = 2'd1;
    localparam [1:0] MSG_OBJ  = 2'd2;
    localparam [1:0] MSG_GAZE = 2'd3;

    localparam integer BAUD_DIV = CLK_FREQ / BAUD;

    // ------------------------------------------------------------------ UART RX
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] rx_sync;
    always @(posedge clk) rx_sync <= {rx_sync[0], rx};
    wire rx_line = rx_sync[1];

    reg  [15:0] baud_cnt;
    reg  [3:0]  bit_idx;
    reg  [7:0]  sh;
    reg         rx_busy;
    reg  [7:0]  rx_byte;
    reg         rx_byte_valid;

    always @(posedge clk) begin
        if (rst) begin
            rx_busy       <= 1'b0;
            baud_cnt      <= 16'd0;
            bit_idx       <= 4'd0;
            sh            <= 8'd0;
            rx_byte       <= 8'd0;
            rx_byte_valid <= 1'b0;
        end else begin
            rx_byte_valid <= 1'b0;
            if (!rx_busy) begin
                if (!rx_line) begin
                    rx_busy  <= 1'b1;
                    // Wait 1.5 bit times to sample the centre of the first data bit.
                    baud_cnt <= BAUD_DIV + BAUD_DIV/2 - 1;
                    bit_idx  <= 4'd0;
                end
            end else if (baud_cnt != 0) begin
                baud_cnt <= baud_cnt - 1'b1;
            end else begin
                baud_cnt <= BAUD_DIV - 1;
                if (bit_idx < 4'd8) begin
                    sh      <= {rx_line, sh[7:1]};
                    bit_idx <= bit_idx + 1'b1;
                end else begin
                    rx_busy       <= 1'b0;
                    rx_byte       <= sh;
                    rx_byte_valid <= 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------------------- Parser
    localparam [2:0] P_IDLE = 3'd0, P_HEAD = 3'd1, P_ID = 3'd2,
                     P_FIELD = 3'd3, P_END = 3'd4;

    reg  [2:0]  pstate;
    reg  [7:0]  id_val;
    reg  [4:0]  field_idx;
    reg  [31:0] cur_num;
    reg  [15:0] num_reg [0:3];
    reg  [(TEXT_MAX*8)-1:0] text_vec;
    reg  [4:0]  text_len;

    wire [7:0] b = rx_byte;
    wire is_digit = (b >= 8'h30) && (b <= 8'h39);
    wire [7:0] digit = b - 8'h30;

    task clear_frame;
        begin
            id_val    <= 8'd0;
            field_idx <= 5'd0;
            cur_num   <= 32'd0;
            text_vec  <= {(TEXT_MAX*8){1'b0}};
            text_len  <= 5'd0;
            num_reg[0] <= 16'd0;
            num_reg[1] <= 16'd0;
            num_reg[2] <= 16'd0;
            num_reg[3] <= 16'd0;
        end
    endtask

    integer k;
    always @(posedge clk) begin
        if (rst) begin
            pstate       <= P_IDLE;
            result_valid <= 1'b0;
            msg_type     <= MSG_NONE;
            bbox_x       <= 16'd0;
            bbox_y       <= 16'd0;
            bbox_w       <= 16'd0;
            bbox_h       <= 16'd0;
            msg_text     <= {(TEXT_MAX*8){1'b0}};
            msg_text_len <= 5'd0;
            msg_score    <= 8'd0;
            frame_count  <= 16'd0;
            clear_frame;
        end else begin
            result_valid <= 1'b0;

            if (rx_byte_valid) begin
                case (pstate)
                    P_IDLE: begin
                        if (b == "$") begin
                            clear_frame;
                            pstate <= P_HEAD;
                        end
                    end

                    // <length> field: parsed but not used.
                    P_HEAD: begin
                        if (b == ",")
                            pstate <= P_ID;
                    end

                    // <algorithm_id>: 2 ASCII digits.
                    P_ID: begin
                        if (b == ",") begin
                            pstate <= P_FIELD;
                        end else if (is_digit) begin
                            id_val <= (id_val * 10) + digit;
                        end
                    end

                    P_FIELD: begin
                        if (b == "#") begin
                            // Finalise the current field, then emit.
                            if (field_idx < 5'd4)
                                num_reg[field_idx] <= cur_num[15:0];
                            // text field (4) is already accumulated

                            if (id_val == 8'd8) begin
                                msg_type  <= MSG_FACE;
                                bbox_x    <= num_reg[0];
                                bbox_y    <= num_reg[1];
                                bbox_w    <= num_reg[2];
                                bbox_h    <= num_reg[3];
                                msg_text  <= text_vec;
                                msg_text_len <= text_len;
                                msg_score <= cur_num[7:0]; // score is field 5
                                result_valid <= 1'b1;
                                frame_count  <= frame_count + 1'b1;
                            end else if (id_val == 8'd14) begin
                                msg_type  <= MSG_OBJ;
                                bbox_x    <= num_reg[0];
                                bbox_y    <= num_reg[1];
                                bbox_w    <= num_reg[2];
                                bbox_h    <= num_reg[3];
                                msg_text  <= text_vec;
                                msg_text_len <= text_len;
                                msg_score <= 8'd0;
                                result_valid <= 1'b1;
                                frame_count  <= frame_count + 1'b1;
                            end else if (id_val == 8'd7) begin
                                // All four fields are numeric and the last one
                                // is finalised by '#', so it still lives in
                                // cur_num rather than num_reg[3].
                                msg_type  <= MSG_GAZE;
                                bbox_x    <= num_reg[0];  // face centre x
                                bbox_y    <= num_reg[1];  // face centre y
                                bbox_w    <= num_reg[2];  // gaze target x
                                bbox_h    <= (field_idx == 5'd3) ? cur_num[15:0]
                                                                 : num_reg[3]; // gaze target y
                                msg_text  <= text_vec;
                                msg_text_len <= text_len;
                                msg_score <= 8'd0;
                                result_valid <= 1'b1;
                                frame_count  <= frame_count + 1'b1;
                            end else begin
                                msg_type <= MSG_NONE;
                            end
                            pstate <= P_END;
                        end else if (b == ",") begin
                            if (field_idx < 5'd4)
                                num_reg[field_idx] <= cur_num[15:0];
                            else if (field_idx == 5'd4)
                                ; // text already accumulated
                            field_idx <= field_idx + 1'b1;
                            cur_num   <= 32'd0;
                        end else begin
                            if (field_idx < 5'd4) begin
                                if (is_digit)
                                    cur_num <= (cur_num * 10) + digit;
                            end else if (field_idx == 5'd4) begin
                                if (text_len < TEXT_MAX) begin
                                    text_vec[text_len*8 +: 8] <= b;
                                    text_len <= text_len + 1'b1;
                                end
                            end else if (field_idx == 5'd5) begin
                                if (is_digit)
                                    cur_num <= (cur_num * 10) + digit;
                            end
                        end
                    end

                    P_END: begin
                        // Tolerate a missing newline: a new '$' restarts framing.
                        if (b == "$") begin
                            clear_frame;
                            pstate <= P_HEAD;
                        end else begin
                            pstate <= P_IDLE;
                        end
                    end

                    default: pstate <= P_IDLE;
                endcase
            end
        end
    end

endmodule
