`timescale 1ns/1ps
////////////////////////////////////////////////////////////////////////////////////
// ai_mailbox_tb - authorisation and object classification checks.
////////////////////////////////////////////////////////////////////////////////////
module ai_mailbox_tb;

    localparam [127:0] ALICE    = {{(16-5){8'h00}}, "e","c","i","l","A"};
    localparam [127:0] BOB      = {{(16-3){8'h00}}, "b","o","B"};
    localparam [127:0] CAROL    = {{(16-5){8'h00}}, "l","o","r","a","C"};
    localparam [127:0] UNKNOWN  = {{(16-7){8'h00}}, "n","w","o","n","k","n","u"};
    localparam [127:0] PHONE    = {{(16-5){8'h00}}, "e","n","o","h","p"};
    localparam [127:0] EARPHONE = {{(16-8){8'h00}}, "e","n","o","h","p","r","a","e"};
    localparam [127:0] APPLE    = {{(16-5){8'h00}}, "e","l","p","p","a"};

    reg         clk = 1'b0;
    reg         rst = 1'b1;
    reg         result_valid = 1'b0;
    reg  [1:0]  msg_type = 2'd0;
    reg  [15:0] bbox_x = 16'd0, bbox_y = 16'd0, bbox_w = 16'd0, bbox_h = 16'd0;
    reg  [127:0] msg_text = 128'd0;
    reg  [4:0]  msg_text_len = 5'd0;
    reg  [7:0]  msg_score = 8'd0;

    wire        face_pulse, face_ok;
    wire [1:0]  face_id;
    wire [7:0]  face_score;
    wire        object_pulse;
    wire [2:0]  object_class;
    wire [15:0] object_x, object_y, object_w, object_h;
    wire [127:0] object_name;
    wire        gaze_pulse, gaze_away, gaze_present;

    always #5 clk = ~clk;

    ai_mailbox #(.TEXT_MAX(16)) dut (
        .clk(clk), .rst(rst),
        .result_valid(result_valid), .msg_type(msg_type),
        .bbox_x(bbox_x), .bbox_y(bbox_y), .bbox_w(bbox_w), .bbox_h(bbox_h),
        .msg_text(msg_text), .msg_text_len(msg_text_len), .msg_score(msg_score),
        .face_pulse(face_pulse), .face_ok(face_ok), .face_id(face_id), .face_score(face_score),
        .object_pulse(object_pulse), .object_class(object_class),
        .object_x(object_x), .object_y(object_y), .object_w(object_w), .object_h(object_h),
        .object_name(object_name),
        .gaze_pulse(gaze_pulse), .gaze_away(gaze_away),
        .gaze_present(gaze_present)
    );

    task feed;
        input [1:0]   t;
        input [127:0] txt;
        input [7:0]   sc;
        input [15:0]  bx, by, bw, bh;
        begin
            @(negedge clk);
            msg_type     = t;
            msg_text     = txt;
            msg_score    = sc;
            bbox_x = bx; bbox_y = by; bbox_w = bw; bbox_h = bh;
            result_valid = 1'b1;
            @(negedge clk);
            result_valid = 1'b0;
            @(negedge clk);
        end
    endtask

    initial begin
        repeat (4) @(negedge clk);
        rst = 1'b0;

        feed(2'd1, ALICE,   8'd87, 16'd0, 16'd0, 16'd0, 16'd0);
        if (!face_ok || face_id !== 2'd1 || face_score !== 8'd87) begin
            $display("FAIL: Alice not authorised (ok=%0d id=%0d)", face_ok, face_id); $finish;
        end

        feed(2'd1, BOB,     8'd90, 16'd0, 16'd0, 16'd0, 16'd0);
        if (!face_ok || face_id !== 2'd2) begin
            $display("FAIL: Bob not authorised id=%0d", face_id); $finish;
        end

        feed(2'd1, CAROL,   8'd80, 16'd0, 16'd0, 16'd0, 16'd0);
        if (!face_ok || face_id !== 2'd3) begin
            $display("FAIL: Carol not authorised id=%0d", face_id); $finish;
        end

        feed(2'd1, UNKNOWN, 8'd0,  16'd0, 16'd0, 16'd0, 16'd0);
        if (face_ok || face_id !== 2'd0) begin
            $display("FAIL: unknown was authorised id=%0d", face_id); $finish;
        end

        feed(2'd2, PHONE,    8'd0, 16'd1, 16'd2, 16'd3, 16'd4);
        if (object_class !== 3'd1 || object_x !== 16'd1 || object_h !== 16'd4) begin
            $display("FAIL: phone class=%0d", object_class); $finish;
        end

        feed(2'd2, EARPHONE, 8'd0, 16'd0, 16'd0, 16'd0, 16'd0);
        if (object_class !== 3'd3) begin
            $display("FAIL: earphone class=%0d", object_class); $finish;
        end

        feed(2'd2, APPLE,    8'd0, 16'd0, 16'd0, 16'd0, 16'd0);
        if (object_class !== 3'd0) begin
            $display("FAIL: apple class=%0d", object_class); $finish;
        end

        // Gaze (07): centred -> pulse but not turned.
        @(negedge clk);
        msg_type = 2'd3; bbox_x = 16'd100; bbox_y = 16'd100;
        bbox_w = 16'd110; bbox_h = 16'd110; result_valid = 1'b1;
        @(negedge clk);
        if (!gaze_pulse || gaze_away || !gaze_present) begin
            $display("FAIL: gaze centred pulse=%0d away=%0d present=%0d",
                     gaze_pulse, gaze_away, gaze_present); $finish;
        end
        @(negedge clk); result_valid = 1'b0;

        // Gaze turned (dx = 600 > 300).
        @(negedge clk);
        bbox_x = 16'd100; bbox_y = 16'd100; bbox_w = 16'd700; bbox_h = 16'd120;
        result_valid = 1'b1;
        @(negedge clk);
        if (!gaze_pulse || !gaze_away || !gaze_present) begin
            $display("FAIL: gaze turned not detected"); $finish;
        end
        @(negedge clk); result_valid = 1'b0;

        // No face (all zero) -> not turned.
        @(negedge clk);
        bbox_x = 16'd0; bbox_y = 16'd0; bbox_w = 16'd0; bbox_h = 16'd0;
        result_valid = 1'b1;
        @(negedge clk);
        if (gaze_away || gaze_present) begin
            $display("FAIL: zero gaze flagged (away=%0d present=%0d)", gaze_away, gaze_present);
            $finish;
        end
        @(negedge clk); result_valid = 1'b0;

        $display("PASS: ai_mailbox (auth ids + object classes)");
        feed(2'd2, {96'd0, "e","n","o","n"}, 8'd0, 16'd0, 16'd0, 16'd0, 16'd0);
        if (object_class !== 3'd7) $fatal(1, "explicit absence not classified");
        $display("PASS: ai_mailbox explicit none");
        $finish;
    end

endmodule
