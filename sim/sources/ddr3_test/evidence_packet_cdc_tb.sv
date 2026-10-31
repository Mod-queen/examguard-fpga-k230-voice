`timescale 1ns/1ps
module packet_cdc_case #(parameter S=5,D=4,CASE_ID=0)(output reg done=0);
    reg arst=1,src_clk=0,dst_clk=0,control_clk=0,cap_clk=0;
    reg run_src=1,run_dst=1,run_control=1,run_cap=1;
    always #(S) if(run_src) src_clk=~src_clk;
    always #(D) if(run_dst) dst_clk=~dst_clk;
    always #10 if(run_control) control_clk=~control_clk;
    always #7 if(run_cap) cap_clk=~cap_clk;
    wire [3:0] resets;
    wire src_rst=resets[0],dst_rst=resets[1];
    evidence_reset_barrier barrier(.arst(arst),.clocks({cap_clk,control_clk,dst_clk,src_clk}),.resets(resets));
    reg src_valid=0,src_last=0,dst_ready=0,hold_dst=1;
    reg [7:0] src_data=0;
    wire src_ready,dst_valid,dst_last;
    wire [7:0] dst_data;
    evidence_packet_cdc #(.DEPTH(16)) dut(.*);
    reg [8:0] expected[0:100000];
    integer tail=0,head=0,p,n,length,seed=32'h12345+CASE_ID,stalls=0;
    reg checking=0,held=0;
    reg [8:0] held_word;
    always @(negedge dst_clk) dst_ready=!hold_dst && (($random(seed)&7)!=0);
    always @(posedge dst_clk) begin
        if(dst_rst) held<=0;
        else begin
            if(held && (!dst_valid || {dst_last,dst_data}!==held_word)) $fatal(1,"FAIL: CDC held byte changed");
            held<=dst_valid && !dst_ready;held_word<={dst_last,dst_data};
            if(checking && dst_valid && dst_ready) begin
                if(head>=tail || {dst_last,dst_data}!==expected[head]) $fatal(1,"FAIL: CDC byte/last/order case=%0d head=%0d",CASE_ID,head);
                head=head+1;
            end
        end
    end
    always @(posedge src_clk) if(!src_rst && src_valid && !src_ready) stalls=stalls+1;
    task send;
        input integer len,id;
        integer i;
        begin
            for(i=0;i<len;i=i+1) begin
                @(negedge src_clk);src_valid=1;src_last=i==len-1;src_data=(id*19+i)&255;
                expected[tail]={src_last,src_data};tail=tail+1;
                @(posedge src_clk);while(!src_ready) @(posedge src_clk);
            end
            @(negedge src_clk);src_valid=0;
        end
    endtask
    initial begin
        repeat(5) @(negedge src_clk);arst=0;wait(resets==0);
        // Fill old epoch: one held destination byte plus queued packet tail.
        send(12,99);wait(dst_valid);@(negedge src_clk);run_src=0;
        @(negedge control_clk);run_control=0;@(negedge cap_clk);run_cap=0;
        #1;arst=1;#2;
        if(resets!==15) $fatal(1,"FAIL: stopped-domain async reset assertion");
        #3;arst=0;
        repeat(20) @(negedge dst_clk);
        if(resets!==15 || dst_valid) $fatal(1,"FAIL: release before stopped domains run");
        run_src=1;run_control=1;repeat(12) @(negedge src_clk);
        if(resets!==15) $fatal(1,"FAIL: missing cap reset barrier");
        run_cap=1;wait(resets==0);
        tail=0;head=0;checking=1;hold_dst=0;
        repeat(15) @(negedge dst_clk);
        if(dst_valid || head) $fatal(1,"FAIL: old packet escaped common reset");
        // Force source full; stalls propagate without byte/tail loss.
        fork
            begin hold_dst=1;send(1108,1);end
            begin repeat(80) @(negedge src_clk);hold_dst=0;end
        join
        for(n=0;n<100;n=n+1) begin
            length=n%4==0 ? 1 : n%4==1 ? 84 : n%4==2 ? 1108 : 17;
            send(length,n+2);
        end
        wait(head==tail);repeat(10) @(negedge dst_clk);
        if(!stalls || dst_valid) $fatal(1,"FAIL: CDC full/drain coverage");
        // Cancel a stalled LAST, with destination clock stopped this time.
        checking=0;hold_dst=1;send(1,999);wait(dst_valid);
        @(negedge dst_clk);run_dst=0;#1;arst=1;#3;arst=0;
        repeat(15) @(negedge src_clk);
        if(resets!==15) $fatal(1,"FAIL: destination stopped release");
        run_dst=1;wait(resets==0);tail=0;head=0;checking=1;hold_dst=0;
        send(3,42);wait(head==3);
        $display("PASS: evidence_packet_cdc case=%0d async periods=%0d/%0d 101packets/reset-held-last/stopped4domains stalls=%0d",CASE_ID,S*2,D*2,stalls);
        done=1;
    end
    initial begin #10000000;$fatal(1,"FAIL: packet CDC timeout case=%0d",CASE_ID);end
endmodule
module evidence_packet_cdc_tb;
    wire a,b;
    packet_cdc_case #(.S(5),.D(4),.CASE_ID(0)) c0(a);
    packet_cdc_case #(.S(3),.D(11),.CASE_ID(1)) c1(b);
    initial begin wait(a && b);$display("PASS: evidence_packet_cdc all cases");$finish;end
endmodule
