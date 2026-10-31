`timescale 1ns/1ps

// TB-only video path. Actual independent-clock STANDARD FIFO Generator IPs,
// latency bridge + new video client, one repeated numbered 2048-pixel frame.
// Synthetic camera/display pacing is deliberately bounded (56ns/72ns per
// pixel); this is NOT a 74.25MHz active-video deadline test.
module video_fifo_path_source (
    input wire clk,rst,run,reads_enable,continuous,
    output wire writes_done,reads_done,
    output wire [3:0] awid,arid,
    output wire [29:0] awaddr,araddr,
    output wire [7:0] awlen,arlen,
    output wire [2:0] awsize,arsize,awprot,arprot,
    output wire [1:0] awburst,arburst,
    output wire awlock,arlock,
    output wire [3:0] awcache,arcache,awqos,arqos,
    output wire awvalid,arvalid,
    input wire awready,arready,
    output wire [127:0] wdata,
    output wire [15:0] wstrb,
    output wire wlast,wvalid,
    input wire wready,
    input wire [3:0] bid,rid,
    input wire [1:0] bresp,rresp,
    input wire bvalid,rvalid,rlast,
    input wire [127:0] rdata,
    output wire bready,rready
);
    reg source_clk=0,display_clk=0;
    always #7 source_clk=~source_clk;
    always #9 display_clk=~display_clk;
    localparam PIXELS=2048,FRAMES=4,WORDS=PIXELS*FRAMES/8;
    reg fifo_reset=1,epoch_clear=1;
    reg [1:0] source_phase=0,display_phase=0;
    reg source_en=0,display_en=0;
    reg [15:0] source_data=0;
    integer produced=0,consumed=0,source_overflow=0,display_underflow=0;
    integer source_high=0,display_high=0,display_min=512,display_body_min=512;
    reg display_started=0,display_pending=0;
    wire source_full,source_busy,display_empty,display_busy;
    wire wrfifo_empty,wrfifo_rst_busy,wrfifo_rd_en,rdfifo_full,rdfifo_rst_busy,rdfifo_wr_en;
    wire [127:0] wrfifo_dout,rdfifo_din;
    wire [15:0] display_data;
    wire [5:0] wcount,rcount;
    wire [8:0] source_count,display_count;
    wr_ddr3_fifo wfifo (
        .rst(fifo_reset),.wr_clk(source_clk),.rd_clk(clk),.din(source_data),.wr_en(source_en),.rd_en(wrfifo_rd_en),
        .dout(wrfifo_dout),.full(source_full),.empty(wrfifo_empty),.rd_data_count(wcount),.wr_data_count(source_count),
        .wr_rst_busy(source_busy),.rd_rst_busy(wrfifo_rst_busy));
    rd_ddr3_fifo rfifo (
        .rst(fifo_reset),.wr_clk(clk),.rd_clk(display_clk),.din(rdfifo_din),.wr_en(rdfifo_wr_en),.rd_en(display_en),
        .dout(display_data),.full(rdfifo_full),.empty(display_empty),.wr_data_count(rcount),.rd_data_count(display_count),
        .wr_rst_busy(rdfifo_rst_busy),.rd_rst_busy(display_busy));
    wire in_valid,in_ready,out_valid,out_ready;
    wire [127:0] in_data,out_data;
    wire wr_clear,rd_clear;
    video_epoch_clear w_epoch(.ui_clk(clk),.ui_rst(rst),.source_clear(epoch_clear),
        .fifo_ui_rst_busy(wrfifo_rst_busy),.client_clear(wr_clear));
    video_epoch_clear r_epoch(.ui_clk(clk),.ui_rst(rst),.source_clear(epoch_clear),
        .fifo_ui_rst_busy(rdfifo_rst_busy),.client_clear(rd_clear));
    wire [31:0] words_fetched,words_to_client,words_to_display,cancelled_words;
    video_fifo_stream_bridge bridge (
        .clk(clk),.rst(rst),.wr_clear(wr_clear),.rd_clear(rd_clear),
        .wrfifo_empty(wrfifo_empty),.wrfifo_rst_busy(wrfifo_rst_busy),.wrfifo_dout(wrfifo_dout),.wrfifo_rd_en(wrfifo_rd_en),
        .in_valid(in_valid),.in_data(in_data),.in_ready(in_ready),.out_valid(out_valid),.out_data(out_data),.out_ready(out_ready),
        .rdfifo_full(rdfifo_full),.rdfifo_rst_busy(rdfifo_rst_busy),.rdfifo_wr_en(rdfifo_wr_en),.rdfifo_din(rdfifo_din),
        .words_fetched(words_fetched),.words_to_client(words_to_client),.words_to_display(words_to_display),.cancelled_words(cancelled_words));
    wire wr_busy,rd_busy,wr_halted,rd_halted;
    wire [3:0] fault;
    wire [31:0] write_bursts,read_bursts,write_beats,read_beats,published_beats;
    wire [31:0] dropped_write_beats,dropped_read_beats,write_errors,read_errors,write_clears,read_clears;
    assign writes_done=write_beats==WORDS && !wr_busy;
    assign reads_done=consumed==PIXELS*FRAMES;
    assign awlock=0;assign arlock=0;assign awcache=0;assign arcache=0;
    assign awprot=0;assign arprot=0;assign awqos=9;assign arqos=9;
    video_axi_client #(.WR_END_EXCLUSIVE(PIXELS*2),.RD_END_EXCLUSIVE(PIXELS*2)) client (
        .clk(clk),.rst(rst),.wr_enable(run && words_to_client<WORDS),
        .rd_enable(run && write_bursts>=PIXELS/8/32 && published_beats<WORDS),
        .wr_clear(wr_clear),.rd_clear(rd_clear),.in_valid(in_valid),.in_data(in_data),.in_ready(in_ready),
        .out_valid(out_valid),.out_data(out_data),.out_ready(out_ready),
        .wr_busy(wr_busy),.rd_busy(rd_busy),.wr_halted(wr_halted),.rd_halted(rd_halted),.fault(fault),
        .write_bursts(write_bursts),.read_bursts(read_bursts),.write_beats(write_beats),.read_beats(read_beats),
        .published_beats(published_beats),.dropped_write_beats(dropped_write_beats),.dropped_read_beats(dropped_read_beats),
        .write_errors(write_errors),.read_errors(read_errors),.write_clears(write_clears),.read_clears(read_clears),
        .m_axi_awid(awid),.m_axi_awaddr(awaddr),.m_axi_awlen(awlen),.m_axi_awsize(awsize),.m_axi_awburst(awburst),
        .m_axi_awvalid(awvalid),.m_axi_awready(awready),.m_axi_wdata(wdata),.m_axi_wstrb(wstrb),.m_axi_wlast(wlast),
        .m_axi_wvalid(wvalid),.m_axi_wready(wready),.m_axi_bid(bid),.m_axi_bresp(bresp),.m_axi_bvalid(bvalid),.m_axi_bready(bready),
        .m_axi_arid(arid),.m_axi_araddr(araddr),.m_axi_arlen(arlen),.m_axi_arsize(arsize),.m_axi_arburst(arburst),
        .m_axi_arvalid(arvalid),.m_axi_arready(arready),.m_axi_rid(rid),.m_axi_rdata(rdata),.m_axi_rresp(rresp),
        .m_axi_rlast(rlast),.m_axi_rvalid(rvalid),.m_axi_rready(rready));
    always @(negedge source_clk) begin
        source_phase=source_phase+1'b1;
        source_en=run && !epoch_clear && !source_busy && produced<PIXELS*FRAMES && source_phase==0;
        source_data=(produced%PIXELS)^16'h5a7c;
    end
    always @(posedge source_clk) if(source_en) begin
        if(source_full) source_overflow=source_overflow+1;
        produced=produced+1;
        if(source_count>source_high) source_high=source_count;
    end
    always @(negedge display_clk) begin
        if(!display_started && display_count>=256) display_started=1;
        display_phase=display_phase+1'b1;
        // Do NOT gate on EMPTY: an unavailable demanded pixel is a real miss.
        display_en=display_started && !display_busy && !epoch_clear && !reads_done && display_phase==0;
    end
    always @(posedge display_clk) begin
        if(fifo_reset) display_pending<=0;
        else begin
            display_pending<=display_en && !display_empty;
            if(display_en && display_empty) display_underflow=display_underflow+1;
            if(display_pending) begin
                if(display_data!==16'((consumed%PIXELS)^16'h5a7c))
                    $fatal(1,"FAIL: actual video FIFO/shared DDR pixel %d got=%h",consumed,display_data);
                consumed=consumed+1;
            end
            if(display_count>display_high) display_high=display_count;
            if(display_started && !reads_done && display_count<display_min) display_min=display_count;
            if(display_started && consumed<PIXELS*FRAMES-512 && display_count<display_body_min) display_body_min=display_count;
        end
    end
    initial begin
        wait(!rst);repeat(8) @(negedge clk);fifo_reset=0;
        wait(!source_busy && !wrfifo_rst_busy && !rdfifo_rst_busy && !display_busy);
        repeat(8) @(negedge clk);epoch_clear=0;
        wait(reads_done && writes_done);repeat(8) @(negedge clk);
        if(source_overflow || display_underflow || fault || wr_halted || rd_halted || dropped_write_beats || dropped_read_beats ||
            write_errors || read_errors || words_to_client!=WORDS || published_beats!=WORDS || words_to_display!=WORDS)
            $fatal(1,"FAIL: actual FIFO/shared DDR conservation overflow=%d underflow=%d",source_overflow,display_underflow);
        $display("actual FIFO video produced/consumed=%0d/%0d UIwords=%0d W/Rbursts=%0d/%0d source_high=%0d display_low/high=%0d/%0d body_low=%0d overflow/underflow=%0d/%0d",
            produced,consumed,WORDS,write_bursts,read_bursts,source_high,display_min,display_high,display_body_min,source_overflow,display_underflow);
    end
endmodule
