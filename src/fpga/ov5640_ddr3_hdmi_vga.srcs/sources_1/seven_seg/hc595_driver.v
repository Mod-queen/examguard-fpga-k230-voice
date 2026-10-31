`timescale 1ns/1ps

// Serializes 16 bits into the board's two cascaded 74HC595 latches.
// Bit order follows the ACX750 example set: the first bit shifted out lands in
// the far end of the chain, so the caller packs the value most-significant
// field first.
module hc595_driver #(
    parameter integer CLK_HZ  = 50000000,
    parameter integer CNT_MAX = 2
) (
    input             clk,
    input             rst,
    input      [15:0] data,
    input             s_en,
    output reg        sh_cp,
    output reg        st_cp,
    output reg        ds
);

    localparam integer CNT_SAFE = (CNT_MAX < 1) ? 1 : CNT_MAX;

    reg [15:0] r_data;

    always @(posedge clk) begin
        if (s_en)
            r_data <= data;
    end

    reg [7:0] divider_cnt;

    always @(posedge clk or posedge rst) begin
        if (rst)
            divider_cnt <= 8'd0;
        else if (divider_cnt == CNT_SAFE - 1)
            divider_cnt <= 8'd0;
        else
            divider_cnt <= divider_cnt + 8'd1;
    end

    wire sck_plus = (divider_cnt == CNT_SAFE - 1);

    reg [5:0] edge_cnt;

    always @(posedge clk or posedge rst) begin
        if (rst)
            edge_cnt <= 6'd0;
        else if (sck_plus) begin
            if (edge_cnt == 6'd32)
                edge_cnt <= 6'd0;
            else
                edge_cnt <= edge_cnt + 6'd1;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            st_cp <= 1'b0;
            ds    <= 1'b0;
            sh_cp <= 1'b0;
        end else begin
            case (edge_cnt)
                6'd0:  begin sh_cp <= 1'b0; st_cp <= 1'b0; ds <= r_data[15]; end
                6'd1:  begin sh_cp <= 1'b1; st_cp <= 1'b0; end
                6'd2:  begin sh_cp <= 1'b0; ds <= r_data[14]; end
                6'd3:  sh_cp <= 1'b1;
                6'd4:  begin sh_cp <= 1'b0; ds <= r_data[13]; end
                6'd5:  sh_cp <= 1'b1;
                6'd6:  begin sh_cp <= 1'b0; ds <= r_data[12]; end
                6'd7:  sh_cp <= 1'b1;
                6'd8:  begin sh_cp <= 1'b0; ds <= r_data[11]; end
                6'd9:  sh_cp <= 1'b1;
                6'd10: begin sh_cp <= 1'b0; ds <= r_data[10]; end
                6'd11: sh_cp <= 1'b1;
                6'd12: begin sh_cp <= 1'b0; ds <= r_data[9]; end
                6'd13: sh_cp <= 1'b1;
                6'd14: begin sh_cp <= 1'b0; ds <= r_data[8]; end
                6'd15: sh_cp <= 1'b1;
                6'd16: begin sh_cp <= 1'b0; ds <= r_data[7]; end
                6'd17: sh_cp <= 1'b1;
                6'd18: begin sh_cp <= 1'b0; ds <= r_data[6]; end
                6'd19: sh_cp <= 1'b1;
                6'd20: begin sh_cp <= 1'b0; ds <= r_data[5]; end
                6'd21: sh_cp <= 1'b1;
                6'd22: begin sh_cp <= 1'b0; ds <= r_data[4]; end
                6'd23: sh_cp <= 1'b1;
                6'd24: begin sh_cp <= 1'b0; ds <= r_data[3]; end
                6'd25: sh_cp <= 1'b1;
                6'd26: begin sh_cp <= 1'b0; ds <= r_data[2]; end
                6'd27: sh_cp <= 1'b1;
                6'd28: begin sh_cp <= 1'b0; ds <= r_data[1]; end
                6'd29: sh_cp <= 1'b1;
                6'd30: begin sh_cp <= 1'b0; ds <= r_data[0]; end
                6'd31: sh_cp <= 1'b1;
                6'd32: st_cp <= 1'b1;
                default: begin
                    st_cp <= 1'b0;
                    ds    <= 1'b0;
                    sh_cp <= 1'b0;
                end
            endcase
        end
    end

endmodule
