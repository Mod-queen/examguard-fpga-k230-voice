`timescale 1ns/1ps
////////////////////////////////////////////////////////////////////////////////////
// ai_mailbox - turn raw ai_link_rx results into ExamGuard decisions.
//
// Face (algorithm 08): compare the received name against up to 3 authorised
//   names. face_ok / face_id tell the exam FSM whether the candidate is one of
//   the registered people. Anything else (including "unknown") is rejected.
//
// Object (algorithm 14): pass the bbox through and classify the object name
//   into one of up to 4 configured prohibited keywords.
//
// Names are compared as little-endian packed ASCII: character 0 sits in the
// low byte, matching ai_link_rx's msg_text layout. Text is zero padded, so a
// full-width == comparison also enforces the name length.
////////////////////////////////////////////////////////////////////////////////////
module ai_mailbox #(
    parameter integer TEXT_MAX = 16,

    // Authorised face names, little-endian ("Alice", "Bob", "Carol").
    parameter [8*TEXT_MAX-1:0] AUTH0_NAME = { {(TEXT_MAX-5){8'h00}}, "e","c","i","l","A" },
    parameter [8*TEXT_MAX-1:0] AUTH1_NAME = { {(TEXT_MAX-3){8'h00}}, "b","o","B" },
    parameter [8*TEXT_MAX-1:0] AUTH2_NAME = { {(TEXT_MAX-5){8'h00}}, "l","o","r","a","C" },

    // Prohibited object keywords, little-endian.
    parameter [8*TEXT_MAX-1:0] OBJ0_NAME = { {(TEXT_MAX-5){8'h00}}, "e","n","o","h","p" },        // phone
    parameter [8*TEXT_MAX-1:0] OBJ1_NAME = { {(TEXT_MAX-5){8'h00}}, "s","e","t","o","n" },        // notes
    parameter [8*TEXT_MAX-1:0] OBJ2_NAME = { {(TEXT_MAX-8){8'h00}}, "e","n","o","h","p","r","a","e" }, // earphone
    parameter [8*TEXT_MAX-1:0] OBJ3_NAME = { {(TEXT_MAX-5){8'h00}}, "h","c","t","a","w" },        // watch

    // Gaze (algorithm 07): |target - face centre| above this many pixels
    // (1280-wide protocol units) counts as a head/gaze turn. Raised to 300 so
    // mild head/eye motion (dx ~50-200) is not counted as looking away.
    parameter [15:0] GAZE_THRESHOLD = 16'd300
) (
    input               clk,
    input               rst,

    // From ai_link_rx (same clock domain).
    input               result_valid,
    input  [1:0]        msg_type,       // 1 = face, 2 = object
    input  [15:0]       bbox_x,
    input  [15:0]       bbox_y,
    input  [15:0]       bbox_w,
    input  [15:0]       bbox_h,
    input  [8*TEXT_MAX-1:0] msg_text,
    input  [4:0]        msg_text_len,
    input  [7:0]        msg_score,

    // Face decision.
    output reg          face_pulse,
    output reg          face_ok,
    output reg  [1:0]   face_id,        // 0 = unknown, 1..3 = authorised
    output reg  [7:0]   face_score,

    // Object decision.
    output reg          object_pulse,
    output reg  [2:0]   object_class,   // 0 = other, 1..4 = keywords, 7 = explicit none
    output reg  [15:0]  object_x,
    output reg  [15:0]  object_y,
    output reg  [15:0]  object_w,
    output reg  [15:0]  object_h,
    output reg  [8*TEXT_MAX-1:0] object_name,

    // Gaze decision.
    output reg          gaze_pulse,
    output reg          gaze_away,
    output reg          gaze_present     // a face was detected in this 07 frame
);

    localparam [1:0] MSG_FACE = 2'd1;
    localparam [1:0] MSG_OBJ  = 2'd2;
    localparam [1:0] MSG_GAZE = 2'd3;

    wire match_auth0 = (msg_text == AUTH0_NAME);
    wire match_auth1 = (msg_text == AUTH1_NAME);
    wire match_auth2 = (msg_text == AUTH2_NAME);

    wire match_obj0 = (msg_text == OBJ0_NAME);
    wire match_obj1 = (msg_text == OBJ1_NAME);
    wire match_obj2 = (msg_text == OBJ2_NAME);
    wire match_obj3 = (msg_text == OBJ3_NAME);
    wire match_none = (msg_text == { {(TEXT_MAX-4){8'h00}}, "e","n","o","n" });

    // Gaze magnitude: |end - start| on each axis. An all-zero frame (no face)
    // gives 0, i.e. "centred/absent".
    wire [15:0] gaze_dx = (bbox_w >= bbox_x) ? (bbox_w - bbox_x) : (bbox_x - bbox_w);
    wire [15:0] gaze_dy = (bbox_h >= bbox_y) ? (bbox_h - bbox_y) : (bbox_y - bbox_h);
    wire        gaze_turned = (gaze_dx > GAZE_THRESHOLD) || (gaze_dy > GAZE_THRESHOLD);
    // Reporter.gaze sends an all-zero frame when no face was found.
    wire        gaze_face = (bbox_x != 16'd0) || (bbox_y != 16'd0);

    always @(posedge clk) begin
        if (rst) begin
            face_pulse   <= 1'b0;
            face_ok      <= 1'b0;
            face_id      <= 2'd0;
            face_score   <= 8'd0;
            object_pulse <= 1'b0;
            object_class <= 3'd0;
            object_x     <= 16'd0;
            object_y     <= 16'd0;
            object_w     <= 16'd0;
            object_h     <= 16'd0;
            object_name  <= {(8*TEXT_MAX){1'b0}};
            gaze_pulse   <= 1'b0;
            gaze_away    <= 1'b0;
            gaze_present <= 1'b0;
        end else begin
            face_pulse   <= 1'b0;
            object_pulse <= 1'b0;
            gaze_pulse   <= 1'b0;
            gaze_away    <= 1'b0;
            gaze_present <= 1'b0;

            if (result_valid && msg_type == MSG_FACE) begin
                face_pulse <= 1'b1;
                face_score <= msg_score;
                if (match_auth0) begin
                    face_ok <= 1'b1; face_id <= 2'd1;
                end else if (match_auth1) begin
                    face_ok <= 1'b1; face_id <= 2'd2;
                end else if (match_auth2) begin
                    face_ok <= 1'b1; face_id <= 2'd3;
                end else begin
                    face_ok <= 1'b0; face_id <= 2'd0;
                end
            end else if (result_valid && msg_type == MSG_OBJ) begin
                object_pulse <= 1'b1;
                object_x     <= bbox_x;
                object_y     <= bbox_y;
                object_w     <= bbox_w;
                object_h     <= bbox_h;
                object_name  <= msg_text;
                if (match_obj0)      object_class <= 3'd1;
                else if (match_obj1) object_class <= 3'd2;
                else if (match_obj2) object_class <= 3'd3;
                else if (match_obj3) object_class <= 3'd4;
                else if (match_none) object_class <= 3'd7;
                else                 object_class <= 3'd0;
            end else if (result_valid && msg_type == MSG_GAZE) begin
                gaze_pulse   <= 1'b1;
                gaze_away    <= gaze_turned;
                gaze_present <= gaze_face;
            end
        end
    end

endmodule
