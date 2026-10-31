`timescale 1ns/1ps

module evidence_dump_tb;

    localparam integer CAPTURE_LENGTH = 3;
    localparam integer BIT_NS         = 140;
    localparam integer TOTAL_BYTES    = CAPTURE_LENGTH * 62 + 11;

    localparam [62*8-1:0] EXPECTED0 =
        "EV,007,00,0000000100,0000000456,1,0,1,001,010,020,000,000,000\n";
    localparam [62*8-1:0] EXPECTED2 =
        "EV,007,02,0000000102,0000000456,1,0,1,001,010,020,000,000,000\n";
    localparam [11*8-1:0] EXPECTED_EO = "EO,007,003\n";

    reg ev_clk;
    reg uart_clk;
    reg ev_rst;
    reg uart_rst;
    reg ev_start;
    reg ring_available;
    reg ring_read_valid;
    reg [131:0] ring_read_data;
    reg [7:0] ring_seq;
    wire ring_read_req;
    wire [6:0] ring_read_index;
    wire busy;
    wire uart_txd;

    reg [7:0] rx_bytes [0:511];
    integer   rx_count;
    reg [7:0] rx_shift;
    integer   bit_index;

    evidence_dump #(
        .UART_CLK_HZ    (1000000),
        .BAUD_RATE      (100000),
        .CAPTURE_LENGTH (CAPTURE_LENGTH),
        .INDEX_WIDTH    (7),
        .SEQ_WIDTH      (8)
    ) dut (
        .ev_clk          (ev_clk),
        .ev_rst          (ev_rst),
        .ev_start        (ev_start),
        .ring_available  (ring_available),
        .ring_read_valid (ring_read_valid),
        .ring_read_data  (ring_read_data),
        .ring_seq        (ring_seq),
        .ring_read_req   (ring_read_req),
        .ring_read_index (ring_read_index),
        .busy            (busy),
        .uart_clk        (uart_clk),
        .uart_rst        (uart_rst),
        .uart_txd        (uart_txd)
    );

    always #5 ev_clk   = ~ev_clk;
    always #7 uart_clk = ~uart_clk;

    // Ring stub: returns a per-index record one cycle after the request.
    always @(posedge ev_clk) begin
        if (ev_rst) begin
            ring_read_valid <= 1'b0;
            ring_read_data  <= 132'd0;
        end else begin
            ring_read_valid <= 1'b0;
            if (ring_read_req) begin
                ring_read_valid <= 1'b1;
                ring_read_data  <= {
                    32'd100 + ring_read_index,
                    32'd456,
                    4'd1,
                    4'd0,
                    4'd1,
                    8'd1,
                    8'd10,
                    8'd20,
                    8'd0,
                    8'd0,
                    8'd0,
                    8'd7
                };
            end
        end
    end

    // Minimal 8N1 receiver.
    initial begin
        rx_count = 0;
        forever begin
            @(negedge uart_txd);
            #(BIT_NS + BIT_NS / 2);
            for (bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                rx_shift[bit_index] = uart_txd;
                #(BIT_NS);
            end
            #(BIT_NS / 2);
            rx_bytes[rx_count] = rx_shift;
            rx_count = rx_count + 1;
        end
    end

    integer i;
    reg [7:0] got;
    reg [7:0] want;

    initial begin
        ev_clk = 1'b0;
        uart_clk = 1'b0;
        ev_rst = 1'b1;
        uart_rst = 1'b1;
        ev_start = 1'b0;
        ring_available = 1'b0;
        ring_read_valid = 1'b0;
        ring_read_data = 132'd0;
        ring_seq = 8'd7;
        rx_shift = 8'd0;

        repeat (4) @(negedge ev_clk);
        ev_rst = 1'b0;
        uart_rst = 1'b0;
        ring_available = 1'b1;

        repeat (4) @(negedge ev_clk);
        @(negedge ev_clk);
        ev_start = 1'b1;
        @(negedge ev_clk);
        ev_start = 1'b0;

        // Wait for the whole window with a generous timeout.
        i = 0;
        while (rx_count < TOTAL_BYTES && i < 2000000) begin
            @(negedge uart_clk);
            i = i + 1;
        end

        if (rx_count !== TOTAL_BYTES) begin
            $display("FAIL: received %0d bytes, expected %0d", rx_count, TOTAL_BYTES);
            $finish;
        end

        for (i = 0; i < 62; i = i + 1) begin
            got  = rx_bytes[i];
            want = EXPECTED0[8*(61-i) +: 8];
            if (got !== want) begin
                $display("FAIL: record0 byte %0d got %c (%02x) expected %c (%02x)",
                         i, got, got, want, want);
                $finish;
            end
        end

        for (i = 0; i < 62; i = i + 1) begin
            got  = rx_bytes[124 + i];
            want = EXPECTED2[8*(61-i) +: 8];
            if (got !== want) begin
                $display("FAIL: record2 byte %0d got %c (%02x) expected %c (%02x)",
                         i, got, got, want, want);
                $finish;
            end
        end

        for (i = 0; i < 11; i = i + 1) begin
            got  = rx_bytes[186 + i];
            want = EXPECTED_EO[8*(10-i) +: 8];
            if (got !== want) begin
                $display("FAIL: end byte %0d got %c (%02x) expected %c (%02x)",
                         i, got, got, want, want);
                $finish;
            end
        end

        if (busy !== 1'b0) begin
            i = 0;
            while (busy !== 1'b0 && i < 100000) begin
                @(negedge uart_clk);
                i = i + 1;
            end
        end
        if (busy !== 1'b0) begin
            $display("FAIL: busy stayed high after the window");
            $finish;
        end

        $display("PASS: evidence dump");
        $finish;
    end

    initial begin
        #5000000;
        $display("FAIL: simulation timeout");
        $finish;
    end

endmodule
