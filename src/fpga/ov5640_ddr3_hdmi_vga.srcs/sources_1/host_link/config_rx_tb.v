`timescale 1ns/1ps

module config_rx_tb;

    reg        clk;
    reg        rst;
    reg        valid;
    reg  [7:0] data;
    wire       cfg_we;
    wire [1:0] cfg_region;
    wire [11:0] cfg_x0;
    wire [11:0] cfg_y0;
    wire [11:0] cfg_x1;
    wire [11:0] cfg_y1;
    wire [7:0] cfg_thr;
    wire [7:0] cfg_version;
    wire [2:0] cfg_status;

    reg [8*40-1:0] msg;

    reg [2:0]  seen_status;
    reg [1:0]  seen_region;
    reg [11:0] seen_x0, seen_y0, seen_x1, seen_y1;
    reg [7:0]  seen_thr;
    reg [7:0]  seen_version;
    integer    we_count;

    config_rx #(
        .H_ACTIVE (1280),
        .V_ACTIVE (720)
    ) dut (
        .clk        (clk),
        .rst        (rst),
        .valid      (valid),
        .data       (data),
        .cfg_we     (cfg_we),
        .cfg_region (cfg_region),
        .cfg_x0     (cfg_x0),
        .cfg_y0     (cfg_y0),
        .cfg_x1     (cfg_x1),
        .cfg_y1     (cfg_y1),
        .cfg_thr    (cfg_thr),
        .cfg_version(cfg_version),
        .cfg_status (cfg_status)
    );

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (cfg_we) begin
            seen_status  <= cfg_status;
            seen_region  <= cfg_region;
            seen_x0      <= cfg_x0;
            seen_y0      <= cfg_y0;
            seen_x1      <= cfg_x1;
            seen_y1      <= cfg_y1;
            seen_thr     <= cfg_thr;
            seen_version <= cfg_version;
            we_count     <= we_count + 1;
        end
    end

    integer k;
    task send_msg;
        input integer len;
        begin
            for (k = 0; k < len; k = k + 1) begin
                @(negedge clk);
                data  = msg[8*(len-1-k) +: 8];
                valid = 1'b1;
                @(negedge clk);
                valid = 1'b0;
            end
            repeat (10) @(negedge clk);
        end
    endtask

    task expect;
        input [2:0]  want_status;
        input [1:0]  want_region;
        input [11:0] want_x0;
        input [11:0] want_y0;
        input [11:0] want_x1;
        input [11:0] want_y1;
        input [7:0]  want_thr;
        input [7:0]  want_version;
        begin
            if (seen_status !== want_status) begin
                $display("FAIL: status %0d expected %0d", seen_status, want_status);
                $finish;
            end
            if (seen_version !== want_version) begin
                $display("FAIL: version %0d expected %0d",
                         seen_version, want_version);
                $finish;
            end
            if (want_status == 3'd0) begin
                if (seen_region !== want_region ||
                    seen_x0 !== want_x0 || seen_y0 !== want_y0 ||
                    seen_x1 !== want_x1 || seen_y1 !== want_y1 ||
                    seen_thr !== want_thr) begin
                    $display("FAIL: values %0d %0d %0d %0d %0d %0d",
                             seen_region, seen_x0, seen_y0, seen_x1,
                             seen_y1, seen_thr);
                    $finish;
                end
            end
        end
    endtask

    initial begin
        clk = 1'b0;
        rst = 1'b1;
        valid = 1'b0;
        data = 8'd0;
        msg = 0;
        we_count = 0;
        seen_status = 3'd7;
        seen_region = 2'd0;
        seen_x0 = 12'd0; seen_y0 = 12'd0; seen_x1 = 12'd0; seen_y1 = 12'd0;
        seen_thr = 8'd0;
        seen_version = 8'd0;

        repeat (4) @(negedge clk);
        rst = 1'b0;
        repeat (2) @(negedge clk);

        // 1. valid pickup region, version becomes 1
        msg = "RC,1,100,50,300,200,12\n";
        send_msg(23);
        expect(3'd0, 2'd1, 12'd100, 12'd50, 12'd300, 12'd200, 8'd12, 8'd1);

        // 2. valid forbidden region at full frame bounds, version 2
        msg = "RC,3,0,0,1280,720,16\n";
        send_msg(23);
        expect(3'd0, 2'd3, 12'd0, 12'd0, 12'd1280, 12'd720, 8'd16, 8'd2);

        // 3. region out of range, version unchanged
        msg = "RC,4,0,0,100,100,10\n";
        send_msg(21);
        expect(3'd1, 2'd0, 12'd0, 12'd0, 12'd0, 12'd0, 8'd0, 8'd2);

        // 4. x1 not greater than x0
        msg = "RC,2,500,100,500,200,10\n";
        send_msg(24);
        expect(3'd2, 2'd0, 12'd0, 12'd0, 12'd0, 12'd0, 8'd0, 8'd2);

        // 5. y1 beyond the frame
        msg = "RC,2,0,0,100,800,10\n";
        send_msg(21);
        expect(3'd3, 2'd0, 12'd0, 12'd0, 12'd0, 12'd0, 8'd0, 8'd2);

        // 6. threshold out of range
        msg = "RC,2,0,0,100,100,300\n";
        send_msg(22);
        expect(3'd4, 2'd0, 12'd0, 12'd0, 12'd0, 12'd0, 8'd0, 8'd2);

        // 7. too few fields
        msg = "RC,1,10,20,30\n";
        send_msg(14);
        expect(3'd5, 2'd0, 12'd0, 12'd0, 12'd0, 12'd0, 8'd0, 8'd2);

        // 8. a foreign line must be ignored entirely
        msg = "ST,1,2,3,4,5,6,7,8,9\n";
        send_msg(22);
        if (we_count != 7) begin
            $display("FAIL: foreign line produced a request (count %0d)", we_count);
            $finish;
        end

        // 9. a valid request after the bad ones still works, version 3
        msg = "RC,2,640,360,1279,719,20\n";
        send_msg(26);
        expect(3'd0, 2'd2, 12'd640, 12'd360, 12'd1279, 12'd719, 8'd20, 8'd3);

        $display("PASS: configuration parser");
        $finish;
    end

    initial begin
        #2000000;
        $display("FAIL: config_rx timeout");
        $finish;
    end

endmodule
