`timescale 1ns/1ps
module video_edges_case #(parameter BURST=3)(output reg passed=0);
    reg clk=0,rst=1,wr_enable=0,rd_enable=0,wr_clear=0,rd_clear=0;
    always #5 clk=~clk;
    reg in_valid=0,out_ready=0;
    reg [127:0] in_data=0;
    wire in_ready,out_valid,wr_busy,rd_busy,wr_halted,rd_halted;
    wire [127:0] out_data;
    wire [3:0] fault;
    wire [31:0] write_bursts,read_bursts,write_beats,read_beats,published_beats;
    wire [31:0] dropped_write_beats,dropped_read_beats,write_errors,read_errors,write_clears,read_clears;
    wire [3:0] m_axi_awid,m_axi_arid;
    wire [29:0] m_axi_awaddr,m_axi_araddr;
    wire [7:0] m_axi_awlen,m_axi_arlen;
    wire [2:0] m_axi_awsize,m_axi_arsize;
    wire [1:0] m_axi_awburst,m_axi_arburst;
    wire m_axi_awvalid,m_axi_wvalid,m_axi_wlast,m_axi_bready,m_axi_arvalid,m_axi_rready;
    wire [127:0] m_axi_wdata;
    wire [15:0] m_axi_wstrb;
    reg m_axi_awready=0,m_axi_wready=0,m_axi_bvalid=0,m_axi_arready=0,m_axi_rvalid=0,m_axi_rlast=0;
    reg [3:0] m_axi_bid=0,m_axi_rid=0;
    reg [1:0] m_axi_bresp=0,m_axi_rresp=0;
    reg [127:0] m_axi_rdata=0;
    video_axi_client #(.BURST(BURST),.WR_END_EXCLUSIVE(BURST*16*3),.RD_END_EXCLUSIVE(BURST*16*3)) dut(.*);
    integer p,delivered=0,wseen=0;
    always @(posedge clk) if(!rst) begin
        if(out_valid && out_ready) delivered=delivered+1;
        if(m_axi_wvalid && m_axi_wready) begin
            if(m_axi_wdata!==128'(wseen%BURST+100) || m_axi_wlast!==((wseen%BURST)==BURST-1))
                $fatal(1,"FAIL: edge clear lost W burst=%d",BURST);
            wseen=wseen+1;
        end
    end
    task fill_write;
        begin
            @(negedge clk);wr_enable=1;
            for(p=0;p<BURST;p=p+1) begin
                @(negedge clk);in_valid=1;in_data=p+100;
                @(posedge clk);while(!in_ready) @(posedge clk);
                @(negedge clk);in_valid=0;
            end
            wr_enable=0;wait(m_axi_awvalid);
        end
    endtask
    task start_read;
        begin
            @(negedge clk);rd_enable=1;wait(m_axi_arvalid);
            @(negedge clk);rd_enable=0;
        end
    endtask
    task clear_rd;
        begin @(negedge clk);rd_clear=1;@(negedge clk);rd_clear=0;end
    endtask
    task read_beat;
        input integer last;
        begin
            @(negedge clk);m_axi_rvalid=1;m_axi_rlast=last;m_axi_rdata=128'habc;
            @(posedge clk);while(!m_axi_rready) @(posedge clk);
            @(negedge clk);m_axi_rvalid=0;m_axi_rlast=0;
        end
    endtask
    initial begin
        repeat(5) @(negedge clk);rst=0;
        fill_write();
        // Clear coincides exactly with AW acceptance, then the level falls
        // before any W is accepted. No new input is supplied thereafter.
        @(negedge clk);wr_clear=1;m_axi_awready=1;
        @(negedge clk);wr_clear=0;m_axi_awready=0;m_axi_wready=1;
        wait(m_axi_bready);@(negedge clk);m_axi_wready=0;m_axi_bvalid=1;
        @(negedge clk);m_axi_bvalid=0;wait(!wr_busy);
        if(m_axi_awaddr!=0 || wseen!=BURST) $fatal(1,"FAIL: AW-edge clear restart");
        fill_write();@(negedge clk);m_axi_awready=1;
        @(negedge clk);m_axi_awready=0;m_axi_wready=1;
        wait(m_axi_bready);@(negedge clk);m_axi_wready=0;m_axi_bvalid=1;wr_clear=1;
        @(negedge clk);m_axi_bvalid=0;wr_clear=0;
        if(m_axi_awaddr!=0 || wr_busy) $fatal(1,"FAIL: B-edge clear restart");
        // AR-edge clear: all subsequent beats drain and none publish.
        start_read();@(negedge clk);rd_clear=1;m_axi_arready=1;
        @(negedge clk);rd_clear=0;m_axi_arready=0;
        for(p=0;p<BURST;p=p+1) read_beat(p==BURST-1);
        wait(!rd_busy);if(out_valid || delivered || dropped_read_beats!=BURST) $fatal(1,"FAIL: AR-edge clear old pixels");
        // Clear exactly on RLAST must also suppress that completed burst.
        start_read();@(negedge clk);m_axi_arready=1;@(negedge clk);m_axi_arready=0;
        for(p=0;p<BURST-1;p=p+1) read_beat(0);
        @(negedge clk);rd_clear=1;m_axi_rvalid=1;m_axi_rlast=1;
        @(negedge clk);rd_clear=0;m_axi_rvalid=0;m_axi_rlast=0;
        wait(!rd_busy);if(out_valid || delivered || dropped_read_beats!=2*BURST) $fatal(1,"FAIL: RLAST-edge clear publication");
        // Missing LAST at advertised length: keep draining, do not publish or
        // index outside buffer. Finish one beat late and halt with sticky fault.
        start_read();@(negedge clk);m_axi_arready=1;@(negedge clk);m_axi_arready=0;
        for(p=0;p<BURST;p=p+1) read_beat(0);
        if(!rd_busy || out_valid) $fatal(1,"FAIL: missing RLAST released transaction");
        read_beat(1);wait(!rd_busy);
        if(!rd_halted || !fault[3] || read_errors!=1 || out_valid) $fatal(1,"FAIL: late RLAST handling");
        clear_rd();
        if(BURST>1) begin
            start_read();@(negedge clk);m_axi_arready=1;@(negedge clk);m_axi_arready=0;
            read_beat(1);wait(!rd_busy);
            if(!rd_halted || read_errors!=2 || out_valid) $fatal(1,"FAIL: early RLAST handling");
            clear_rd();
        end
        // Actual counter updates at the maximum must stay saturated.
        @(negedge clk);dut.write_beats=32'hffffffff;dut.read_beats=32'hffffffff;
        dut.write_bursts=32'hffffffff;dut.read_bursts=32'hffffffff;dut.published_beats=32'hffffffff;
        fill_write();@(negedge clk);m_axi_awready=1;@(negedge clk);m_axi_awready=0;m_axi_wready=1;
        wait(m_axi_bready);@(negedge clk);m_axi_wready=0;m_axi_bvalid=1;@(negedge clk);m_axi_bvalid=0;
        start_read();@(negedge clk);m_axi_arready=1;@(negedge clk);m_axi_arready=0;
        for(p=0;p<BURST;p=p+1) read_beat(p==BURST-1);
        out_ready=1;wait(!rd_busy);@(negedge clk);
        if(write_beats!=32'hffffffff || read_beats!=32'hffffffff || write_bursts!=32'hffffffff ||
            read_bursts!=32'hffffffff || published_beats!=32'hffffffff) $fatal(1,"FAIL: video stats saturation");
        $display("video edges BURST=%0d AW/B/AR/RLAST clear, late/early LAST, saturation PASS",BURST);passed=1;
    end
endmodule
module video_axi_client_edges_tb;
    wire a,b,c;
    video_edges_case #(.BURST(1)) one(a);
    video_edges_case #(.BURST(3)) three(b);
    video_edges_case #(.BURST(32)) full_burst(c);
    initial begin wait(a&&b&&c);$display("PASS: video_axi_client_edges all checks");$finish;end
    initial begin #1000000;$fatal(1,"FAIL: video edge timeout");end
endmodule
