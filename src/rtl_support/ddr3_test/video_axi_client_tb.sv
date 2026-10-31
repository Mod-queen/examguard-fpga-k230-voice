`timescale 1ns/1ps
module video_axi_client_tb;
    localparam BASE=4080, END_ADDR=5280;
    reg clk=0,rst=1,wr_enable=0,rd_enable=0,wr_clear=0,rd_clear=0;
    always #5 clk=~clk;
    reg in_valid=0,out_ready=0;
    reg [127:0] in_data=0;
    wire in_ready,out_valid,wr_busy,rd_busy,wr_halted,rd_halted;
    wire [127:0] out_data;
    wire [3:0] fault;
    wire [31:0] write_bursts,read_bursts,write_beats,read_beats,published_beats;
    wire [31:0] dropped_write_beats,dropped_read_beats,write_errors,read_errors,write_clears,read_clears;
    `include "axi_frame_tb_wires.vh"
    video_axi_client #(.WR_BEGIN(BASE),.WR_END_EXCLUSIVE(END_ADDR),.RD_BEGIN(BASE),.RD_END_EXCLUSIVE(END_ADDR)) dut(.*);
    reg allow_aw=1,allow_w=1,allow_ar=1,allow_r=1,hold_b=0,inject_b=0,inject_r=0,bad_bid=0,bad_rid=0;
    wire mem_awready,mem_wready,mem_arready,mem_rvalid,mem_rlast;
    wire [3:0] mem_bid,mem_rid;
    assign m_axi_awready=mem_awready && allow_aw;
    assign m_axi_wready=mem_wready && allow_w;
    assign m_axi_arready=mem_arready && allow_ar;
    assign m_axi_rvalid=mem_rvalid && allow_r;
    assign m_axi_rlast=mem_rlast;
    assign m_axi_bid=mem_bid ^ (bad_bid ? 4'hf : 0);
    assign m_axi_rid=mem_rid ^ (bad_rid ? 4'he : 0);
    axi_frame_slave_model memory (
        .m_axi_awvalid(m_axi_awvalid && allow_aw),.m_axi_awready(mem_awready),
        .m_axi_wvalid(m_axi_wvalid && allow_w),.m_axi_wready(mem_wready),
        .m_axi_arvalid(m_axi_arvalid && allow_ar),.m_axi_arready(mem_arready),
        .m_axi_rready(m_axi_rready && allow_r),.m_axi_rvalid(mem_rvalid),.m_axi_rlast(mem_rlast),
        .m_axi_bid(mem_bid),.m_axi_rid(mem_rid),.*);
    reg [127:0] expected_w[0:4095],expected_r[0:4095];
    integer wh=0,wt=0,rh=0,rt=0,p,n,target,first_count,snapshot_aw,snapshot_ar;
    integer checked_w=0,checked_out=0,cancelled=0;
    reg cancelled_read=0,check_outputs=1;
    reg aw_stall=0,ar_stall=0,w_stall=0,out_stall=0;
    reg [42:0] held_aw,held_ar;
    reg [144:0] held_w;
    reg [127:0] held_out;
    always @(posedge clk) begin
        if(rst) begin aw_stall<=0;ar_stall<=0;w_stall<=0;out_stall<=0;wh=0;wt=0;rh=0;rt=0;cancelled_read=0;end
        else begin
            if(aw_stall && (!m_axi_awvalid || {m_axi_awaddr,m_axi_awlen,m_axi_awsize,m_axi_awburst}!==held_aw))
                $fatal(1,"FAIL: clear changed stalled AW");
            if(ar_stall && (!m_axi_arvalid || {m_axi_araddr,m_axi_arlen,m_axi_arsize,m_axi_arburst}!==held_ar))
                $fatal(1,"FAIL: clear changed stalled AR");
            if(w_stall && (!m_axi_wvalid || {m_axi_wdata,m_axi_wstrb,m_axi_wlast}!==held_w))
                $fatal(1,"FAIL: clear changed committed W");
            if(out_stall && !rd_clear && (!out_valid || out_data!==held_out))
                $fatal(1,"FAIL: output changed without local epoch clear");
            aw_stall<=m_axi_awvalid && !m_axi_awready;
            ar_stall<=m_axi_arvalid && !m_axi_arready;
            w_stall<=m_axi_wvalid && !m_axi_wready;
            out_stall<=out_valid && !out_ready;
            held_aw<={m_axi_awaddr,m_axi_awlen,m_axi_awsize,m_axi_awburst};
            held_ar<={m_axi_araddr,m_axi_arlen,m_axi_arsize,m_axi_arburst};
            held_w<={m_axi_wdata,m_axi_wstrb,m_axi_wlast};held_out<=out_data;
            if(in_valid && in_ready) begin expected_w[wt]=in_data;wt=wt+1;end
            if(m_axi_awvalid && m_axi_awready && wt-wh<m_axi_awlen+1)
                $fatal(1,"FAIL: AW before complete data reservation");
            if(m_axi_wvalid && m_axi_wready) begin
                if(wh==wt || m_axi_wdata!==expected_w[wh] || m_axi_wstrb!=16'hffff)
                    $fatal(1,"FAIL: reserved W data lost on clear beat=%d",wh);
                wh=wh+1;checked_w=checked_w+1;
            end
            if(m_axi_arvalid && m_axi_arready) begin rh=0;rt=0;cancelled_read=0;end
            if(rd_clear) begin rh=0;rt=0;cancelled_read=1;end
            if(m_axi_rvalid && m_axi_rready && !cancelled_read) begin expected_r[rt]=m_axi_rdata;rt=rt+1;end
            if(out_valid && out_ready) begin
                if(cancelled_read || (check_outputs && (rh==rt || out_data!==expected_r[rh])))
                    $fatal(1,"FAIL: old/invalid read data published");
                rh=rh+1;checked_out=checked_out+1;
            end
            if(rd_clear && out_valid) $fatal(1,"FAIL: output during clear");
        end
    end
    function integer burst_at;
        input integer a;
        integer x,y;
        begin x=(4096-(a%4096))/16;y=(END_ADDR-a)/16;burst_at=x<32 ? x : 32;if(burst_at>y) burst_at=y;end
    endfunction
    task data_words;
        input integer count,tag;
        begin
            for(p=0;p<count;p=p+1) begin
                repeat(p%3) @(negedge clk);
                @(negedge clk);in_valid=1;in_data={32'(tag),32'(p),32'habcdef01,32'(tag^p)};
                @(posedge clk);while(!in_ready) @(posedge clk);
                @(negedge clk);in_valid=0;
            end
        end
    endtask
    task new_write;
        input integer a,tag;
        begin
            @(negedge clk);wr_enable=1;
            data_words(burst_at(a),tag);wr_enable=0;
            wait(m_axi_awvalid);#1;
            if(m_axi_awaddr!=a || m_axi_awlen!=burst_at(a)-1) $fatal(1,"FAIL: address/page/frame boundary a=%h",a);
        end
    endtask
    task finish_write;
        begin wait(!wr_busy);@(negedge clk);end
    endtask
    task clear_write;
        begin @(negedge clk);wr_clear=1;repeat(3) @(negedge clk);wr_clear=0;end
    endtask
    task clear_read;
        begin @(negedge clk);rd_clear=1;repeat(3) @(negedge clk);rd_clear=0;end
    endtask
    task new_read;
        input integer a;
        begin
            @(negedge clk);rd_enable=1;wait(m_axi_arvalid);@(negedge clk);rd_enable=0;
            if(m_axi_araddr!=a || m_axi_arlen!=burst_at(a)-1) $fatal(1,"FAIL: read boundary a=%h",a);
        end
    endtask
    task finish_read;
        begin wait(!rd_busy);@(negedge clk);end
    endtask
    initial begin
        repeat(6) @(negedge clk);rst=0;
        // Full address span incl 4KiB split, short frame tail, wrapping.
        for(n=0;n<2;n=n+1) begin
            new_write(BASE,10+n);finish_write();
            new_write(4096,20+n);finish_write();
            new_write(4608,30+n);finish_write();
            new_write(5120,40+n);finish_write();
        end
        // Partial fill clear never emits AW. Clear discards 7 stored beats.
        @(negedge clk);wr_enable=1;data_words(1,50);wr_enable=0;finish_write();
        snapshot_aw=memory.aw_count;
        @(negedge clk);wr_enable=1;data_words(7,60);wr_enable=0;
        @(negedge clk);wh=wt;cancelled=cancelled+7;
        clear_write();finish_write();
        if(memory.aw_count!=snapshot_aw || dropped_write_beats!=7) $fatal(1,"FAIL: partial fill cancellation");
        // Reproduce old hazard at a NONZERO address, but new address stays held.
        new_write(BASE,70);finish_write();
        allow_aw=0;new_write(4096,71);clear_write();
        repeat(20) @(negedge clk);
        if(m_axi_awaddr!=4096 || !m_axi_awvalid) $fatal(1,"FAIL: cleared stalled AW did not survive");
        allow_aw=1;finish_write();
        new_write(BASE,72);finish_write();
        // Clear with stalled first W: upstream input disappears, W burst still
        // completes from its private buffer, then returns to BEGIN.
        allow_w=0;new_write(4096,80);wait(m_axi_wvalid);
        clear_write();repeat(20) @(negedge clk);allow_w=1;finish_write();
        new_write(BASE,81);finish_write();
        // Clear on LAST handshake, and later during withheld B.
        new_write(4096,90);wait(dut.ws==3 && dut.wi==31);
        @(negedge clk);wr_clear=1;wait(m_axi_wvalid && m_axi_wready && m_axi_wlast);
        @(negedge clk);wr_clear=0;finish_write();
        new_write(BASE,91);finish_write();
        hold_b=1;new_write(4096,100);wait(dut.ws==4);clear_write();
        repeat(20) @(negedge clk);hold_b=0;finish_write();
        new_write(BASE,101);finish_write();
        // B error/wrong ID are counted and halt, rather than deadlocking RESP.
        inject_b=1;new_write(4096,110);finish_write();inject_b=0;
        if(!wr_halted || write_errors!=1) $fatal(1,"FAIL: B error halt");
        clear_write();bad_bid=1;new_write(BASE,111);finish_write();bad_bid=0;
        if(!wr_halted || write_errors!=2 || !fault[0]) $fatal(1,"FAIL: wrong BID halt");
        clear_write();
        // Reads: full burst publication is backpressured independently of AXI.
        out_ready=1;new_read(BASE);finish_read();new_read(4096);finish_read();
        new_read(4608);finish_read();new_read(5120);finish_read();
        // AR command survives clear before address acceptance; no old data
        // publishes after the clear level drops.
        new_read(BASE);finish_read();allow_ar=0;new_read(4096);clear_read();
        repeat(20) @(negedge clk);
        if(m_axi_araddr!=4096 || !m_axi_arvalid) $fatal(1,"FAIL: cleared AR changed/withdrawn");
        first_count=published_beats;allow_ar=1;finish_read();
        if(published_beats!=first_count) $fatal(1,"FAIL: cancelled AR published");
        new_read(BASE);finish_read();
        // Clear while R not yet present, drain later despite stopped output.
        allow_r=0;new_read(4096);wait(dut.rs==2);out_ready=0;clear_read();
        allow_r=1;finish_read();out_ready=1;
        new_read(BASE);finish_read();
        // Clear halfway through a 32-beat R transaction.
        fork
            new_read(4096);
            begin wait(dut.received==8);clear_read();end
        join
        finish_read();
        new_read(BASE);finish_read();
        // Clear during local publication cancels the remaining stream at its
        // explicit epoch boundary, including a previously stalled out_valid.
        out_ready=0;new_read(4096);wait(out_valid);clear_read();finish_read();out_ready=1;
        new_read(BASE);finish_read();
        // Entire errored read burst is withheld, not partially published.
        inject_r=1;first_count=published_beats;new_read(4096);finish_read();inject_r=0;
        if(!rd_halted || read_errors!=1 || published_beats!=first_count) $fatal(1,"FAIL: R error publication");
        clear_read();bad_rid=1;new_read(BASE);finish_read();bad_rid=0;
        if(!rd_halted || read_errors!=2 || !fault[2]) $fatal(1,"FAIL: RID error publication");
        clear_read();new_read(BASE);finish_read();
        if(wh!=wt || published_beats!=checked_out || write_beats!=checked_w || write_clears<5 || read_clears<5)
            $fatal(1,"FAIL: video client conservation");
        // Common reset cancels an outstanding address (distinct from clear).
        allow_aw=0;new_write(BASE,120);
        @(negedge clk);rst=1;repeat(5) @(negedge clk);rst=0;allow_aw=1;
        if(m_axi_awvalid || out_valid || fault || wr_halted || rd_halted) $fatal(1,"FAIL: reset stale state");
        new_write(BASE,121);finish_write();new_read(BASE);finish_read();
        $display("video clear-safe client checked_W=%0d checked_published=%0d partial_drop=%0d final_after_reset W/R=%0d/%0d",
            checked_w,checked_out,cancelled,write_beats,read_beats);
        $display("PASS: video_axi_client all checks");$finish;
    end
    initial begin #10000000;$fatal(1,"FAIL: video AXI client timeout ws=%d rs=%d",dut.ws,dut.rs);end
endmodule
