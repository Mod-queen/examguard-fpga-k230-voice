`timescale 1ns/1ps
module history_stream_cdc_case #(parameter SH=7,DH=5,DEPTH=4)(output reg done=0);
    reg src_clk=0,dst_clk=0,control_clk=0,run_src=1,run_dst=1;
    always #(SH) if(run_src) src_clk=~src_clk;
    always #(DH) if(run_dst) dst_clk=~dst_clk;
    always #11 control_clk=~control_clk;
    reg arst=1,restart=0,inject_src=0,inject_dst=0;
    wire src_rst,dst_rst,control_rst,cancelled,src_halted,dst_halted;
    wire [31:0] cancellation_count;
    history_stream_epoch epoch(.src_halt(src_halted || inject_src),.dst_halt(dst_halted || inject_dst),.*);
    reg command_valid=0,pixel_valid=0,pixel_last=0;
    reg [1:0] command_kind=0;
    reg [95:0] command_meta=0;
    reg [7:0] command_reason=0;
    reg [15:0] pixel_data=0;
    wire command_ready,pixel_ready,dst_command_valid,dst_pixel_valid,dst_pixel_last;
    wire [1:0] dst_command_kind;
    wire [95:0] dst_command_meta;
    wire [7:0] dst_command_reason;
    wire [15:0] dst_pixel_data;
    reg dst_command_ready=0,dst_pixel_ready=0,drain=0;
    history_stream_cdc #(.DEPTH(DEPTH)) dut(.*);
    reg [106:0] expected[0:4095];
    integer w=0,r=0,seed=718,i,p,full_cycles=0,epoch_number=1;
    reg stalled=0;
    reg [106:0] saved;
    wire [106:0] current_word=dst_command_valid ? {1'b0,dst_command_kind,dst_command_meta,dst_command_reason} : {1'b1,89'd0,dst_pixel_last,dst_pixel_data};
    always @(negedge dst_clk) begin
        dst_command_ready=drain && (($random(seed)&3)!=0);
        dst_pixel_ready=drain && (($random(seed)&7)==0);
    end
    always @(posedge src_clk) if(!src_rst) begin
        if(dut.fifo.wfull) full_cycles=full_cycles+1;
        if(command_valid && command_ready && command_kind!=3) begin
            expected[w]={1'b0,command_kind,command_meta,command_reason};w=w+1;
        end
        if(pixel_valid && pixel_ready) begin expected[w]={1'b1,89'd0,pixel_last,pixel_data};w=w+1;end
    end
    always @(posedge dst_clk) begin
        if(dst_rst) stalled=0;
        else begin
            if(stalled && (!(dst_command_valid || dst_pixel_valid) || current_word!==saved)) $fatal(1,"FAIL: CDC holding changed");
            stalled=(dst_command_valid && !dst_command_ready) || (dst_pixel_valid && !dst_pixel_ready);
            saved=current_word;
            if((dst_command_valid && dst_command_ready) || (dst_pixel_valid && dst_pixel_ready)) begin
                if(r>=w || current_word!==expected[r]) $fatal(1,"FAIL: CDC order/payload epoch%0d word%0d",epoch_number,r);
                r=r+1;
            end
        end
    end
    task automatic command(input [1:0] kind,input integer id);
        begin
            @(negedge src_clk);command_valid=1;command_kind=kind;
            command_meta={32'(epoch_number),32'h12345678,32'(id)};command_reason=id;
            @(posedge src_clk);while(!command_ready) @(posedge src_clk);
            @(negedge src_clk);command_valid=0;
        end
    endtask
    task automatic pixels(input integer n);
        integer k;
        begin
            for(k=0;k<n;k=k+1) begin
                @(negedge src_clk);pixel_valid=1;pixel_last=k==n-1;pixel_data=16'(k^16'hbaad);
                @(posedge src_clk);while(!pixel_ready) @(posedge src_clk);
                @(negedge src_clk);pixel_valid=0;
            end
        end
    endtask
    task automatic restart_epoch;
        begin
            wait(src_rst && dst_rst);command_valid=0;pixel_valid=0;
            inject_src=0;inject_dst=0;
            repeat(6) @(negedge control_clk);
            w=0;r=0;stalled=0;epoch_number=epoch_number+1;
            restart=1;@(negedge control_clk);restart=0;
            wait(!src_rst && !dst_rst);repeat(3) @(negedge dst_clk);
            if(dst_command_valid || dst_pixel_valid) $fatal(1,"FAIL: old CDC data after restart");
        end
    endtask
    initial begin
        repeat(5) @(negedge control_clk);arst=0;wait(!src_rst && !dst_rst);
        fork
            begin
                for(i=0;i<80;i=i+1) begin
                    command(i%3==0?1:0,i);
                    if(i%3!=0) pixels((i%37)+1);
                    command(2,i);
                end
            end
            begin repeat(100) @(negedge dst_clk);drain=1;end
        join
        wait(r==w);repeat(10) @(negedge dst_clk);
        if(!full_cycles || cancelled || src_halted || dst_halted) $fatal(1,"FAIL: full/backpressure coverage");
        // Cancel with a held destination command and old queued pixels.
        drain=0;command(0,100);pixels(1);wait(dst_command_valid);
        inject_src=1;wait(cancelled);restart_epoch();drain=1;
        command(1,101);command(2,101);wait(r==w);
        // Destination stop cannot release either side, even if control asks
        // restart before the paused destination can clear its held word.
        drain=0;command(0,102);pixels(1);wait(dst_command_valid);
        @(negedge dst_clk);run_dst=0;inject_src=1;wait(cancelled);wait(src_rst && dst_rst);
        inject_src=0;repeat(6) @(negedge control_clk);w=0;r=0;epoch_number=epoch_number+1;
        restart=1;@(negedge control_clk);restart=0;repeat(20) @(negedge control_clk);
        if(!src_rst || !dst_rst) $fatal(1,"FAIL: stopped dst escaped barrier");
        run_dst=1;wait(!src_rst && !dst_rst);drain=1;command(1,103);command(2,103);wait(r==w);
        // Source stop while destination detects a fatal protocol error.
        @(negedge src_clk);run_src=0;inject_dst=1;wait(cancelled);wait(src_rst && dst_rst);
        inject_dst=0;repeat(6) @(negedge control_clk);w=0;r=0;epoch_number=epoch_number+1;
        restart=1;@(negedge control_clk);restart=0;repeat(20) @(negedge control_clk);
        if(!src_rst || !dst_rst) $fatal(1,"FAIL: stopped source escaped barrier");
        run_src=1;wait(!src_rst && !dst_rst);command(1,104);command(2,104);wait(r==w);
        // Unknown source command is halted locally then cancels the other side.
        command(3,105);wait(cancelled);restart_epoch();command(1,106);command(2,106);wait(r==w);
        if(cancellation_count!=4) $fatal(1,"FAIL: cancellation count/retrigger");
        // Corrupt FIFO head framing while destination is stalled; invalid tag
        // cannot be delivered and becomes a destination-domain cancellation.
        drain=0;command(1,108);wait(dst_command_valid);
        stalled=0;
        force dut.held={1'b1,106'd0};
        @(posedge dst_clk);@(negedge dst_clk);release dut.held;
        wait(cancelled);restart_epoch();drain=1;command(1,109);command(2,109);wait(r==w);
        if(cancellation_count!=5) $fatal(1,"FAIL: malformed FIFO head not cancelled");
        // Short external reset, shorter than either domain period.
        #1;arst=1;#2;arst=0;wait(src_rst && dst_rst);w=0;r=0;epoch_number=epoch_number+1;
        wait(!src_rst && !dst_rst);command(1,107);command(2,107);wait(r==w);
        if(cancellation_count) $fatal(1,"FAIL: external reset did not clear counter");
        $display("PASS: history_stream_cdc SH%0d DH%0d depth%0d mixed80 frames/drop/fence full/stall/cancel/stopped domains/restart",SH,DH,DEPTH);
        done=1;
    end
    initial begin #3000000;if(!done) $fatal(1,"FAIL: CDC timeout SH%0d w%0d r%0d",SH,w,r);end
endmodule
module history_stream_cdc_tb;
    wire a,b;
    history_stream_cdc_case #(.SH(7),.DH(5),.DEPTH(4)) slow(a);
    history_stream_cdc_case #(.SH(3),.DH(11),.DEPTH(16)) fast(b);
    initial begin wait(a && b);$display("PASS: history_stream_cdc ALL");$finish;end
endmodule
