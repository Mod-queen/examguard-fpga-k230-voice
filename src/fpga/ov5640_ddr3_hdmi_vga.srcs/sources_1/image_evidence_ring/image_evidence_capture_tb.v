`timescale 1ns/1ps

// End-to-end check of the image evidence path: downsampler + ring + serialiser
// (pixel domain) -> cdc_byte_channel -> header parser / frame driver (125 MHz).
// A behavioural sink reassembles the window and compares it with a golden model.
module image_evidence_capture_tb;

    localparam integer FRAME_WIDTH  = 4;
    localparam integer FRAME_HEIGHT = 2;
    localparam integer FRAME_PIXELS = FRAME_WIDTH * FRAME_HEIGHT;
    localparam integer PRE_FRAMES   = 2;
    localparam integer POST_FRAMES  = 2;
    localparam integer RING_DEPTH   = 8;
    localparam integer WINDOW_LENGTH= PRE_FRAMES + POST_FRAMES + 1;
    localparam integer SRC_PIXELS   = 32 * 16; // 4 wide x 2 tall at /8

    reg src_clk, dst_clk;
    reg src_rst, dst_rst;

    // Display stream
    reg [7:0]  pr, pg, pb;
    reg [11:0] xv, yv;
    reg        de, sof;
    reg [31:0] meta_frame_id, meta_timestamp;
    reg [7:0]  meta_cfg, meta_seq;
    reg        event_trig;

    wire        cap_valid;
    wire [7:0]  cap_data;
    wire        cap_ready;
    wire        cap_available, cap_busy, cap_overrun;
    wire [7:0]  cap_snapshot_seq;

    wire        ch_valid;
    wire [7:0]  ch_data;
    wire        ch_ack;

    wire        src_start_frame;
    wire [7:0]  src_event_seq, src_frame_index;
    wire [15:0] src_frame_count;
    wire [31:0] src_frame_id, src_timestamp;
    wire [7:0]  src_cfg;
    wire [15:0] src_width, src_height;
    wire [31:0] src_frame_length;
    wire        sink_start_ready;
    wire        src_byte_valid;
    wire [7:0]  src_byte;
    wire        sink_byte_ready;

    image_evidence_capture #(
        .FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT),
        .PRE_FRAMES(PRE_FRAMES), .POST_FRAMES(POST_FRAMES),
        .RING_DEPTH(RING_DEPTH)
    ) capture (
        .clk(src_clk), .rst(src_rst),
        .pixel_r(pr), .pixel_g(pg), .pixel_b(pb),
        .x(xv), .y(yv), .de(de), .sof(sof),
        .meta_frame_id(meta_frame_id),
        .meta_timestamp_ms(meta_timestamp),
        .meta_config_version(meta_cfg),
        .meta_event_seq(meta_seq),
        .event_trigger(event_trig),
        .out_valid(cap_valid), .out_data(cap_data), .out_ready(cap_ready),
        .window_available(cap_available), .window_busy(cap_busy),
        .window_overrun(cap_overrun), .snapshot_event_seq(cap_snapshot_seq)
    );

    cdc_byte_channel channel (
        .src_clk(src_clk), .src_rst(src_rst),
        .src_valid(cap_valid), .src_data(cap_data), .src_ready(cap_ready),
        .dst_clk(dst_clk), .dst_rst(dst_rst),
        .dst_valid(ch_valid), .dst_data(ch_data), .dst_ack(ch_ack)
    );

    image_evidence_udp_source #(
        .FRAME_WIDTH(FRAME_WIDTH), .FRAME_HEIGHT(FRAME_HEIGHT),
        .WINDOW_LENGTH(WINDOW_LENGTH)
    ) source (
        .clk125m(dst_clk), .reset_p(dst_rst),
        .byte_valid(ch_valid), .byte_data(ch_data), .byte_ack(ch_ack),
        .start_frame(src_start_frame),
        .event_seq(src_event_seq), .frame_index(src_frame_index),
        .frame_count(src_frame_count), .frame_id(src_frame_id),
        .timestamp_ms(src_timestamp), .config_version(src_cfg),
        .frame_width(src_width), .frame_height(src_height),
        .frame_length(src_frame_length),
        .start_ready(sink_start_ready),
        .frame_byte_valid(src_byte_valid), .frame_byte(src_byte),
        .frame_byte_ready(sink_byte_ready), .busy()
    );

    // ------------------------------------------------------------------
    // Behavioural sink: reassemble each frame the source emits.
    // ------------------------------------------------------------------
    reg [1:0]  sink_state;
    reg [15:0] sink_count;
    reg [3:0]  sink_frame_no;
    reg [7:0]  got_event_seq [0:WINDOW_LENGTH-1];
    reg [7:0]  got_frame_index [0:WINDOW_LENGTH-1];
    reg [15:0] got_frame_count [0:WINDOW_LENGTH-1];
    reg [31:0] got_frame_id [0:WINDOW_LENGTH-1];
    reg [31:0] got_timestamp [0:WINDOW_LENGTH-1];
    reg [7:0]  got_cfg [0:WINDOW_LENGTH-1];
    reg [7:0]  got_pixels [0:WINDOW_LENGTH*FRAME_PIXELS*2-1];

    assign sink_start_ready = (sink_state == 2'd0);
    assign sink_byte_ready  = (sink_state == 2'd1);

    always @(posedge dst_clk) begin
        if (dst_rst) begin
            sink_state    <= 2'd0;
            sink_count    <= 16'd0;
            sink_frame_no <= 4'd0;
        end else begin
            case (sink_state)
                2'd0: begin
                    if (src_start_frame && sink_start_ready) begin
                        got_event_seq [sink_frame_no] <= src_event_seq;
                        got_frame_index[sink_frame_no] <= src_frame_index;
                        got_frame_count[sink_frame_no] <= src_frame_count;
                        got_frame_id  [sink_frame_no] <= src_frame_id;
                        got_timestamp [sink_frame_no] <= src_timestamp;
                        got_cfg       [sink_frame_no] <= src_cfg;
                        sink_count <= 16'd0;
                        sink_state <= 2'd1;
                    end
                end
                2'd1: begin
                    if (src_byte_valid && sink_byte_ready) begin
                        got_pixels[sink_frame_no*FRAME_PIXELS*2 + sink_count] <= src_byte;
                        if (sink_count == FRAME_PIXELS*2 - 1) begin
                            sink_count    <= 16'd0;
                            sink_frame_no <= sink_frame_no + 4'd1;
                            sink_state    <= 2'd0;
                        end else begin
                            sink_count <= sink_count + 16'd1;
                        end
                    end
                end
                default: sink_state <= 2'd0;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Clocks
    // ------------------------------------------------------------------
    initial begin src_clk = 1'b0; forever #5 src_clk = ~src_clk; end
    initial begin dst_clk = 1'b0; forever #4 dst_clk = ~dst_clk; end

    // ------------------------------------------------------------------
    // Drive one synthetic frame (32x16 source -> 4x2 evidence).
    // ------------------------------------------------------------------
    integer x, y;
    task send_frame;
        input integer fid;
        input         trigger;
        begin
            @(negedge src_clk);
            sof = 1'b1; de = 1'b0;
            meta_frame_id  = fid;
            meta_timestamp = fid * 100;
            meta_cfg       = fid[7:0] + 8'd1;
            meta_seq       = trigger ? 8'd7 : 8'd0;
            @(negedge src_clk);
            sof = 1'b0;
            for (y = 0; y < 16; y = y + 1) begin
                for (x = 0; x < 32; x = x + 1) begin
                    @(negedge src_clk);
                    de = 1'b1;
                    xv = x[11:0];
                    yv = y[11:0];
                    pr = fid[7:0] * 8'd10 + x[7:0];
                    pg = fid[7:0] * 8'd10 + y[7:0];
                    pb = fid[7:0];
                    event_trig = trigger;
                end
            end
            @(negedge src_clk);
            de = 1'b0;
            event_trig = 1'b0;
        end
    endtask

    // Golden RGB565 downsample value for a frame/pixel index.
    function [15:0] golden_pixel;
        input integer fid;
        input integer idx;
        integer sx, sy, r, g, b;
        begin
            sx = idx % FRAME_WIDTH;
            sy = idx / FRAME_WIDTH;
            r = fid * 10 + 8*sx;
            g = fid * 10 + 8*sy;
            b = fid;
            golden_pixel = {r[7:3], g[7:2], b[7:3]};
        end
    endfunction

    integer f, p;
    reg     failed;
    reg [15:0] gp;
    initial begin
        failed = 1'b0;
        src_rst = 1'b1; dst_rst = 1'b1;
        pr = 8'd0; pg = 8'd0; pb = 8'd0; xv = 12'd0; yv = 12'd0;
        de = 1'b0; sof = 1'b0;
        meta_frame_id = 32'd0; meta_timestamp = 32'd0;
        meta_cfg = 8'd0; meta_seq = 8'd0; event_trig = 1'b0;

        repeat (4) @(negedge src_clk);
        src_rst = 1'b0;
        repeat (4) @(negedge dst_clk);
        dst_rst = 1'b0;

        // Frame 0,1 quiet; frame 2 triggers; frames 3,4 complete the window.
        send_frame(0, 1'b0);
        send_frame(1, 1'b0);
        send_frame(2, 1'b1);
        send_frame(3, 1'b0);
        send_frame(4, 1'b0);

        // Wait for the whole window to be serialised and reassembled.
        wait (sink_frame_no == WINDOW_LENGTH);
        repeat (20) @(negedge dst_clk);

        for (f = 0; f < WINDOW_LENGTH; f = f + 1) begin
            if (got_event_seq[f] !== 8'd7) begin
                $display("FAIL: frame %0d event_seq=%0d", f, got_event_seq[f]);
                failed = 1'b1;
            end
            if (got_frame_index[f] !== f[7:0] ||
                got_frame_count[f] !== WINDOW_LENGTH ||
                got_frame_id[f] !== f ||
                got_timestamp[f] !== f * 100 ||
                got_cfg[f] !== f[7:0] + 8'd1) begin
                $display("FAIL: frame %0d header idx=%0d cnt=%0d id=%0d ts=%0d cfg=%0d",
                         f, got_frame_index[f], got_frame_count[f],
                         got_frame_id[f], got_timestamp[f], got_cfg[f]);
                failed = 1'b1;
            end
            for (p = 0; p < FRAME_PIXELS; p = p + 1) begin
                gp = golden_pixel(f, p);
                if (got_pixels[f*FRAME_PIXELS*2 + 2*p]     !== gp[15:8] ||
                    got_pixels[f*FRAME_PIXELS*2 + 2*p + 1] !== gp[7:0]) begin
                    $display("FAIL: frame %0d pixel %0d got=%02x%02x exp=%04x",
                             f, p, got_pixels[f*FRAME_PIXELS*2 + 2*p],
                             got_pixels[f*FRAME_PIXELS*2 + 2*p + 1], gp);
                    failed = 1'b1;
                end
            end
        end

        if (!failed)
            $display("PASS: image evidence capture path");
        else
            $display("FAIL: image evidence capture path");
        $finish;
    end

    initial begin
        #5000000;
        $display("FAIL: image evidence capture timeout");
        $finish;
    end

endmodule
