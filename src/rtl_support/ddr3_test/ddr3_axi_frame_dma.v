`timescale 1ns/1ps

// Independent RGB565 frame DMA. Byte addresses, 128-bit AXI, one outstanding
// burst per direction. Write bursts are buffered before AW; short input frames
// cannot leave an AXI burst waiting for missing W beats. A frame succeeds only
// after ALL B responses are OKAY. Commands/base addresses are latched.
// Reset must also reset/quiesce the AXI slave (outstanding work is discarded).
module ddr3_axi_frame_dma #(
    parameter integer FRAME_PIXELS = 14400,
    parameter integer BURST = 32,
    parameter integer ADDR_WIDTH = 30,
    parameter integer ID_WIDTH = 4
)(
    input wire clk, rst,
    input wire wr_start,
    input wire [ADDR_WIDTH-1:0] wr_base,
    input wire in_valid,
    input wire [15:0] in_data,
    input wire in_last,
    output wire in_ready,
    output wire wr_busy,
    output reg wr_done, wr_ok,
    input wire rd_start,
    input wire [ADDR_WIDTH-1:0] rd_base,
    output wire out_valid,
    output wire [15:0] out_data,
    output wire out_sof, out_last,
    input wire out_ready,
    output wire rd_busy,
    output reg rd_done, rd_ok,
    output wire [ID_WIDTH-1:0] m_axi_awid,
    output wire [ADDR_WIDTH-1:0] m_axi_awaddr,
    output wire [7:0] m_axi_awlen,
    output wire [2:0] m_axi_awsize,
    output wire [1:0] m_axi_awburst,
    output wire m_axi_awvalid,
    input wire m_axi_awready,
    output wire [127:0] m_axi_wdata,
    output wire [15:0] m_axi_wstrb,
    output wire m_axi_wlast, m_axi_wvalid,
    input wire m_axi_wready,
    input wire [ID_WIDTH-1:0] m_axi_bid,
    input wire [1:0] m_axi_bresp,
    input wire m_axi_bvalid,
    output wire m_axi_bready,
    output wire [ID_WIDTH-1:0] m_axi_arid,
    output wire [ADDR_WIDTH-1:0] m_axi_araddr,
    output wire [7:0] m_axi_arlen,
    output wire [2:0] m_axi_arsize,
    output wire [1:0] m_axi_arburst,
    output wire m_axi_arvalid,
    input wire m_axi_arready,
    input wire [ID_WIDTH-1:0] m_axi_rid,
    input wire [127:0] m_axi_rdata,
    input wire [1:0] m_axi_rresp,
    input wire m_axi_rlast, m_axi_rvalid,
    output wire m_axi_rready,
    output reg [31:0] write_beats, read_beats
);
    localparam integer BEATS = (FRAME_PIXELS+7)/8;
    localparam [2:0] W_IDLE=0, W_FILL=1, W_AW=2, W_DATA=3, W_RESP=4;
    localparam [1:0] R_IDLE=0, R_AR=1, R_DATA=2;
    reg [2:0] ws;
    reg [1:0] rs;
    reg [ADDR_WIDTH-1:0] wa, ra;
    reg [31:0] wp, rp, wbeats_left, rbeats_left;
    reg [8:0] wtarget, wcount, windex, rtarget, rindex;
    reg [2:0] wlane, rlane;
    reg [127:0] pack, rhold;
    reg [15:0] mask;
    reg rhold_valid, wfinal, werror, rerror;
    reg [127:0] data_mem [0:BURST-1];
    reg [15:0] strb_mem [0:BURST-1];

    // synthesis translate_off
    initial begin
        if (FRAME_PIXELS < 1 || BURST < 1 || BURST > 32 || ADDR_WIDTH < 12)
            $fatal(1,"FAIL: invalid frame DMA parameters");
    end
    // synthesis translate_on

    // All commands are 16-byte aligned. Split every burst at 4 KiB, including
    // non-power-of-two frame sizes and a short final burst.
    function [8:0] chunk;
        input [ADDR_WIDTH-1:0] addr;
        input [31:0] remaining;
        reg [31:0] n, page_left;
        begin
            page_left = (4096 - {20'd0,addr[11:0]}) >> 4;
            n = (remaining < BURST) ? remaining : BURST;
            if (n > page_left) n = page_left;
            chunk = n[8:0];
        end
    endfunction
    assign wr_busy = ws != W_IDLE;
    assign rd_busy = rs != R_IDLE;
    assign in_ready = !rst && ws == W_FILL;
    assign m_axi_awid = 0;
    assign m_axi_awaddr = wa;
    assign m_axi_awlen = wcount - 1'b1;
    assign m_axi_awsize = 3'd4;
    assign m_axi_awburst = 2'd1;
    assign m_axi_awvalid = !rst && ws == W_AW;
    assign m_axi_wdata = data_mem[windex];
    assign m_axi_wstrb = strb_mem[windex];
    assign m_axi_wlast = windex == wcount-1'b1;
    assign m_axi_wvalid = !rst && ws == W_DATA;
    assign m_axi_bready = !rst && ws == W_RESP;
    assign m_axi_arid = 0;
    assign m_axi_araddr = ra;
    assign m_axi_arlen = rtarget - 1'b1;
    assign m_axi_arsize = 3'd4;
    assign m_axi_arburst = 2'd1;
    assign m_axi_arvalid = !rst && rs == R_AR;
    assign m_axi_rready = !rst && rs == R_DATA && !rhold_valid;
    assign out_valid = !rst && rhold_valid;
    assign out_data = rhold[rlane*16 +: 16];
    assign out_sof = rp == 0;
    assign out_last = rp == FRAME_PIXELS-1;

    always @(posedge clk) begin
        if (rst) begin
            ws <= W_IDLE; rs <= R_IDLE;
            wa <= 0; ra <= 0; wp <= 0; rp <= 0;
            wbeats_left <= 0; rbeats_left <= 0;
            wtarget <= 0; wcount <= 0; windex <= 0;
            rtarget <= 0; rindex <= 0; wlane <= 0; rlane <= 0;
            pack <= 0; mask <= 0; rhold <= 0; rhold_valid <= 0;
            werror <= 0; rerror <= 0; wfinal <= 0;
            wr_done <= 0; wr_ok <= 0; rd_done <= 0; rd_ok <= 0;
            write_beats <= 0; read_beats <= 0;
        end else begin
            wr_done <= 0; rd_done <= 0;
            case (ws)
                W_IDLE: if (wr_start) begin
                    wr_ok <= 0;
                    if (wr_base[3:0] != 0) begin
                        wr_done <= 1;
                    end else begin
                        wa <= wr_base; wp <= 0; wbeats_left <= BEATS;
                        wtarget <= chunk(wr_base, BEATS);
                        wcount <= 0; windex <= 0; wlane <= 0;
                        pack <= 0; mask <= 0; werror <= 0; wfinal <= 0;
                        ws <= W_FILL;
                    end
                end
                W_FILL: if (in_valid && in_ready) begin
                    pack[wlane*16 +: 16] <= in_data;
                    mask[wlane*2 +: 2] <= 2'b11;
                    wp <= wp + 1'b1;
                    if (in_last != (wp == FRAME_PIXELS-1)) werror <= 1;
                    if (wlane == 7 || in_last || wp == FRAME_PIXELS-1) begin
                        data_mem[wcount] <= pack | ({112'd0,in_data} << (wlane*16));
                        strb_mem[wcount] <= mask | (16'h0003 << (wlane*2));
                        wcount <= wcount + 1'b1;
                        wlane <= 0; pack <= 0; mask <= 0;
                        if (wcount+1'b1 == wtarget || in_last || wp == FRAME_PIXELS-1) begin
                            windex <= 0;
                            wfinal <= in_last || wp == FRAME_PIXELS-1;
                            ws <= W_AW;
                        end
                    end else wlane <= wlane + 1'b1;
                end
                W_AW: if (m_axi_awvalid && m_axi_awready) ws <= W_DATA;
                W_DATA: if (m_axi_wvalid && m_axi_wready) begin
                    if (write_beats != 32'hffffffff) write_beats <= write_beats + 1'b1;
                    if (m_axi_wlast) ws <= W_RESP;
                    else windex <= windex + 1'b1;
                end
                W_RESP: if (m_axi_bvalid && m_axi_bready) begin
                    if (m_axi_bresp != 0 || m_axi_bid != 0) werror <= 1;
                    if (wfinal) begin
                        wr_done <= 1;
                        wr_ok <= !werror && m_axi_bresp == 0 && m_axi_bid == 0;
                        ws <= W_IDLE;
                    end else begin
                        wa <= wa + (wcount << 4);
                        wbeats_left <= wbeats_left - wcount;
                        wtarget <= chunk(wa + (wcount << 4), wbeats_left - wcount);
                        wcount <= 0; ws <= W_FILL;
                    end
                end
                default: ws <= W_IDLE;
            endcase

            case (rs)
                R_IDLE: if (rd_start) begin
                    rd_ok <= 0;
                    if (rd_base[3:0] != 0) rd_done <= 1;
                    else begin
                        ra <= rd_base; rp <= 0; rbeats_left <= BEATS;
                        rtarget <= chunk(rd_base, BEATS); rindex <= 0;
                        rlane <= 0; rhold_valid <= 0; rerror <= 0; rs <= R_AR;
                    end
                end
                R_AR: if (m_axi_arvalid && m_axi_arready) rs <= R_DATA;
                R_DATA: begin
                    if (m_axi_rvalid && m_axi_rready) begin
                        rhold <= m_axi_rdata; rhold_valid <= 1; rlane <= 0;
                        if (read_beats != 32'hffffffff) read_beats <= read_beats + 1'b1;
                        if (m_axi_rresp != 0 || m_axi_rid != 0 ||
                            m_axi_rlast != (rindex == rtarget-1'b1)) rerror <= 1;
                    end
                    if (out_valid && out_ready) begin
                        rp <= rp + 1'b1;
                        if (rlane == 7 || out_last) begin
                            rhold_valid <= 0;
                            if (out_last) begin
                                rd_done <= 1; rd_ok <= !rerror; rs <= R_IDLE;
                            end else if (rindex == rtarget-1'b1) begin
                                ra <= ra + (rtarget << 4);
                                rbeats_left <= rbeats_left - rtarget;
                                rtarget <= chunk(ra + (rtarget << 4), rbeats_left - rtarget);
                                rindex <= 0; rs <= R_AR;
                            end else rindex <= rindex + 1'b1;
                        end else rlane <= rlane + 1'b1;
                    end
                end
                default: rs <= R_IDLE;
            endcase
        end
    end
endmodule
