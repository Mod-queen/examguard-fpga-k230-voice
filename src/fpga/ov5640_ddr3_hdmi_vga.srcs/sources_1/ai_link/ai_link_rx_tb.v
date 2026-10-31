`timescale 1ns/1ps
////////////////////////////////////////////////////////////////////////////////////
// ai_link_rx_tb - UART bit-bangs two Yahboom ASCII frames and checks the parser.
//   face   : $00,08,10,20,30,40,Alice,87#\n
//   object : $00,14,5,6,7,8,phone#\n
// CLK 100 MHz, BAUD 10 MHz -> 100 ns per bit (fast simulation).
////////////////////////////////////////////////////////////////////////////////////
module ai_link_rx_tb;

    localparam integer BIT_NS = 100;

    reg  clk = 1'b0;
    reg  rst = 1'b1;
    reg  rx  = 1'b1;

    wire         result_valid;
    wire [1:0]   msg_type;
    wire [15:0]  bbox_x, bbox_y, bbox_w, bbox_h;
    wire [127:0] msg_text;
    wire [4:0]   msg_text_len;
    wire [7:0]   msg_score;
    wire [15:0]  frame_count;

    always #5 clk = ~clk;   // 100 MHz

    ai_link_rx #(
        .CLK_FREQ(100_000_000),
        .BAUD(10_000_000),
        .TEXT_MAX(16)
    ) dut (
        .clk         (clk),
        .rst         (rst),
        .rx          (rx),
        .result_valid(result_valid),
        .msg_type    (msg_type),
        .bbox_x      (bbox_x),
        .bbox_y      (bbox_y),
        .bbox_w      (bbox_w),
        .bbox_h      (bbox_h),
        .msg_text    (msg_text),
        .msg_text_len(msg_text_len),
        .msg_score   (msg_score),
        .frame_count (frame_count)
    );

    task send_byte;
        input [7:0] d;
        integer i;
        begin
            rx = 1'b0;                 // start bit
            #(BIT_NS);
            for (i = 0; i < 8; i = i + 1) begin
                rx = d[i];             // LSB first
                #(BIT_NS);
            end
            rx = 1'b1;                 // stop bit
            #(BIT_NS);
        end
    endtask

    task send_face_frame;
        begin
            send_byte("$"); send_byte("0"); send_byte("0"); send_byte(",");
            send_byte("0"); send_byte("8"); send_byte(",");
            send_byte("1"); send_byte("0"); send_byte(",");
            send_byte("2"); send_byte("0"); send_byte(",");
            send_byte("3"); send_byte("0"); send_byte(",");
            send_byte("4"); send_byte("0"); send_byte(",");
            send_byte("A"); send_byte("l"); send_byte("i"); send_byte("c"); send_byte("e"); send_byte(",");
            send_byte("8"); send_byte("7"); send_byte("#"); send_byte("\n");
        end
    endtask

    task send_object_frame;
        begin
            send_byte("$"); send_byte("0"); send_byte("0"); send_byte(",");
            send_byte("1"); send_byte("4"); send_byte(",");
            send_byte("5"); send_byte(",");
            send_byte("6"); send_byte(",");
            send_byte("7"); send_byte(",");
            send_byte("8"); send_byte(",");
            send_byte("p"); send_byte("h"); send_byte("o"); send_byte("n"); send_byte("e");
            send_byte("#"); send_byte("\n");
        end
    endtask

    task send_gaze_frame;
        begin
            send_byte("$"); send_byte("0"); send_byte("0"); send_byte(",");
            send_byte("0"); send_byte("7"); send_byte(",");
            send_byte("1"); send_byte("0"); send_byte("0"); send_byte(",");
            send_byte("8"); send_byte("0"); send_byte(",");
            send_byte("1"); send_byte("4"); send_byte("0"); send_byte(",");
            send_byte("1"); send_byte("2"); send_byte("0"); send_byte("#"); send_byte("\n");
        end
    endtask

    initial begin
        repeat (5) @(posedge clk);
        rst = 1'b0;
        #(BIT_NS);

        send_face_frame;
        #(BIT_NS * 4);
        if (msg_type !== 2'd1) begin
            $display("FAIL: face type expected 1 got %0d", msg_type); $finish;
        end
        if (bbox_x !== 16'd10 || bbox_y !== 16'd20 || bbox_w !== 16'd30 || bbox_h !== 16'd40) begin
            $display("FAIL: face bbox %0d %0d %0d %0d", bbox_x, bbox_y, bbox_w, bbox_h); $finish;
        end
        if (msg_text_len !== 5'd5 || msg_text[7:0] !== "A" || msg_text[39:32] !== "e") begin
            $display("FAIL: face name len=%0d b0=%c b4=%c", msg_text_len, msg_text[7:0], msg_text[39:32]); $finish;
        end
        if (msg_score !== 8'd87) begin
            $display("FAIL: face score %0d", msg_score); $finish;
        end

        send_object_frame;
        #(BIT_NS * 4);
        if (msg_type !== 2'd2) begin
            $display("FAIL: object type expected 2 got %0d", msg_type); $finish;
        end
        if (bbox_x !== 16'd5 || bbox_y !== 16'd6 || bbox_w !== 16'd7 || bbox_h !== 16'd8) begin
            $display("FAIL: object bbox %0d %0d %0d %0d", bbox_x, bbox_y, bbox_w, bbox_h); $finish;
        end
        if (msg_text_len !== 5'd5 || msg_text[7:0] !== "p" || msg_text[39:32] !== "e") begin
            $display("FAIL: object text len=%0d", msg_text_len); $finish;
        end
        if (frame_count !== 16'd2) begin
            $display("FAIL: frame_count %0d", frame_count); $finish;
        end

        send_gaze_frame;
        #(BIT_NS * 4);
        if (msg_type !== 2'd3) begin
            $display("FAIL: gaze type expected 3 got %0d", msg_type); $finish;
        end
        if (bbox_x !== 16'd100 || bbox_y !== 16'd80 ||
            bbox_w !== 16'd140 || bbox_h !== 16'd120) begin
            $display("FAIL: gaze coords %0d %0d %0d %0d", bbox_x, bbox_y, bbox_w, bbox_h); $finish;
        end
        if (frame_count !== 16'd3) begin
            $display("FAIL: frame_count %0d", frame_count); $finish;
        end

        $display("PASS: ai_link_rx (face + object + gaze frames parsed)");
        $finish;
    end

endmodule
