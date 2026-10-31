`timescale 1ns/1ps

// Non-stallable sampled-image ingress, in the sampling clock domain only.
// Reserve a bank at frame_start; publish only an exact, ordered, LAST-terminated
// frame. Two BRAM banks retain whole frames through arbitrary output stalls.
// No bank at START => drop the WHOLE frame, even if a bank frees partway through.
// frame_start is independent of valid; it may coincide with the first sample.
// frame_end is optional (0 if unavailable); the next START aborts a short frame.
// Downstream is stallable, and may feed ddr_evidence_axi's cap-domain FIFO.
// enable is sampled at START. Metadata must describe that source frame.
module camera_frame_guard #(
    parameter integer FRAME_PIXELS = 14400,
    parameter integer META_WIDTH = 96, // e.g. {source_frame_id32, monotonic_ms64}
    parameter integer INDEX_W = FRAME_PIXELS<2 ? 1 : $clog2(FRAME_PIXELS)
)(
    input wire clk, rst,
    input wire enable,
    input wire frame_start, frame_end,
    input wire in_valid,
    input wire [INDEX_W-1:0] in_index,
    input wire [15:0] in_data,
    input wire in_last,
    input wire [META_WIDTH-1:0] in_meta,
    output reg out_valid,
    output reg [15:0] out_data,
    output wire out_sof, out_last,
    output wire [META_WIDTH-1:0] out_meta,
    input wire out_ready,
    output wire [1:0] banks_occupied,
    output reg [31:0] frames_seen, frames_buffered, frames_sent,
    output reg [31:0] dropped_busy, dropped_invalid, dropped_disabled
);
    (* ram_style = "block" *) reg [15:0] bank0 [0:FRAME_PIXELS-1];
    (* ram_style = "block" *) reg [15:0] bank1 [0:FRAME_PIXELS-1];
    reg [META_WIDTH-1:0] meta0, meta1;
    reg [1:0] ready;
    reg write_bank, read_bank, filling, read_pending;
    reg [INDEX_W-1:0] capture_index, read_index;
    reg [15:0] read0, read1;
    reg next_filling, do_write, publish, reserve;
    reg [INDEX_W-1:0] next_index, write_index;
    reg [1:0] invalid_add;
    wire read_issue = !rst && ready[read_bank] && !read_pending && !out_valid;
    wire release_bank = out_valid && out_ready && out_last;
    assign out_sof = read_index == 0;
    assign out_last = read_index == FRAME_PIXELS-1;
    assign out_meta = read_bank ? meta1 : meta0;
    // Includes the bank currently being captured, not just published banks.
    assign banks_occupied = {1'b0,ready[0]} + {1'b0,ready[1]} + filling;

    function [31:0] sat_add;
        input [31:0] n;
        input [1:0] delta;
        reg [32:0] sum;
        begin
            sum = {1'b0,n}+delta;
            sat_add = sum[32] ? 32'hffffffff : sum[31:0];
        end
    endfunction

    always @* begin
        next_filling = filling; next_index = capture_index;
        do_write = 0; publish = 0; reserve = 0; invalid_add = 0;
        write_index = capture_index;
        if (frame_start) begin
            if (filling) invalid_add = 1; // previous frame never finished
            next_filling = enable && !ready[write_bank];
            next_index = 0;
            reserve = next_filling;
        end
        if (next_filling) begin
            write_index = next_index;
            if (in_valid) begin
                if (in_index != next_index || in_last != (next_index == FRAME_PIXELS-1)) begin
                    invalid_add = invalid_add+1'b1;
                    next_filling = 0;
                end else begin
                    do_write = 1;
                    if (in_last) begin publish = 1; next_filling = 0; end
                    else next_index = next_index+1'b1;
                end
            end
            if (frame_end && next_filling) begin
                invalid_add = invalid_add+1'b1;
                next_filling = 0;
            end
        end
    end

    // Reset invalidates ownership/flags only, never resets BRAM contents.
    always @(posedge clk) begin
        if (!rst && do_write) begin
            if (write_bank) bank1[write_index] <= in_data;
            else bank0[write_index] <= in_data;
        end
        if (read_issue) begin
            read0 <= bank0[read_index];
            read1 <= bank1[read_index];
        end
    end
    always @(posedge clk) begin
        if (rst) begin
            ready <= 0; write_bank <= 0; read_bank <= 0; filling <= 0;
            capture_index <= 0; read_index <= 0; read_pending <= 0;
            out_valid <= 0; out_data <= 0; meta0 <= 0; meta1 <= 0;
            frames_seen <= 0; frames_buffered <= 0; frames_sent <= 0;
            dropped_busy <= 0; dropped_invalid <= 0; dropped_disabled <= 0;
        end else begin
            filling <= next_filling; capture_index <= next_index;
            dropped_invalid <= sat_add(dropped_invalid,invalid_add);
            if (frame_start) begin
                frames_seen <= sat_add(frames_seen,1);
                if (!enable) dropped_disabled <= sat_add(dropped_disabled,1);
                else if (!reserve) dropped_busy <= sat_add(dropped_busy,1);
                if (reserve) begin
                    if (write_bank) meta1 <= in_meta; else meta0 <= in_meta;
                end
            end
            if (publish) begin
                ready[write_bank] <= 1;
                write_bank <= !write_bank;
                frames_buffered <= sat_add(frames_buffered,1);
            end
            if (read_issue) read_pending <= 1;
            if (read_pending) begin
                read_pending <= 0; out_valid <= 1;
                out_data <= read_bank ? read1 : read0;
            end
            if (out_valid && out_ready) begin
                out_valid <= 0;
                if (release_bank) begin
                    ready[read_bank] <= 0; read_bank <= !read_bank; read_index <= 0;
                    frames_sent <= sat_add(frames_sent,1);
                end else read_index <= read_index+1'b1;
            end
        end
    end
    // synthesis translate_off
    initial if (FRAME_PIXELS<1 || META_WIDTH<1)
        $fatal(1,"FAIL: invalid camera_frame_guard parameters");
    // synthesis translate_on
endmodule
