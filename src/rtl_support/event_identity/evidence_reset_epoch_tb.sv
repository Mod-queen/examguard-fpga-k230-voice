`timescale 1ns/1ps
module evidence_reset_epoch_tb;
    reg arst=1,control_clk=0,cap_clk=0,ui_clk=0;
    reg run_control=1,run_cap=1;
    always #10 if(run_control) control_clk=~control_clk;
    always #7 if(run_cap) cap_clk=~cap_clk;
    always #5 ui_clk=~ui_clk;
    wire control_rst,cap_rst,ui_rst;
    evidence_reset_epoch epoch(.*);
    reg src_valid=0,dst_ready=0;
    reg [255:0] src_data=0;
    wire src_ready,dst_valid;
    wire [255:0] dst_data;
    wire [31:0] src_accepted_count,dst_delivered_count;
    cdc_event_transaction bridge(.src_clk(control_clk),.src_rst(control_rst),.dst_clk(ui_clk),.dst_rst(ui_rst),.*);
    reg winc=0,rinc=0;
    reg [15:0] wdata=0;
    wire [15:0] rdata;
    wire wfull,rempty;
    async_fifo #(.DEPTH(16)) fifo(.wclk(cap_clk),.wrst_n(!cap_rst),.rclk(ui_clk),.rrst_n(!ui_rst),.*);
    integer delivered=0,read_words=0,n,phase=0;
    always @(posedge ui_clk) if(!ui_rst) begin
        if(dst_valid && dst_ready) begin
            if(phase!=2 || dst_data!==256'h13579abcdef) $fatal(1,"FAIL: old event escaped reset barrier");
            delivered=delivered+1;
        end
        if(rinc && !rempty) begin
            if(phase!=2 || rdata!==16'(16'hc000+read_words)) $fatal(1,"FAIL: old FIFO data escaped common reset");
            read_words=read_words+1;
        end
    end
    task source_event;
        input [255:0] data;
        begin
            @(negedge control_clk);src_valid=1;src_data=data;
            @(posedge control_clk);while(!src_ready) @(posedge control_clk);
            @(negedge control_clk);src_valid=0;
        end
    endtask
    task write_word;
        input [15:0] data;
        begin
            @(negedge cap_clk);wdata=data;winc=1;
            @(posedge cap_clk);while(wfull) @(posedge cap_clk);
            @(negedge cap_clk);winc=0;
        end
    endtask
    initial begin
        repeat(6) @(negedge control_clk);arst=0;
        wait(!control_rst && !cap_rst && !ui_rst);
        // Force old request toggle1, held output, and nonempty pixel FIFO.
        source_event(256'hbad);wait(dst_valid);write_word(16'hdead);wait(!rempty);
        @(negedge control_clk);run_control=0;
        @(negedge cap_clk);run_cap=0;
        #3;arst=1;#1;
        if(!control_rst || !cap_rst || !ui_rst) $fatal(1,"FAIL: asynchronous assertion with stopped clocks");
        #19;arst=0;dst_ready=1;rinc=1;
        repeat(25) @(negedge ui_clk);
        if(!ui_rst || !control_rst || !cap_rst || dst_valid || !rempty) $fatal(1,"FAIL: barrier released with stopped domains");
        run_cap=1;repeat(12) @(negedge cap_clk);
        if(!ui_rst || !cap_rst) $fatal(1,"FAIL: barrier ignored stopped control clock");
        run_control=1;wait(!control_rst && !cap_rst && !ui_rst);
        repeat(15) @(negedge ui_clk);
        if(dst_valid || !rempty || delivered || read_words) $fatal(1,"FAIL: stale epoch after delayed clocks resume");
        phase=2;source_event(256'h13579abcdef);
        for(n=0;n<80;n=n+1) write_word(16'hc000+n);
        wait(delivered==1 && read_words==80);
        // Short reset pulse during idle is stretched; repeated assertion during
        // release restarts every local chain and barrier.
        #2;arst=1;#3;arst=0;
        repeat(2) @(negedge ui_clk);arst=1;#3;arst=0;
        wait(!control_rst && !cap_rst && !ui_rst);
        repeat(10) @(negedge ui_clk);
        if(dst_valid || !rempty || src_accepted_count || dst_delivered_count) $fatal(1,"FAIL: repeated reset retained epoch counters");
        $display("PASS: evidence_reset_epoch stopped-control/capture clocks, stale-toggle/FIFO cancellation, restart80 and retrigger");$finish;
    end
    initial begin #1000000;$fatal(1,"FAIL: reset epoch timeout");end
endmodule
