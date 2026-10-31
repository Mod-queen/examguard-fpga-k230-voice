`timescale 1ns/1ps
module history_axi_epoch_guard_tb;
    reg clk=0,rst=1,cancel=1;
    always #5 clk=~clk;
    wire idle,protocol_fault;
    reg [3:0] s_awid=3,s_arid=5;
    reg [29:0] s_awaddr=4080,s_araddr=4080;
    reg [7:0] s_awlen=0,s_arlen=0;
    reg [2:0] s_awsize=4,s_arsize=4;
    reg [1:0] s_awburst=1,s_arburst=1;
    reg s_awvalid=0,s_arvalid=0,s_wvalid=0,s_wlast=0,s_bready=0,s_rready=0;
    reg [127:0] s_wdata=0;reg [15:0] s_wstrb=16'hffff;
    wire s_awready,s_arready,s_wready,s_bvalid,s_rvalid,s_rlast;
    wire [3:0] s_bid,s_rid;wire [1:0] s_bresp,s_rresp;wire [127:0] s_rdata;
    wire [3:0] m_awid,m_arid;wire [29:0] m_awaddr,m_araddr;
    wire [7:0] m_awlen,m_arlen;wire [2:0] m_awsize,m_arsize;
    wire [1:0] m_awburst,m_arburst;
    wire m_awvalid,m_arvalid,m_wvalid,m_wlast,m_bready,m_rready;
    wire [127:0] m_wdata;wire [15:0] m_wstrb;
    reg m_awready=0,m_arready=0,m_wready=0,m_bvalid=0,m_rvalid=0,m_rlast=0;
    reg [3:0] m_bid=3,m_rid=5;reg [1:0] m_bresp=0,m_rresp=0;reg [127:0] m_rdata=0;
    history_axi_epoch_guard dut(.*);
    integer downstream_aw=0,downstream_w=0,downstream_b=0,downstream_ar=0,downstream_r=0;
    integer wremaining=0,rremaining=0,total_checks=0,i,n,old_aw;
    reg aw_stall=0,ar_stall=0,w_stall=0;
    reg [48:0] aw_old,ar_old;reg [144:0] w_old;
    always @(posedge clk) begin
        if(!rst) begin
            if(cancel && (s_awready || s_arready || s_wready || s_bvalid || s_rvalid))
                $fatal(1,"FAIL: cancelled epoch handshake visible");
            if(aw_stall && (!m_awvalid || {m_awid,m_awaddr,m_awlen,m_awsize,m_awburst}!==aw_old))
                $fatal(1,"FAIL: AW withdrawn/changed on cancel");
            if(ar_stall && (!m_arvalid || {m_arid,m_araddr,m_arlen,m_arsize,m_arburst}!==ar_old))
                $fatal(1,"FAIL: AR withdrawn/changed on cancel");
            if(w_stall && (!m_wvalid || {m_wdata,m_wstrb,m_wlast}!==w_old))
                $fatal(1,"FAIL: buffered W changed under stall");
            if(m_awvalid && m_awready) begin
                if(wremaining) $fatal(1,"FAIL: multiple AW");
                downstream_aw=downstream_aw+1;wremaining=m_awlen+1;
            end
            if(m_wvalid && m_wready) begin
                if(wremaining<1 || m_wlast!=(wremaining==1) || m_wdata!==128'(1000+downstream_w%32))
                    $fatal(1,"FAIL: buffered W payload/LAST count=%0d data=%h",downstream_w,m_wdata);
                if(m_wstrb!==(m_wlast ? 16'h0003 : 16'hffff)) $fatal(1,"FAIL: WSTRB");
                wremaining=wremaining-1;downstream_w=downstream_w+1;
            end
            if(m_bvalid && m_bready) begin
                if(wremaining) $fatal(1,"FAIL: early B");
                downstream_b=downstream_b+1;
            end
            if(m_arvalid && m_arready) begin
                downstream_ar=downstream_ar+1;rremaining=m_arlen+1;
            end
            if(m_rvalid && m_rready) begin
                if(rremaining<1 || m_rlast!=(rremaining==1)) $fatal(1,"FAIL: R length");
                downstream_r=downstream_r+1;rremaining=rremaining-1;
            end
        end
        aw_stall<=!rst && m_awvalid && !m_awready;ar_stall<=!rst && m_arvalid && !m_arready;
        w_stall<=!rst && m_wvalid && !m_wready;
        aw_old<={m_awid,m_awaddr,m_awlen,m_awsize,m_awburst};
        ar_old<={m_arid,m_araddr,m_arlen,m_arsize,m_arburst};w_old<={m_wdata,m_wstrb,m_wlast};
    end
    task automatic address(input integer length);
        begin
            @(negedge clk);s_awlen=length-1;s_awaddr=length==1?4080:4096;s_awvalid=1;
            @(posedge clk);while(!s_awready) @(posedge clk);
            @(negedge clk);s_awvalid=0;
        end
    endtask
    task automatic write_words(input integer length,input integer prefix_only);
        integer j,base;
        begin
            base=downstream_w;
            for(j=0;j<length;j=j+1) begin
                @(negedge clk);s_wvalid=1;s_wlast=!prefix_only && j==length-1;
                s_wstrb=s_wlast?16'h0003:16'hffff;s_wdata=128'(1000+(base+j)%32);
                @(posedge clk);while(!s_wready) @(posedge clk);
            end
            @(negedge clk);s_wvalid=0;s_wlast=0;
        end
    endtask
    task automatic raise_cancel;
        begin @(negedge clk);cancel=1;repeat(3) @(negedge clk);end
    endtask
    task automatic finish_write(input integer length,input integer discard);
        begin
            wait(m_awvalid);repeat(4) @(negedge clk);m_awready=1;
            @(negedge clk);m_awready=0;
            for(n=0;n<length;n=n+1) begin
                repeat(2+n%3) @(negedge clk);m_wready=1;
                @(negedge clk);m_wready=0;
            end
            repeat(8) @(negedge clk);m_bvalid=1;m_bresp=2;
            if(discard) begin
                #1;if(s_bvalid || !m_bready) $fatal(1,"FAIL: stale B leaked/not drained");
            end else begin
                repeat(5) @(negedge clk);
                if(!s_bvalid || s_bresp!=2 || s_bid!=3 || idle) $fatal(1,"FAIL: B response");
                s_bready=1;
            end
            @(negedge clk);m_bvalid=0;s_bready=0;
            wait(idle);repeat(2) @(negedge clk);
        end
    endtask
    // Lifecycle controller waits for physical drain before reopening source.
    reg control_clk=0,transport_rst=1,local_cancelled=0;
    always #11 control_clk=~control_clk;
    wire client_transport_rst,source_epoch_rst;
    history_lifecycle_control lifecycle(.clk(control_clk),.transport_rst(transport_rst),.axi_idle(idle),
        .local_cancelled(local_cancelled),.client_transport_rst(client_transport_rst),.source_epoch_rst(source_epoch_rst));
    initial begin
        repeat(4) @(negedge clk);rst=0;cancel=0;transport_rst=0;
        wait(!client_transport_rst);
        // Partial local burst: not one AW may reach shared AXI.
        old_aw=downstream_aw;address(4);write_words(2,1);raise_cancel();
        if(!idle || downstream_aw!=old_aw || m_awvalid) $fatal(1,"FAIL: partial burst escaped");
        cancel=0;total_checks=total_checks+1;
        // Good lengths including full 32 and 4KiB edge/tail strobe.
        for(i=1;i<=32;i=i==1?7:32+i) begin
            address(i);write_words(i,0);finish_write(i,0);total_checks=total_checks+1;
        end
        address(32);write_words(32,0);finish_write(32,0);total_checks=total_checks+1;
        // Cancel while AW VALID stalled: promised address/data must finish.
        address(7);write_words(7,0);wait(m_awvalid);raise_cancel();
        transport_rst=1;repeat(4) @(negedge control_clk);transport_rst=0;
        repeat(10) @(negedge control_clk);
        if(!client_transport_rst) $fatal(1,"FAIL: lifecycle released before drain");
        finish_write(7,1);wait(!client_transport_rst);cancel=0;total_checks=total_checks+1;
        // Cancel while a downstream W beat is stalled.
        address(3);write_words(3,0);wait(m_awvalid);@(negedge clk);m_awready=1;
        @(negedge clk);m_awready=0;wait(m_wvalid);raise_cancel();
        for(n=0;n<3;n=n+1) begin m_wready=1;@(negedge clk);m_wready=0;repeat(2) @(negedge clk);end
        m_bvalid=1;@(negedge clk);m_bvalid=0;wait(idle);cancel=0;total_checks=total_checks+1;
        // Cancel held B response: old master never consumes it, guard must.
        address(1);write_words(1,0);wait(m_awvalid);@(negedge clk);m_awready=1;
        @(negedge clk);m_awready=0;wait(m_wvalid);m_wready=1;
        @(negedge clk);m_wready=0;m_bvalid=1;repeat(3) @(negedge clk);
        if(!s_bvalid) $fatal(1,"FAIL: missing held B");
        raise_cancel();m_bvalid=0;wait(idle);cancel=0;total_checks=total_checks+1;
        // Cancel stalled AR followed by held R, drain all 32 beats.
        @(negedge clk);s_arvalid=1;s_arlen=31;s_araddr=4096;
        @(posedge clk);while(!s_arready) @(posedge clk);
        @(negedge clk);s_arvalid=0;wait(m_arvalid);raise_cancel();
        m_arready=1;@(negedge clk);m_arready=0;
        for(n=0;n<32;n=n+1) begin
            repeat(2) @(negedge clk);m_rvalid=1;m_rlast=n==31;m_rdata=128'(n);
            #1;if(s_rvalid || !m_rready) $fatal(1,"FAIL: stale R leaked/not drained");
            @(negedge clk);m_rvalid=0;
        end
        wait(idle);cancel=0;total_checks=total_checks+1;
        // Fresh read must still preserve response/backpressure after drain.
        @(negedge clk);s_arvalid=1;s_arlen=0;s_araddr=4080;
        @(posedge clk);while(!s_arready) @(posedge clk);
        @(negedge clk);s_arvalid=0;wait(m_arvalid);@(negedge clk);m_arready=1;
        @(negedge clk);m_arready=0;m_rvalid=1;m_rlast=1;m_rdata=128'hf123;m_rresp=2;
        repeat(4) @(negedge clk);
        if(!s_rvalid || s_rdata!=128'hf123 || s_rresp!=2 || m_rready) $fatal(1,"FAIL: fresh R backpressure");
        raise_cancel();m_rvalid=0;wait(idle);cancel=0;total_checks=total_checks+1;
        local_cancelled=1;repeat(50) @(negedge control_clk);
        if(!source_epoch_rst || client_transport_rst) $fatal(1,"FAIL: local halt not latched independently");
        if(protocol_fault || downstream_aw!=downstream_b) $fatal(1,"FAIL: fault/stranded shared write");
        $display("PASS: history_axi_epoch_guard checks=%0d AW/B=%0d W=%0d AR=%0d R=%0d partial/AW/W/B/AR/R cancel and lifecycle drain",total_checks,downstream_aw,downstream_w,downstream_ar,downstream_r);
        $finish;
    end
    initial begin #200000;$fatal(1,"FAIL: history AXI epoch timeout state %0d/%0d",dut.ws,dut.rs);end
endmodule
