`timescale 1ns/1ps

// Sequential double-dabble converter. The result is ten packed BCD digits,
// ordered from most significant to least significant.
module u32_to_bcd (
    input         clk,
    input         rst,
    input         start,
    input  [31:0] value,
    output reg    busy,
    output reg    done,
    output reg [39:0] digits
);

    reg [31:0] value_shift;
    reg [39:0] bcd;
    reg [5:0]  bit_count;
    function [38:0] add_three_to_digits;
        input [39:0] value;
        reg [39:0] result;
        begin
            result = value;

            if (result[3:0] >= 4'd5)
                result[3:0] = result[3:0] + 4'd3;
            if (result[7:4] >= 4'd5)
                result[7:4] = result[7:4] + 4'd3;
            if (result[11:8] >= 4'd5)
                result[11:8] = result[11:8] + 4'd3;
            if (result[15:12] >= 4'd5)
                result[15:12] = result[15:12] + 4'd3;
            if (result[19:16] >= 4'd5)
                result[19:16] = result[19:16] + 4'd3;
            if (result[23:20] >= 4'd5)
                result[23:20] = result[23:20] + 4'd3;
            if (result[27:24] >= 4'd5)
                result[27:24] = result[27:24] + 4'd3;
            if (result[31:28] >= 4'd5)
                result[31:28] = result[31:28] + 4'd3;
            if (result[35:32] >= 4'd5)
                result[35:32] = result[35:32] + 4'd3;
            if (result[39:36] >= 4'd5)
                result[39:36] = result[39:36] + 4'd3;

            // The next double-dabble shift discards result[39].
            add_three_to_digits = result[38:0];
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            value_shift <= 32'd0;
            bcd         <= 40'd0;
            bit_count   <= 6'd0;
            busy        <= 1'b0;
            done        <= 1'b0;
            digits      <= 40'd0;
        end else begin
            done <= 1'b0;

            if (start && !busy) begin
                value_shift <= value;
                bcd         <= 40'd0;
                bit_count   <= 6'd0;
                busy        <= 1'b1;
            end else if (busy) begin
                bcd         <= {add_three_to_digits(bcd), value_shift[31]};
                value_shift <= {value_shift[30:0], 1'b0};

                if (bit_count == 6'd31) begin
                    digits <= {add_three_to_digits(bcd), value_shift[31]};
                    busy   <= 1'b0;
                    done   <= 1'b1;
                end else begin
                    bit_count <= bit_count + 6'd1;
                end
            end
        end
    end

endmodule
