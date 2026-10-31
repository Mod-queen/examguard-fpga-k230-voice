////////////////////////////////////////////////////////////////////////////////////
// overlay_status (ExamGuard full-screen variant)
//
// Removed: the three fixed ROI boxes and the three per-ROI motion bars.
// Kept: a single top status strip (risk colour / activity) and the text panel.
// The ROI/motion inputs remain in the port list for top-level compatibility but
// are no longer drawn.
////////////////////////////////////////////////////////////////////////////////////
module overlay_status #(
    parameter ENABLE = 1'b1,
    parameter BAR_HEIGHT = 12'd16
) (
    input  [23:0] pixel_in,
    input  [11:0] x,
    input  [11:0] y,
    input         de,
    // Runtime regions of interest, matching what motion_detect is using.
    input  [11:0] roi_pickup_x0,
    input  [11:0] roi_pickup_y0,
    input  [11:0] roi_pickup_x1,
    input  [11:0] roi_pickup_y1,
    input  [11:0] roi_operation_x0,
    input  [11:0] roi_operation_y0,
    input  [11:0] roi_operation_x1,
    input  [11:0] roi_operation_y1,
    input  [11:0] roi_forbidden_x0,
    input  [11:0] roi_forbidden_y0,
    input  [11:0] roi_forbidden_x1,
    input  [11:0] roi_forbidden_y1,
    input  [3:0]  stage_id,
    input  [3:0]  risk_level,
    input  [3:0]  zone_id,
    input  [7:0]  event_code,
    input         mute,
    input         alarm_active,
    input         warning_active,
    input  [7:0]  motion_pickup,
    input  [7:0]  motion_operation,
    input  [7:0]  motion_forbidden,
    input  [7:0]  motion_global,
    output reg [23:0] pixel_out
);

    reg [23:0] status_pixel;
    reg [23:0] risk_color;

    wire        text_active;
    wire [23:0] text_pixel;

    // The text panel renders stage / risk / event over the video.
    text_overlay text_overlay_inst (
        .x          (x),
        .y          (y),
        .stage_id   (stage_id),
        .risk_level (risk_level),
        .zone_id    (zone_id),
        .event_code (event_code),
        .mute       (mute),
        .text_active(text_active),
        .text_pixel (text_pixel)
    );

    // Full-width top status strip: risk colour when alarming, a white pulse on
    // whole-frame activity, dim otherwise. No per-ROI segments.
    always @* begin
        case (risk_level)
            4'd0: risk_color = 24'h20A040;
            4'd1: risk_color = 24'hD0B020;
            default: risk_color = 24'hD03030;
        endcase

        status_pixel = 24'h202830;
        if (alarm_active || warning_active)
            status_pixel = risk_color;
        else if (motion_global >= 8'd8)
            status_pixel = 24'hFFFFFF;
        else
            status_pixel = 24'h404040;

        if (ENABLE && de && (y < BAR_HEIGHT))
            pixel_out = status_pixel;
        else if (ENABLE && de && text_active)
            pixel_out = text_pixel;
        else
            pixel_out = pixel_in;
    end

endmodule
