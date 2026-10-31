`timescale 1ns/1ps
module evidence_wrapper_reset_tb;
    reg ddr3_clk200m=0,ddr3_rst_n=0,control_clk=0,wrfifo_clk=0,rdfifo_clk=0,eth_clk=0;
    always #2.5 ddr3_clk200m=~ddr3_clk200m;
    always #10 control_clk=~control_clk;
    always #7 wrfifo_clk=~wrfifo_clk;
    always #6.734 rdfifo_clk=~rdfifo_clk;
    always #4 eth_clk=~eth_clk;
    wire shared_ui_clk,shared_ui_rst,ddr3_init_done;
    reg cancel=1;
    wire [3:0] resets;
    wire fabric_rst=resets[2];
    evidence_reset_barrier barrier(.arst(cancel || shared_ui_rst || !ddr3_rst_n),.clocks({eth_clk,shared_ui_clk,rdfifo_clk,control_clk}),.resets(resets));
    wire [31:0] source_overflow,display_underflow;
    wire [9:0] source_high,display_low;
    wire [3:0] video_fault,protocol_fault;
    wire wrfifo_full,rdfifo_empty;
    wire [15:0] wrfifo_wr_cnt,rdfifo_rd_cnt,rdfifo_dout;
    reg [3:0] e_awid=1,e_arid=1;
    reg [29:0] e_awaddr=8192,e_araddr=8192;
    reg [7:0] e_awlen=0,e_arlen=0;
    reg [2:0] e_awsize=4,e_arsize=4;
    reg [1:0] e_awburst=1,e_arburst=1;
    reg e_awvalid=0,e_arvalid=0,e_wlast=1,e_wvalid=0,e_bready=0,e_rready=0;
    reg [127:0] e_wdata=128'h123456789abcdef0123456789abcdef0;
    reg [15:0] e_wstrb=16'hffff;
    wire e_awready,e_arready,e_wready,e_bvalid,e_rvalid,e_rlast;
    wire [3:0] e_bid,e_rid;
    wire [1:0] e_bresp,e_rresp;
    wire [127:0] e_rdata;
    ddr3_shared_video_ctrl #(.WR_BYTE_ADDR_END(511),.RD_BYTE_ADDR_END(511)) dut(
        .wrfifo_clr(1'b0),.wrfifo_wren(1'b0),.wrfifo_din(16'd0),.rdfifo_clr(1'b0),.rdfifo_rden(1'b0),
        .ddr3_dq(),.ddr3_dqs_n(),.ddr3_dqs_p(),.ddr3_addr(),.ddr3_ba(),.ddr3_ras_n(),.ddr3_cas_n(),.ddr3_we_n(),.ddr3_reset_n(),
        .ddr3_ck_p(),.ddr3_ck_n(),.ddr3_cke(),.ddr3_cs_n(),.ddr3_odt(),.ddr3_dm(),.*);
    always @(posedge shared_ui_clk) begin
        if(dut.u_mig_7series_0.aresetn!==!fabric_rst) $fatal(1,"FAIL: wrapper slave aresetn not common cancellation");
        if(!ddr3_rst_n && !fabric_rst) $fatal(1,"FAIL: system reset failed to cancel fabric");
    end
    task write;
        begin
            @(negedge shared_ui_clk);e_awvalid=1;
            @(posedge shared_ui_clk);while(!e_awready) @(posedge shared_ui_clk);
            @(negedge shared_ui_clk);e_awvalid=0;e_wvalid=1;
            @(posedge shared_ui_clk);while(!e_wready) @(posedge shared_ui_clk);
            @(negedge shared_ui_clk);e_wvalid=0;
        end
    endtask
    task reset_transport;
        begin
            #1;cancel=1;e_awvalid=0;e_wvalid=0;e_arvalid=0;e_bready=0;e_rready=0;
            repeat(8) @(negedge shared_ui_clk);
            if(shared_ui_rst || !ddr3_init_done) $fatal(1,"FAIL: fabric aresetn fed back into raw MIG readiness");
            cancel=0;wait(resets==0);repeat(10) @(negedge shared_ui_clk);
            if(e_bvalid || e_rvalid || dut.fabric.arbiter.write_busy || dut.fabric.buffered_evidence_read.buffer.out_valid)
                $fatal(1,"FAIL: wrapper old evidence response survived aresetn");
        end
    endtask
    initial begin
        repeat(4) @(negedge control_clk);ddr3_rst_n=1;
        wait(ddr3_init_done);repeat(5) @(negedge shared_ui_clk);
        if(shared_ui_rst || !fabric_rst) $fatal(1,"FAIL: raw readiness/barrier startup independence");
        cancel=0;wait(resets==0);
        dut.u_mig_7series_0.hold_b=1;write();wait(dut.u_mig_7series_0.memory.responding);reset_transport();
        dut.u_mig_7series_0.hold_b=0;write();wait(e_bvalid);
        @(negedge shared_ui_clk);e_bready=1;@(negedge shared_ui_clk);e_bready=0;
        e_arvalid=1;@(posedge shared_ui_clk);while(!e_arready) @(posedge shared_ui_clk);
        @(negedge shared_ui_clk);e_arvalid=0;wait(e_rvalid);reset_transport();
        write();wait(e_bvalid);@(negedge shared_ui_clk);e_bready=1;@(negedge shared_ui_clk);e_bready=0;e_arvalid=1;
        @(posedge shared_ui_clk);while(!e_arready) @(posedge shared_ui_clk);
        @(negedge shared_ui_clk);e_arvalid=0;wait(e_rvalid);
        if(e_rdata!==e_wdata || e_rid!=1 || e_rresp || !e_rlast) $fatal(1,"FAIL: wrapper post-reset evidence mismatch");
        @(negedge shared_ui_clk);e_rready=1;@(negedge shared_ui_clk);e_rready=0;
        $display("PASS: evidence_wrapper_reset ACTUAL wrapper/fabric aresetn cancels delayedB/heldR; raw calibration independent; new evidence correct (MIG stub not PHY)");$finish;
    end
    initial begin #1000000;$fatal(1,"FAIL: wrapper reset deadlock/timeout resets=%b raw=%b",resets,shared_ui_rst);end
endmodule
