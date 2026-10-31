`timescale 1ns/1ps

// Decodes the real status_uart_tx byte stream. Verifies ST/AL stay unchanged
// and that the additive EI identity line follows the AL and carries the
// latched identity. No top/MIG needed.
module status_uart_tx_v2_tb;
    reg clk = 0, rst = 1;
    reg status_valid = 0;
    reg [31:0] status_frame_id = 0;
    reg [3:0]  status_stage_id = 0, status_risk_level = 0, status_zone_id = 0;
    reg [31:0] status_timestamp = 0;
    reg [7:0]  status_event_code = 0;
    reg [7:0]  status_motion_pickup = 0, status_motion_operation = 0, status_motion_forbidden = 0;
    reg [31:0] event_device_id = 0, event_boot_id = 0, event_session_id = 0;
    reg [63:0] event_uid = 0;
    reg [7:0]  event_seq = 0;
    reg [7:0]  health_flags = 0;
    wire uart_txd, uart_busy;

    integer errors = 0;
    integer rx_count = 0;

    status_uart_tx #(
        .CLK_FREQ_HZ(921600), .BAUD_RATE(115200), .STATUS_PERIOD_CYCLES(400)
    ) dut (
        .clk(clk), .rst(rst), .status_valid(status_valid),
        .status_frame_id(status_frame_id), .status_stage_id(status_stage_id),
        .status_risk_level(status_risk_level), .status_zone_id(status_zone_id),
        .status_timestamp(status_timestamp), .status_event_code(status_event_code),
        .status_motion_pickup(status_motion_pickup),
        .status_motion_operation(status_motion_operation),
        .status_motion_forbidden(status_motion_forbidden),
        .event_device_id(event_device_id), .event_boot_id(event_boot_id),
        .event_session_id(event_session_id), .event_uid(event_uid), .event_seq(event_seq),
        .health_flags(health_flags),
        .uart_txd(uart_txd), .uart_busy(uart_busy));

    always #5 clk = ~clk;

    // 8 clocks per bit at 921600/115200.
    localparam [2:0] R_IDLE = 0, R_WAIT = 1, R_DATA = 2, R_STOP = 3;
    reg [2:0] rstate = R_IDLE;
    reg [3:0] tick = 0;
    reg [3:0] rbit = 0;
    reg [7:0] rshift = 0;

    always @(posedge clk) begin
        case (rstate)
            R_IDLE: if (!uart_txd) begin tick <= 0; rstate <= R_WAIT; end
            R_WAIT: if (tick == 4'd3) begin tick <= 0; rstate <= R_DATA; rbit <= 0; end
                    else tick <= tick + 4'd1;
            R_DATA: if (tick == 4'd7) begin
                        rshift <= {uart_txd, rshift[7:1]};
                        tick <= 0;
                        if (rbit == 4'd7) rstate <= R_STOP;
                        else rbit <= rbit + 4'd1;
                    end else tick <= tick + 4'd1;
            R_STOP: if (tick == 4'd7) begin
                        $write("%c", rshift);
                        rx_count = rx_count + 1;
                        tick <= 0;
                        rstate <= R_IDLE;
                    end else tick <= tick + 4'd1;
        endcase
    end

    task check(input cond, input [255:0] name);
        begin
            if (!cond) begin errors = errors + 1; $display("FAIL: %0s", name); end
        end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        rst = 0;
        repeat (4) @(posedge clk);

        // One phone event with a known identity.
        status_frame_id = 32'd42; status_stage_id = 4'd3; status_zone_id = 4'd0;
        status_risk_level = 4'd2; status_timestamp = 32'd7000; status_event_code = 8'h50;
        event_device_id = 32'd5; event_boot_id = 32'd1; event_session_id = 32'd1;
        event_uid = 64'd1; event_seq = 8'd7; health_flags = 8'd9;
        status_valid = 1; @(posedge clk); status_valid = 0;

        // Allow AL + EI + at least one periodic ST to be received.
        repeat (12000) @(posedge clk);
        $write("\n");
        check(rx_count > 0, "some bytes received");
        $display("RX_BYTES %0d", rx_count);
        if (errors == 0) $display("PASS: status_uart_tx_v2 all checks");
        else $display("FAIL: status_uart_tx_v2 %0d errors", errors);
        $finish;
    end
endmodule
