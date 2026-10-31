`timescale 1ns/1ps

// Parses one configuration line per frame from the host:
//
//   RC,<region>,<x0>,<y0>,<x1>,<y1>,<threshold>\n
//
// Fields are decimal. The FPGA owns the configuration version: it increments
// on every accepted request, so the host can always read back which revision
// produced a given event. A rejected request never changes the stored version
// and never reaches the ROI logic.
module config_rx #(
    parameter integer H_ACTIVE = 1280,
    parameter integer V_ACTIVE = 720,
    parameter integer MAX_THRESHOLD = 255
) (
    input             clk,
    input             rst,
    input             valid,
    input      [7:0]  data,
    output reg        cfg_we,
    output reg [1:0]  cfg_region,
    output reg [11:0] cfg_x0,
    output reg [11:0] cfg_y0,
    output reg [11:0] cfg_x1,
    output reg [11:0] cfg_y1,
    output reg [7:0]  cfg_thr,
    output reg [7:0]  cfg_version,
    output reg [2:0]  cfg_status
);

    localparam [2:0] ST_OK        = 3'd0;
    localparam [2:0] ST_BAD_REGION = 3'd1;
    localparam [2:0] ST_BAD_X     = 3'd2;
    localparam [2:0] ST_BAD_Y     = 3'd3;
    localparam [2:0] ST_BAD_THR   = 3'd4;
    localparam [2:0] ST_MALFORMED = 3'd5;

    localparam [7:0] CH_R = 8'h52;
    localparam [7:0] CH_C = 8'h43;
    localparam [7:0] CH_COMMA = 8'h2C;
    localparam [7:0] CH_CR = 8'h0D;
    localparam [7:0] CH_LF = 8'h0A;

    reg [1:0]  prefix_cnt;
    reg        prefix_done;
    reg [2:0]  field;
    reg [15:0] acc;
    reg        commit_q;
    reg [15:0] fv [0:5];
    reg [7:0]  version_reg;

    wire [7:0] next_version = version_reg + 8'd1;

    integer i;

    // Validation of the assembled request.
    wire [15:0] r_region = fv[0];
    wire [15:0] r_x0 = fv[1];
    wire [15:0] r_y0 = fv[2];
    wire [15:0] r_x1 = fv[3];
    wire [15:0] r_y1 = fv[4];
    wire [15:0] r_thr = fv[5];

    wire region_ok = (r_region >= 16'd1) && (r_region <= 16'd3);
    wire x_ok = (r_x1 > r_x0) && (r_x1 <= H_ACTIVE);
    wire y_ok = (r_y1 > r_y0) && (r_y1 <= V_ACTIVE);
    wire thr_ok = (r_thr <= MAX_THRESHOLD);

    wire [2:0] evaluated_status = !region_ok ? ST_BAD_REGION :
                                  !x_ok      ? ST_BAD_X :
                                  !y_ok      ? ST_BAD_Y :
                                  !thr_ok    ? ST_BAD_THR : ST_OK;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            prefix_cnt  <= 2'd0;
            prefix_done <= 1'b0;
            field       <= 3'd0;
            acc         <= 16'd0;
            commit_q    <= 1'b0;
            cfg_we      <= 1'b0;
            cfg_region  <= 2'd0;
            cfg_x0      <= 12'd0;
            cfg_y0      <= 12'd0;
            cfg_x1      <= 12'd0;
            cfg_y1      <= 12'd0;
            cfg_thr     <= 8'd0;
            cfg_version <= 8'd0;
            cfg_status  <= ST_OK;
            version_reg <= 8'd0;
            for (i = 0; i < 6; i = i + 1)
                fv[i] <= 16'd0;
        end else begin
            cfg_we   <= 1'b0;
            commit_q <= 1'b0;

            if (commit_q) begin
                cfg_status <= evaluated_status;
                cfg_we     <= 1'b1;
                if (evaluated_status == ST_OK) begin
                    cfg_region  <= r_region[1:0];
                    cfg_x0      <= r_x0[11:0];
                    cfg_y0      <= r_y0[11:0];
                    cfg_x1      <= r_x1[11:0];
                    cfg_y1      <= r_y1[11:0];
                    cfg_thr     <= r_thr[7:0];
                    cfg_version <= next_version;
                    version_reg <= next_version;
                end else begin
                    cfg_version <= version_reg;
                end
            end else if (valid) begin
                if (!prefix_done) begin
                    case (prefix_cnt)
                        2'd0: prefix_cnt <= (data == CH_R) ? 2'd1 : 2'd0;
                        2'd1: prefix_cnt <= (data == CH_C) ? 2'd2 : 2'd0;
                        default: begin
                            if (data == CH_COMMA) begin
                                prefix_done <= 1'b1;
                                field       <= 3'd0;
                                acc         <= 16'd0;
                            end else begin
                                prefix_cnt <= 2'd0;
                            end
                        end
                    endcase
                end else if (data == CH_CR) begin
                    // ignore
                end else if (data == CH_LF) begin
                    if (field == 3'd5) begin
                        fv[5]    <= acc;
                        commit_q <= 1'b1;
                    end else begin
                        // wrong field count
                        cfg_status  <= ST_MALFORMED;
                        cfg_we      <= 1'b1;
                    end
                    prefix_done <= 1'b0;
                    prefix_cnt  <= 2'd0;
                    field       <= 3'd0;
                    acc         <= 16'd0;
                end else if ((data >= 8'h30) && (data <= 8'h39)) begin
                    if (acc < 16'd10000)
                        acc <= (acc * 16'd10) + {8'd0, (data - 8'h30)};
                end else if (data == CH_COMMA) begin
                    if (field < 3'd5) begin
                        fv[field] <= acc;
                        field     <= field + 3'd1;
                        acc       <= 16'd0;
                    end else begin
                        cfg_status  <= ST_MALFORMED;
                        cfg_we      <= 1'b1;
                        prefix_done <= 1'b0;
                        field       <= 3'd0;
                        acc         <= 16'd0;
                    end
                end else begin
                    // unexpected character ends the attempt
                    prefix_done <= 1'b0;
                    prefix_cnt  <= 2'd0;
                    field       <= 3'd0;
                    acc         <= 16'd0;
                end
            end
        end
    end

endmodule
