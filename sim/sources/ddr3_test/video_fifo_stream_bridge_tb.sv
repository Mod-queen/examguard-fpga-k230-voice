`timescale 1ns/1ps
// Uses the ACTUAL existing FIFO Generator IP simulation models, independent
// clocks, asymmetric widths and reset busy flags. No ready/valid FIFO stand-in.
module video_fifo_stream_bridge_tb;
    reg clk=0,source_clk=0,display_clk=0,rst=1,wr_clear=1,rd_clear=1;
    always #5 clk=~clk;
    always #7 source_clk=~source_clk;
    always #9 display_clk=~display_clk;
    wire wrfifo_empty,wrfifo_rst_busy,rdfifo_full,rdfifo_rst_busy,wrfifo_rd_en;
    wire [127:0] wrfifo_dout;
    wire in_valid;
    wire [127:0] in_data;
    reg in_ready=0,out_valid=0;
    reg [127:0] out_data=0;
    wire out_ready,rdfifo_wr_en;
    wire [127:0] rdfifo_din;
    wire [31:0] words_fetched,words_to_client,words_to_display,cancelled_words;
    video_fifo_stream_bridge dut(.*);
    reg wreset=1,rreset=1,source_en=0,display_en=0;
    reg [15:0] source_data=0;
    wire source_full,display_empty,source_busy,display_busy;
    wire [15:0] display_data;
    wire [5:0] wcount,rcount;
    wire [8:0] source_count,display_count;
    wr_ddr3_fifo wfifo (
        .rst(wreset),.wr_clk(source_clk),.rd_clk(clk),.din(source_data),.wr_en(source_en),.rd_en(wrfifo_rd_en),
        .dout(wrfifo_dout),.full(source_full),.empty(wrfifo_empty),.rd_data_count(wcount),.wr_data_count(source_count),
        .wr_rst_busy(source_busy),.rd_rst_busy(wrfifo_rst_busy));
    rd_ddr3_fifo rfifo (
        .rst(rreset),.wr_clk(clk),.rd_clk(display_clk),.din(rdfifo_din),.wr_en(rdfifo_wr_en),.rd_en(display_en),
        .dout(display_data),.full(rdfifo_full),.empty(display_empty),.wr_data_count(rcount),.rd_data_count(display_count),
        .wr_rst_busy(rdfifo_rst_busy),.rd_rst_busy(display_busy));
    integer epoch=1,p,n,got_words=0,got_pixels=0,expected_word=0,expected_pixel=0;
    integer source_overflow=0,display_underflow=0;
    reg random_ready=0,display_go=0,display_pending=0;
    reg [31:0] rng=32'h798abcd;
    reg [127:0] expected;
    always @(negedge clk) begin
        rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        if(random_ready) in_ready<=rng[1];
    end
    // Loop back the bridge's stream through a separate registered source; the
    // output FIFO is filled independently below to isolate both interfaces.
    always @(posedge clk) if(!rst && !wr_clear && in_valid && in_ready) begin
        // FIFO Generator asymmetric words put the earliest 16bit input at the
        // HIGH end of the 128bit word; verify, never assume DMA low-lane format.
        for(n=0;n<8;n=n+1) expected[(7-n)*16 +: 16]=epoch*4096+expected_word*8+n;
        if(in_data!==expected) $fatal(1,"FAIL: standard FIFO delayed read/order expected_word=%d got=%h expected=%h",expected_word,in_data,expected);
        expected_word=expected_word+1;got_words=got_words+1;
    end
    always @(posedge source_clk) if(source_en && (source_full || source_busy)) source_overflow=source_overflow+1;
    always @(negedge display_clk) begin
        display_en=display_go && !display_empty && !display_busy && !rd_clear;
    end
    always @(posedge display_clk) begin
        if(rreset) display_pending<=0;
        else begin
            if(display_en && display_empty) display_underflow=display_underflow+1;
            display_pending<=display_en && !display_empty && !display_busy;
            if(display_pending) begin
                if(display_data!==16'(epoch*4096+expected_pixel))
                    $fatal(1,"FAIL: output FIFO word/pixel order pixel=%d got=%h",expected_pixel,display_data);
                expected_pixel=expected_pixel+1;got_pixels=got_pixels+1;
            end
        end
    end
    task source_pixels;
        input integer count;
        begin
            for(p=0;p<count;p=p+1) begin
                @(negedge source_clk);source_en=1;source_data=epoch*4096+p;
                @(negedge source_clk);source_en=0;
            end
        end
    endtask
    task display_words;
        input integer count;
        integer k,j;
        begin
            for(k=0;k<count;k=k+1) begin
                @(negedge clk);out_valid=1;
                for(j=0;j<8;j=j+1) out_data[(7-j)*16 +: 16]=epoch*4096+k*8+j;
                @(posedge clk);while(!out_ready) @(posedge clk);
                @(negedge clk);out_valid=0;
            end
        end
    endtask
    task release_resets;
        begin
            repeat(8) @(negedge clk);wreset=0;rreset=0;
            wait(!source_busy && !wrfifo_rst_busy && !rdfifo_rst_busy && !display_busy);
            repeat(8) @(negedge clk);wr_clear=0;rd_clear=0;
        end
    endtask
    initial begin
        repeat(8) @(negedge clk);rst=0;release_resets();random_ready=1;display_go=1;
        fork source_pixels(384);display_words(48);join
        wait(expected_word==48 && expected_pixel==384);repeat(10) @(negedge clk);
        random_ready=0;@(negedge clk);in_ready=0;display_go=0;
        // Hold a prefetched word and cancel it with a new FIFO epoch. The old
        // source pixels must not be delivered after clear release.
        source_pixels(16);wait(in_valid);
        @(negedge clk);wr_clear=1;rd_clear=1;wreset=1;rreset=1;
        repeat(8) @(negedge clk);epoch=2;expected_word=0;expected_pixel=0;
        release_resets();random_ready=1;display_go=1;
        fork source_pixels(256);display_words(32);join
        wait(expected_word==32 && expected_pixel==256);repeat(10) @(negedge clk);
        if(source_overflow || display_underflow || words_to_client!=80 || words_to_display!=80 || cancelled_words==0)
            $fatal(1,"FAIL: FIFO bridge counters actual model fetched=%d delivered=%d cancelled=%d",words_fetched,words_to_client,cancelled_words);
        $display("actual standard FIFO bridge words=%0d pixels=%0d cancelled=%0d overflow/underflow=%0d/%0d",
            got_words,got_pixels,cancelled_words,source_overflow,display_underflow);
        $display("PASS: video_fifo_stream_bridge all checks");$finish;
    end
    initial begin #2000000;$fatal(1,"FAIL: actual video FIFO bridge timeout");end
endmodule
