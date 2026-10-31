`timescale 1ns/1ps

// Two-clock-domain TB: a uid crosses once per src event, in order.
module cdc_event_uid_tb;
    reg clk_src = 0, clk_dst = 0;
    reg rst_src = 1, rst_dst = 1;
    reg src_event = 0;
    reg [63:0] src_uid = 0;
    wire [63:0] dst_uid;
    wire dst_event;

    integer errors = 0;
    integer sent = 0;
    integer dst_count = 0;
    reg [63:0] dst_last = 0;

    cdc_event_uid #(.WIDTH(64)) dut (
        .clk_src(clk_src), .rst_src(rst_src), .src_event(src_event), .src_uid(src_uid),
        .clk_dst(clk_dst), .rst_dst(rst_dst), .dst_uid(dst_uid), .dst_event(dst_event));

    always #5  clk_src = ~clk_src;   // 100 MHz
    always #7  clk_dst = ~clk_dst;   // ~71 MHz (deliberately asynchronous)

    // Destination monitor: count pulses and record the uid that came with them.
    always @(posedge clk_dst) begin
        if (dst_event) begin
            dst_count <= dst_count + 1;
            dst_last  <= dst_uid;
        end
    end

    task check(input cond, input [255:0] name);
        begin
            if (!cond) begin errors = errors + 1; $display("FAIL: %0s", name); end
        end
    endtask

    task send(input [63:0] value);
        begin
            @(posedge clk_src);
            src_uid = value; src_event = 1; @(posedge clk_src); src_event = 0;
            repeat (40) @(posedge clk_dst);
            sent = sent + 1;
            check(dst_count == sent, "exactly one dst pulse per src event");
            check(dst_last == value, "dst uid matches the sent value");
        end
    endtask

    initial begin
        repeat (4) @(posedge clk_src);
        rst_src = 0; rst_dst = 0;
        repeat (4) @(posedge clk_dst);

        send(64'd1);
        send(64'h0000_0000_0000_0005);
        send(64'hDEAD_BEEF_1234_5678);
        send(64'hFFFF_FFFF_FFFF_FFFF);

        check(sent == 4, "four events crossed");
        if (errors == 0) $display("PASS: cdc_event_uid all checks");
        else $display("FAIL: cdc_event_uid %0d errors", errors);
        $finish;
    end
endmodule
