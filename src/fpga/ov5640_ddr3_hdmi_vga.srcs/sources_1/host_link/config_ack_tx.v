`timescale 1ns/1ps

// Sends the configuration acknowledgement line:
//
//   CA,<version>,<status>\n
//
// version is three decimal digits and status is one digit, so the host can
// match the acknowledgement to the request that produced it.
//
// The serializer advances one byte per completed UART frame. `uart_start` is
// asserted for exactly one clock, and the next byte is not loaded until the
// transmitter reports it has gone idle again; this keeps the byte index and
// the data presented to the transmitter in step.
module config_ack_tx #(
    parameter integer CLK_FREQ_HZ = 50000000,
    parameter integer BAUD_RATE   = 115200,
    parameter integer STREAM_OUTPUT=0
) (
    input             clk,
    input             rst,
    input             trigger,
    input      [7:0]  version,
    input      [2:0]  status,
    output reg        busy,
    output            uart_txd,
    output            stream_valid,stream_last,
    output [7:0]      stream_data,
    input             stream_ready
);

    localparam [1:0] A_IDLE      = 2'd0;
    localparam [1:0] A_START     = 2'd1;
    localparam [1:0] A_WAIT_BUSY = 2'd2;
    localparam [1:0] A_WAIT_DONE = 2'd3;

    localparam [7:0] LAST_INDEX = 8'd8;

    reg [1:0]  state;
    reg [7:0]  byte_index;
    reg [7:0]  packet_version;
    reg [2:0]  packet_status;

    wire       uart_busy;
    reg        uart_start;
    reg [7:0]  uart_data;

    generate if(STREAM_OUTPUT) begin: holding_stream
    uart_stream_adapter adapter(.clk(clk),.rst(rst),.tx_start(uart_start),.tx_data(uart_data),.tx_last(byte_index==LAST_INDEX),
        .tx(uart_txd),.busy(uart_busy),.stream_valid(stream_valid),.stream_data(stream_data),.stream_last(stream_last),.stream_ready(stream_ready));
    end else begin: physical_output
    assign stream_valid=0;assign stream_last=0;assign stream_data=0;
    uart_tx #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ),
        .BAUD_RATE   (BAUD_RATE)
    ) uart_tx_inst (
        .clk      (clk),
        .rst      (rst),
        .tx_start (uart_start),
        .tx_data  (uart_data),
        .tx       (uart_txd),
        .busy     (uart_busy)
    );
    end endgenerate

    function [7:0] byte_digit;
        input [7:0] value;
        input [1:0] position;
        begin
            case (position)
                2'd0:    byte_digit = 8'h30 + (value / 8'd100);
                2'd1:    byte_digit = 8'h30 + ((value / 8'd10) % 8'd10);
                default: byte_digit = 8'h30 + (value % 8'd10);
            endcase
        end
    endfunction

    always @* begin
        case (byte_index)
            8'd0: uart_data = "C";
            8'd1: uart_data = "A";
            8'd2: uart_data = ",";
            8'd3: uart_data = byte_digit(packet_version, 2'd0);
            8'd4: uart_data = byte_digit(packet_version, 2'd1);
            8'd5: uart_data = byte_digit(packet_version, 2'd2);
            8'd6: uart_data = ",";
            8'd7: uart_data = 8'h30 + {5'd0, packet_status};
            default: uart_data = 8'h0A;
        endcase
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state          <= A_IDLE;
            byte_index     <= 8'd0;
            packet_version <= 8'd0;
            packet_status  <= 3'd0;
            uart_start     <= 1'b0;
            busy           <= 1'b0;
        end else begin
            uart_start <= 1'b0;

            case (state)
                A_IDLE: begin
                    busy <= 1'b0;
                    if (trigger) begin
                        packet_version <= version;
                        packet_status  <= status;
                        byte_index     <= 8'd0;
                        busy           <= 1'b1;
                        state          <= A_START;
                    end
                end

                A_START: begin
                    // Present this byte to the transmitter for one clock.
                    uart_start <= 1'b1;
                    state      <= A_WAIT_BUSY;
                end

                A_WAIT_BUSY: begin
                    uart_start <= 1'b0;
                    if (uart_busy)
                        state <= A_WAIT_DONE;
                end

                A_WAIT_DONE: begin
                    if (!uart_busy) begin
                        if (byte_index == LAST_INDEX) begin
                            busy  <= 1'b0;
                            state <= A_IDLE;
                        end else begin
                            byte_index <= byte_index + 8'd1;
                            state      <= A_START;
                        end
                    end
                end

                default: state <= A_IDLE;
            endcase
        end
    end

endmodule
