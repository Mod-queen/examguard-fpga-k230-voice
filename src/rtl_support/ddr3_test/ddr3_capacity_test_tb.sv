`timescale 1ns/1ps
module ddr3_capacity_test_tb;
    reg clk=0,rst=1,start=0;always #5 clk=~clk;
    wire [3:0] awid,arid;wire [29:0] awaddr,araddr;
    wire [7:0] awlen,arlen;wire [2:0] awsize,arsize;wire [1:0] awburst,arburst;
    wire awvalid,wvalid,wlast,bready,arvalid,rready;wire [127:0] wdata;wire [15:0] wstrb;
    wire busy,done,timed_out;wire [31:0] errors,passes_done,beats_written,beats_read;
    wire [127:0] region_errors,write_cycles,read_cycles;
    reg [31:0] rng=32'hcade;reg stall_write=0,alias_memory=0,inject_response=0;
    reg wactive=0,ractive=0,bvalid=0;reg [29:0] wa=0,ra=0;reg [5:0] wi=0,ri=0;
    wire awready=!wactive && !bvalid && rng[0];wire wready=wactive && rng[1] && !stall_write;
    wire arready=!ractive && rng[2];wire rvalid=ractive;wire rlast=ri==31;
    reg [127:0] memory[0:255];
    function automatic integer slot(input [29:0] addr);
        slot=(alias_memory?0:addr[29:28]*64)+addr[9:4];
    endfunction
    wire [127:0] rdata=memory[slot(ra+ri*16)];
    ddr3_capacity_test #(.REGION_BYTES(1024),.PASSES(2),.STALL_CYCLES(80)) dut(
        .clk(clk),.rst(rst),.start(start),.m_axi_awid(awid),.m_axi_awaddr(awaddr),.m_axi_awlen(awlen),.m_axi_awsize(awsize),.m_axi_awburst(awburst),.m_axi_awvalid(awvalid),.m_axi_awready(awready),
        .m_axi_wdata(wdata),.m_axi_wstrb(wstrb),.m_axi_wlast(wlast),.m_axi_wvalid(wvalid),.m_axi_wready(wready),
        .m_axi_bid(4'd0),.m_axi_bresp(inject_response?2'd2:2'd0),.m_axi_bvalid(bvalid),.m_axi_bready(bready),
        .m_axi_arid(arid),.m_axi_araddr(araddr),.m_axi_arlen(arlen),.m_axi_arsize(arsize),.m_axi_arburst(arburst),.m_axi_arvalid(arvalid),.m_axi_arready(arready),
        .m_axi_rid(4'd0),.m_axi_rdata(rdata),.m_axi_rresp(2'd0),.m_axi_rlast(rlast),.m_axi_rvalid(rvalid),.m_axi_rready(rready),
        .busy(busy),.done(done),.timed_out(timed_out),.errors(errors),.passes_done(passes_done),.beats_written(beats_written),.beats_read(beats_read),.region_errors(region_errors),.write_cycles(write_cycles),.read_cycles(read_cycles));
    integer writes=0,reads=0,passes=0;reg [127:0] held;reg held_valid=0;
    wire report_ready,report_valid,report_last;wire [7:0] report_data;integer report_count=0,fd;
    wire [735:0] payload={48'h444301010060,7'd0,timed_out,8'd0,32'd1024,32'd2,passes_done,
        errors,beats_written,beats_read,region_errors,write_cycles,read_cycles,96'd0};
    ddr3_capacity_report report(.clk(clk),.rst(rst),.result_valid(done),.result_ready(report_ready),
        .payload(payload),.byte_valid(report_valid),.byte_last(report_last),.byte_data(report_data),.byte_ready(1'b1));
    always @(posedge clk) if(!rst && report_valid) begin
        $fwrite(fd,"%c",report_data);if(report_last) report_count=report_count+1;
    end
    always @(posedge clk) begin
        rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        if(rst) begin wactive<=0;ractive<=0;bvalid<=0;writes=0;reads=0;passes=0;held_valid<=0;end
        else begin
            if(held_valid && (!wvalid || wdata!==held)) $fatal(1,"FAIL: stalled W changed");
            held_valid<=wvalid && !wready;held<=wdata;
            if(awvalid && awready) begin
                if(awlen!=31 || awsize!=4 || awburst!=1 || awaddr[8:0]!=0 || awaddr[11:0]+512>4096) $fatal(1,"FAIL: AXI shape");
                wactive<=1;wa<=awaddr;wi<=0;
            end
            if(wvalid && wready) begin
                if(wlast!=(wi==31) || wstrb!=16'hffff) $fatal(1,"FAIL: W shape");
                memory[slot(wa+wi*16)]<=wdata;writes=writes+1;
                if(wlast) begin wactive<=0;bvalid<=1;end else wi<=wi+1'b1;
            end
            if(bvalid && bready) bvalid<=0;
            if(arvalid && arready) begin
                if(writes!=(passes+1)*256) $fatal(1,"FAIL: read before all four regions written");
                ractive<=1;ra<=araddr;ri<=0;
            end
            if(rvalid && rready) begin
                reads=reads+1;
                if(rlast) begin ractive<=0;if(reads%256==0) passes=passes+1;end
                else ri<=ri+1'b1;
            end
        end
    end
    task automatic run_test(input integer aliasing,input integer bus_error);
        begin
            @(negedge clk);rst=1;alias_memory=aliasing;inject_response=bus_error;
            repeat(5) @(negedge clk);rst=0;start=1;@(negedge clk);start=0;
            wait(done);#1;
            if(beats_written!=512 || beats_read!=512 || passes_done!=2 || timed_out) $fatal(1,"FAIL: capacity counters");
            if(aliasing && errors!=384) $fatal(1,"FAIL: high-address aliases undetected %0d",errors);
            if(!aliasing && errors!=(bus_error?16:0)) $fatal(1,"FAIL: response error count %0d",errors);
            wait(!report_ready);wait(report_ready);repeat(3) @(negedge clk);
        end
    endtask
    initial begin
        fd=$fopen("ddr_capacity_records.txt","w");
        run_test(0,0);run_test(1,0);run_test(0,1);
        @(negedge clk);rst=1;inject_response=0;repeat(4) @(negedge clk);rst=0;start=1;
        @(negedge clk);start=0;wait(wvalid);@(negedge clk);stall_write=1;
        repeat(90) @(negedge clk);
        if(!timed_out || !busy || !wvalid) $fatal(1,"FAIL: timeout abandoned live AXI");
        stall_write=0;wait(done);#1;if(!timed_out || errors!=0) $fatal(1,"FAIL: timeout recovery observation");
        wait(!report_ready);wait(report_ready);repeat(3) @(negedge clk);$fclose(fd);
        $display("PASS: ddr3_capacity_test all-four-write-before-read/two-salts/alias384/B-errors16/stall-owner/counters");$finish;
    end
    initial begin #1000000;$fatal(1,"FAIL: capacity timeout");end
endmodule
