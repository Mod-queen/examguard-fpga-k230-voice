`timescale 1ns/1ps

// Independent shared-DDR video client candidate. Does NOT replace the vendor
// source in the accepted main XPR. UI-domain 128-bit streams; standard-mode
// FIFO IP needs a latency-aware stream bridge in the integrating snapshot.
//
// Each write burst is fully stored BEFORE AW. Once AWVALID is asserted, clear
// NEVER withdraws/changes that command or its W data: drain through B, then
// restart at WR_BEGIN. A clear during pre-AW filling discards that partial burst.
// Reads are fully checked before publication. Clear drains any issued AR/R
// through RLAST, suppressing old publication even after the clear level falls.
//
// wr_clear/rd_clear are UI-synchronous LEVELS, paired with the corresponding
// stream/FIFO epoch reset. Cancellation is allowed on LOCAL streams at clear,
// not on AXI. Hold clear during FIFO reset busy and synchronize release. A
// standalone client reset requires common arbiter/MIG reset, unlike frame clear.
// Errors halt that direction until frame clear; no infinite retry or fabricated
// OKAY data. Missing B/RLAST still requires system watchdog/common reset.
module video_axi_client #(
    parameter integer BURST=32,
    parameter [29:0] WR_BEGIN=0, WR_END_EXCLUSIVE=30'h001c2000,
    parameter [29:0] RD_BEGIN=0, RD_END_EXCLUSIVE=30'h001c2000,
    parameter [3:0] AXI_ID=0
)(
    input wire clk, rst,
    input wire wr_enable, rd_enable, wr_clear, rd_clear,
    input wire in_valid,
    input wire [127:0] in_data,
    output wire in_ready,
    output wire out_valid,
    output wire [127:0] out_data,
    input wire out_ready,
    output wire wr_busy, rd_busy,
    output reg wr_halted, rd_halted,
    output reg [3:0] fault,
    output reg [31:0] write_bursts, read_bursts, write_beats, read_beats,
    output reg [31:0] published_beats, dropped_write_beats, dropped_read_beats,
    output reg [31:0] write_errors, read_errors, write_clears, read_clears,
    output wire [3:0] m_axi_awid,
    output wire [29:0] m_axi_awaddr,
    output wire [7:0] m_axi_awlen,
    output wire [2:0] m_axi_awsize,
    output wire [1:0] m_axi_awburst,
    output wire m_axi_awvalid,
    input wire m_axi_awready,
    output wire [127:0] m_axi_wdata,
    output wire [15:0] m_axi_wstrb,
    output wire m_axi_wlast, m_axi_wvalid,
    input wire m_axi_wready,
    input wire [3:0] m_axi_bid,
    input wire [1:0] m_axi_bresp,
    input wire m_axi_bvalid,
    output wire m_axi_bready,
    output wire [3:0] m_axi_arid,
    output wire [29:0] m_axi_araddr,
    output wire [7:0] m_axi_arlen,
    output wire [2:0] m_axi_arsize,
    output wire [1:0] m_axi_arburst,
    output wire m_axi_arvalid,
    input wire m_axi_arready,
    input wire [3:0] m_axi_rid,
    input wire [127:0] m_axi_rdata,
    input wire [1:0] m_axi_rresp,
    input wire m_axi_rlast, m_axi_rvalid,
    output wire m_axi_rready
);
    localparam [2:0] W_IDLE=0,W_FILL=1,W_ADDR=2,W_DATA=3,W_RESP=4;
    localparam [1:0] R_IDLE=0,R_ADDR=1,R_DATA=2,R_PUBLISH=3;
    reg [2:0] ws;
    reg [1:0] rs;
    reg [29:0] wa,ra;
    reg [8:0] wn,rn,fill,wi,ri,send_index;
    reg [31:0] received;
    reg wcancel,rcancel,rbad,wr_clear_d,rd_clear_d;
    (* ram_style="distributed" *) reg [127:0] wmem[0:BURST-1];
    (* ram_style="distributed" *) reg [127:0] rmem[0:BURST-1];
    function [8:0] chunk;
        input [29:0] a,e;
        reg [29:0] n,page_words,frame_words;
        begin
            page_words=(4096-{18'd0,a[11:0]})>>4;
            frame_words=(e-a)>>4;
            n=BURST;
            if(n>page_words) n=page_words;
            if(n>frame_words) n=frame_words;
            chunk=n[8:0];
        end
    endfunction
    function [31:0] sat_add;
        input [31:0] a,b;
        reg [32:0] sum;
        begin sum={1'b0,a}+{1'b0,b};sat_add=sum[32] ? 32'hffffffff : sum[31:0];end
    endfunction
    wire berror=m_axi_bresp!=0 || m_axi_bid!=AXI_ID;
    wire rerror=m_axi_rresp!=0 || m_axi_rid!=AXI_ID || m_axi_rlast!=(ri==rn-1'b1);
    assign in_ready=!rst && !wr_clear && !wcancel && !wr_halted && ws==W_FILL;
    assign out_valid=!rst && !rd_clear && !rcancel && rs==R_PUBLISH;
    assign out_data=rmem[send_index];
    assign wr_busy=ws!=W_IDLE;
    assign rd_busy=rs!=R_IDLE;
    assign m_axi_awid=AXI_ID;assign m_axi_arid=AXI_ID;
    assign m_axi_awaddr=wa;assign m_axi_araddr=ra;
    assign m_axi_awlen=wn-1'b1;assign m_axi_arlen=rn-1'b1;
    assign m_axi_awsize=4;assign m_axi_arsize=4;
    assign m_axi_awburst=1;assign m_axi_arburst=1;
    assign m_axi_awvalid=!rst && ws==W_ADDR;
    assign m_axi_arvalid=!rst && rs==R_ADDR;
    assign m_axi_wvalid=!rst && ws==W_DATA;
    assign m_axi_wdata=wmem[wi];assign m_axi_wstrb=16'hffff;
    assign m_axi_wlast=wi==wn-1'b1;
    assign m_axi_bready=!rst && ws==W_RESP;
    assign m_axi_rready=!rst && rs==R_DATA;

    // No reset on storage. Only ownership/state reset makes data unreachable.
    always @(posedge clk) begin
        if(in_valid && in_ready) wmem[fill]<=in_data;
        if(m_axi_rvalid && m_axi_rready && ri<rn) rmem[ri]<=m_axi_rdata;
    end
    always @(posedge clk) begin
        if(rst) begin
            ws<=W_IDLE;rs<=R_IDLE;wa<=WR_BEGIN;ra<=RD_BEGIN;
            wn<=0;rn<=0;fill<=0;wi<=0;ri<=0;send_index<=0;received<=0;
            wcancel<=0;rcancel<=0;rbad<=0;wr_halted<=0;rd_halted<=0;fault<=0;
            wr_clear_d<=0;rd_clear_d<=0;
            write_bursts<=0;read_bursts<=0;write_beats<=0;read_beats<=0;published_beats<=0;
            dropped_write_beats<=0;dropped_read_beats<=0;write_errors<=0;read_errors<=0;
            write_clears<=0;read_clears<=0;
        end else begin
            wr_clear_d<=wr_clear;rd_clear_d<=rd_clear;
            if(wr_clear && !wr_clear_d) write_clears<=sat_add(write_clears,1);
            if(rd_clear && !rd_clear_d) read_clears<=sat_add(read_clears,1);
            if(wr_clear) begin
                wr_halted<=0;
                if(ws==W_ADDR || ws==W_DATA || ws==W_RESP) wcancel<=1;
            end
            if(rd_clear) begin
                rd_halted<=0;
                if(rs==R_ADDR || rs==R_DATA) rcancel<=1;
            end
            case(ws)
                W_IDLE: begin
                    wcancel<=0;fill<=0;
                    if(wr_clear) wa<=WR_BEGIN;
                    else if(wr_enable && !wr_halted) begin wn<=chunk(wa,WR_END_EXCLUSIVE);ws<=W_FILL;end
                end
                W_FILL: begin
                    if(wr_clear) begin
                        dropped_write_beats<=sat_add(dropped_write_beats,{23'd0,fill});
                        wa<=WR_BEGIN;fill<=0;ws<=W_IDLE;
                    end else if(in_valid && in_ready) begin
                        fill<=fill+1'b1;
                        if(fill==wn-1'b1) begin wi<=0;ws<=W_ADDR;end
                    end
                end
                W_ADDR: if(m_axi_awvalid && m_axi_awready) ws<=W_DATA;
                W_DATA: if(m_axi_wvalid && m_axi_wready) begin
                    write_beats<=sat_add(write_beats,1);
                    if(m_axi_wlast) ws<=W_RESP;else wi<=wi+1'b1;
                end
                W_RESP: if(m_axi_bvalid && m_axi_bready) begin
                    write_bursts<=sat_add(write_bursts,1);ws<=W_IDLE;
                    if(berror) begin
                        write_errors<=sat_add(write_errors,1);fault[0]<=1;
                        wr_halted<=!(wcancel || wr_clear);
                    end
                    if(wcancel || wr_clear) begin wa<=WR_BEGIN;wcancel<=0;end
                    else if(!berror) begin
                        if(wa+({21'd0,wn}<<4)>=WR_END_EXCLUSIVE) wa<=WR_BEGIN;
                        else wa<=wa+({21'd0,wn}<<4);
                    end
                end
                default: ws<=W_IDLE;
            endcase
            case(rs)
                R_IDLE: begin
                    rcancel<=0;ri<=0;send_index<=0;rbad<=0;received<=0;
                    if(rd_clear) ra<=RD_BEGIN;
                    else if(rd_enable && !rd_halted) begin rn<=chunk(ra,RD_END_EXCLUSIVE);rs<=R_ADDR;end
                end
                R_ADDR: if(m_axi_arvalid && m_axi_arready) rs<=R_DATA;
                R_DATA: if(m_axi_rvalid && m_axi_rready) begin
                    read_beats<=sat_add(read_beats,1);received<=sat_add(received,1);
                    if(ri<256) ri<=ri+1'b1; // saturate: malformed late LAST cannot wrap buffer index
                    if(rerror) rbad<=1;
                    if(m_axi_rresp!=0) fault[1]<=1;
                    if(m_axi_rid!=AXI_ID) fault[2]<=1;
                    if(m_axi_rlast!=(ri==rn-1'b1)) fault[3]<=1;
                    if(m_axi_rlast) begin
                        read_bursts<=sat_add(read_bursts,1);
                        if(rbad || rerror) begin
                            read_errors<=sat_add(read_errors,1);rd_halted<=!(rcancel || rd_clear);
                        end
                        if(rcancel || rd_clear || rbad || rerror) begin
                            dropped_read_beats<=sat_add(dropped_read_beats,sat_add(received,1));
                            rs<=R_IDLE;
                            if(rcancel || rd_clear) begin ra<=RD_BEGIN;rcancel<=0;end
                        end else begin send_index<=0;rs<=R_PUBLISH;end
                    end
                end
                R_PUBLISH: begin
                    if(rd_clear) begin
                        dropped_read_beats<=sat_add(dropped_read_beats,{23'd0,rn-send_index});
                        ra<=RD_BEGIN;rs<=R_IDLE;rcancel<=0;
                    end else if(out_valid && out_ready) begin
                        published_beats<=sat_add(published_beats,1);
                        if(send_index==rn-1'b1) begin
                            rs<=R_IDLE;
                            if(ra+({21'd0,rn}<<4)>=RD_END_EXCLUSIVE) ra<=RD_BEGIN;
                            else ra<=ra+({21'd0,rn}<<4);
                        end else send_index<=send_index+1'b1;
                    end
                end
                default: rs<=R_IDLE;
            endcase
        end
    end
    // synthesis translate_off
    initial if(BURST<1 || BURST>32 || WR_END_EXCLUSIVE<=WR_BEGIN || RD_END_EXCLUSIVE<=RD_BEGIN ||
        WR_BEGIN[3:0] || WR_END_EXCLUSIVE[3:0] || RD_BEGIN[3:0] || RD_END_EXCLUSIVE[3:0])
        $fatal(1,"FAIL: video client invalid address/length parameters");
    // synthesis translate_on
endmodule
