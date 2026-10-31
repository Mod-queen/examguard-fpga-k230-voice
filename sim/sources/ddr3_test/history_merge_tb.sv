`timescale 1ns/1ps
module history_merge_case(output reg done=0);
    reg clk=0,rst=1;
    always #5 clk=~clk;
    // byte mux
    reg a_valid=0,a_last=0,b_valid=0,b_last=0,dst_ready=0;
    reg [7:0] a_data=0,b_data=0;
    wire a_ready,b_ready,dst_valid,dst_last;
    wire [7:0] dst_data;
    evidence_byte_mux mux(.clk(clk),.rst(rst),.a_valid(a_valid),.a_last(a_last),.a_data(a_data),.a_ready(a_ready),
        .b_valid(b_valid),.b_last(b_last),.b_data(b_data),.b_ready(b_ready),
        .dst_valid(dst_valid),.dst_last(dst_last),.dst_data(dst_data),.dst_ready(dst_ready));
    reg [7:0] got[0:7];
    integer n=0,i;
    always @(posedge clk) if(!rst && dst_valid && dst_ready) begin
        got[n]<=dst_data;n<=n+1;
    end
    always @(negedge clk) if(!rst) dst_ready<=($random & 1);
    task automatic drive_a(input integer base,input integer count);
        integer k;
        begin
            @(negedge clk);a_valid=1;a_last=0;a_data=base;
            for(k=0;k<count;k=k+1) begin
                @(negedge clk);a_data=base+k;a_last=k==count-1;
                @(posedge clk);while(!a_ready) @(posedge clk);
            end
            @(negedge clk);a_valid=0;a_last=0;
        end
    endtask
    task automatic drive_b(input integer base,input integer count);
        integer k;
        begin
            @(negedge clk);b_valid=1;b_last=0;b_data=base;
            for(k=0;k<count;k=k+1) begin
                @(negedge clk);b_data=base+k;b_last=k==count-1;
                @(posedge clk);while(!b_ready) @(posedge clk);
            end
            @(negedge clk);b_valid=0;b_last=0;
        end
    endtask
    task automatic send(input integer base,input integer count);
        begin
            repeat(3) @(negedge clk);
            fork
                drive_a(base,count);
                drive_b(base+16,count);
            join
        end
    endtask
    // result fork
    reg f_valid=0;
    wire f_ready,a_f_valid,b_f_valid;
    reg a_f_ready=0,b_f_ready=0;
    wire [1:0] f_win,a_win,b_win;
    wire [31:0] f_tok,a_tok,b_tok,f_frames,a_frames,b_frames,f_gap,a_gap,b_gap;
    wire [2:0] f_code,a_code,b_code;
    wire f_ok,f_trunc,f_cap,f_unk,f_bad,f_cov;
    wire a_ok,a_trunc,a_cap,a_unk,a_bad,a_cov,b_ok,b_trunc,b_cap,b_unk,b_bad,b_cov;
    wire [63:0] f_lo,f_hi,a_lo,a_hi,b_lo,b_hi;
    wire [95:0] f_fm,f_lm,a_fm,a_lm,b_fm,b_lm;
    wire [7:0] f_fr,f_lr,a_fr,a_lr,b_fr,b_lr;
    wire [255:0] f_ev,a_ev,b_ev;
    reg [255:0] ev=256'h123456789abcdef0;
    history_result_fork #(.WINDOWS(4)) resfork(.clk(clk),.rst(rst),.in_valid(f_valid),.in_ready(f_ready),
        .in_window(2'd1),.in_token(32'hcafe),.in_code(3'd0),.in_ok(1),.in_trunc(0),.in_cap(0),
        .in_gap_unknown(0),.in_gap_bad_range(0),.in_coverage(1),.in_frames(32'd3),.in_gap_count(32'd0),
        .in_lower(64'd100),.in_upper(64'd300),.in_first_meta({32'd1,64'd100}),.in_last_meta({32'd2,64'd300}),
        .in_first_reason(8'h81),.in_last_reason(8'h82),.in_event(ev),
        .a_valid(a_f_valid),.a_ready(a_f_ready),.a_window(a_win),.a_token(a_tok),.a_code(a_code),
        .a_ok(a_ok),.a_trunc(a_trunc),.a_cap(a_cap),.a_gap_unknown(a_unk),.a_gap_bad_range(a_bad),
        .a_coverage(a_cov),.a_frames(a_frames),.a_gap_count(a_gap),.a_lower(a_lo),.a_upper(a_hi),
        .a_first_meta(a_fm),.a_last_meta(a_lm),.a_first_reason(a_fr),.a_last_reason(a_lr),.a_event(a_ev),
        .b_valid(b_f_valid),.b_ready(b_f_ready),.b_window(b_win),.b_token(b_tok),.b_code(b_code),
        .b_ok(b_ok),.b_trunc(b_trunc),.b_cap(b_cap),.b_gap_unknown(b_unk),.b_gap_bad_range(b_bad),
        .b_coverage(b_cov),.b_frames(b_frames),.b_gap_count(b_gap),.b_lower(b_lo),.b_upper(b_hi),
        .b_first_meta(b_fm),.b_last_meta(b_lm),.b_first_reason(b_fr),.b_last_reason(b_lr),.b_event(b_ev));
    task automatic fork_check(input integer a_delay,input integer b_delay);
        begin
            @(negedge clk);f_valid=1;
            @(posedge clk);while(!f_ready) @(posedge clk);
            @(negedge clk);f_valid=0;
            repeat(a_delay) @(negedge clk);
            if(!a_f_valid) $fatal(1,"FAIL: fork A not valid");
            a_f_ready=1;@(negedge clk);a_f_ready=0;
            if(!b_f_valid) $fatal(1,"FAIL: fork B lost after A");
            repeat(b_delay) @(negedge clk);
            if(a_f_valid) $fatal(1,"FAIL: fork A repeated after ack");
            if(b_f_valid && (b_tok!=32'hcafe || b_frames!=3 || b_lo!=100 || b_hi!=300 || b_ev!=ev))
                $fatal(1,"FAIL: fork B fields");
            b_f_ready=1;@(negedge clk);b_f_ready=0;
            repeat(3) @(negedge clk);
            if(a_f_valid || b_f_valid || !f_ready) $fatal(1,"FAIL: fork not released");
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        send(8'h10,3);
        if(n!=6) $fatal(1,"FAIL: mux byte count %0d",n);
        for(i=0;i<3;i=i+1) if(got[i]!=8'h20+i) $fatal(1,"FAIL: mux B priority bytes");
        for(i=0;i<3;i=i+1) if(got[3+i]!=8'h10+i) $fatal(1,"FAIL: mux A bytes after B");
        fork_check(5,7);
        fork_check(9,3);
        $display("PASS: history_merge byte_mux priority/whole-packet + result_fork both-order hold");
        done=1;
    end
    initial begin #200000;$fatal(1,"FAIL: merge timeout n%0d",n);end
endmodule
module history_merge_tb;
    wire d;
    history_merge_case c(d);
    initial begin wait(d);$display("PASS: history_merge ALL");$finish;end
endmodule


