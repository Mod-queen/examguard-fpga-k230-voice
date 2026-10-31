`timescale 1ns/1ps
module frame_dma_case #(parameter FP=269, BASE=4080)(output reg passed=0);
    reg clk=0, rst=1;
    always #5 clk=~clk;
    reg wr_start=0, rd_start=0, in_valid=0, in_last=0;
    reg [29:0] wr_base=BASE, rd_base=BASE;
    reg [15:0] in_data=0;
    wire in_ready, wr_busy, wr_done, wr_ok, rd_busy, rd_done, rd_ok;
    wire out_valid, out_sof, out_last;
    wire [15:0] out_data;
    reg out_ready=0, hold_b=0, inject_b=0, inject_r=0;
    wire [31:0] write_beats, read_beats;
    `include "axi_frame_tb_wires.vh"
    ddr3_axi_frame_dma #(.FRAME_PIXELS(FP)) dut (.*);
    axi_frame_slave_model memory (.*);
    integer p, got=0, salt=0;
    reg checking=0;
    reg [31:0] rng=32'h12345678;
    always @(negedge clk) begin
        rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        out_ready<=rng[2];
    end
    always @(posedge clk) if (!rst && out_valid && out_ready) begin
        if (!checking || out_data !== ((salt+got)&16'hffff) ||
            out_sof!=(got==0) || out_last!=(got==FP-1))
            $fatal(1,"FAIL: frame DMA pixels FP=%d got=%d data=%h",FP,got,out_data);
        got=got+1;
    end
    task launch_write;
        begin
            @(negedge clk); wr_start=1;
            @(negedge clk); wr_start=0;
        end
    endtask
    task pixels;
        input integer count;
        input integer last_flag;
        begin
            for(p=0;p<count;p=p+1) begin
                repeat((p*7)%3) @(negedge clk);
                @(negedge clk); in_valid=1; in_data=salt+p; in_last=last_flag && p==count-1;
                @(posedge clk); while(!in_ready) @(posedge clk);
                @(negedge clk); in_valid=0; in_last=0;
            end
        end
    endtask
    task wait_write;
        input integer okay;
        begin
            wait(wr_done); #1;
            if (wr_ok!=okay) $fatal(1,"FAIL: write result FP=%d expected=%d",FP,okay);
            @(negedge clk);
        end
    endtask
    task read_frame;
        input integer okay;
        begin
            got=0; checking=1;
            @(negedge clk); rd_start=1;
            @(negedge clk); rd_start=0;
            wait(rd_done); #1;
            if(rd_ok!=okay || got!=FP) $fatal(1,"FAIL: read completion FP=%d",FP);
            checking=0; @(negedge clk);
        end
    endtask
    initial begin
        repeat(6) @(negedge clk); rst=0;
        salt=1000;
        // Gapped input, delayed responses, page split, partial final WSTRB.
        launch_write(); pixels(FP,1); wait_write(1);
        for(p=FP*2;p<((FP+7)/8)*16;p=p+1)
            if(memory.mem[BASE+p]!==8'ha5) $fatal(1,"FAIL: tail strobe overwrote padding");
        read_frame(1);
        inject_r=1; read_frame(0); inject_r=0;
        inject_b=1; launch_write(); pixels(FP,1); wait_write(0); inject_b=0;
        if(FP>1) begin
            launch_write(); pixels(FP-1,1); wait_write(0);
        end
        launch_write(); pixels(FP,0); wait_write(0);
        // Final W acceptance cannot assert completion while B is withheld.
        hold_b=1;
        if(FP<=8) begin
            launch_write(); pixels(FP,1);
            repeat(50) begin @(posedge clk); if(wr_done) $fatal(1,"FAIL: early B commit"); end
            hold_b=0; wait_write(1);
        end else hold_b=0;
        wr_base=BASE+1; launch_write(); wait_write(0); wr_base=BASE;
        // Reset cancels partial packing; slave and DMA reset together.
        launch_write();
        @(negedge clk); in_valid=1; in_data=16'h1234;
        @(posedge clk); while(!in_ready) @(posedge clk);
        @(negedge clk); in_valid=0; rst=1;
        repeat(4) @(negedge clk); rst=0;
        salt=2000; launch_write(); pixels(FP,1); wait_write(1); read_frame(1);
        passed=1;
    end
endmodule
module ddr3_axi_frame_dma_tb;
    wire a,b,c;
    frame_dma_case #(.FP(269),.BASE(4080)) ca(a);
    frame_dma_case #(.FP(1),.BASE(0)) cb(b);
    frame_dma_case #(.FP(8),.BASE(4096)) cc(c);
    initial begin wait(a&&b&&c); $display("PASS: ddr3_axi_frame_dma all checks"); $finish; end
    initial begin #10000000; $fatal(1,"FAIL: frame DMA timeout"); end
endmodule
