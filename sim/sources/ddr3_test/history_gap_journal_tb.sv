`timescale 1ns/1ps
module history_gap_journal_case #(parameter D=3)(output reg done=0);
    reg clk=0,rst=1,gap_valid=0,query_valid=0,result_ready=0;
    always #5 clk=~clk;
    wire gap_ready,query_ready,result_valid,result_bad_range,result_unknown,halted;
    reg [95:0] gap_meta=0;
    reg [7:0] gap_reason=0;
    reg [63:0] query_lower=0,query_upper=0;
    wire [31:0] result_count,recorded_count,evicted_count;
    wire [95:0] result_first_meta,result_last_meta;
    wire [7:0] result_first_reason,result_last_reason;
    history_gap_journal #(.DEPTH(D)) dut(.*);
    integer total=0,i,k,seed=39;
    reg [63:0] times[0:99];
    task automatic append(input [63:0] t);
        begin
            @(negedge clk);gap_valid=1;gap_meta={32'(total+1),t};gap_reason=total+1;
            @(posedge clk);while(!gap_ready) @(posedge clk);
            @(negedge clk);gap_valid=0;times[total]=t;total=total+1;
        end
    endtask
    task automatic query(input [63:0] lo,input [63:0] hi);
        integer j,n,first,last,base;
        reg unknown;
        reg [241:0] held;
        begin
            n=0;first=0;last=0;base=total>D ? total-D : 0;
            unknown=halted || (base>0 && lo<=times[base-1]);
            for(j=base;j<total;j=j+1) if(times[j]>=lo && times[j]<=hi) begin
                if(n==0) first=j;last=j;n=n+1;
            end
            @(negedge clk);query_valid=1;query_lower=lo;query_upper=hi;
            @(posedge clk);while(!query_ready) @(posedge clk);
            @(negedge clk);query_valid=0;wait(result_valid);#1;
            if(result_count!=n || result_unknown!==unknown || result_bad_range!==(lo>hi))
                $fatal(1,"FAIL: gap query D%0d count%0d/%0d unknown%b/%b",D,result_count,n,result_unknown,unknown);
            if(n && (result_first_meta!=={32'(first+1),times[first]} || result_last_meta!=={32'(last+1),times[last]} ||
                     result_first_reason!=first+1 || result_last_reason!=last+1)) $fatal(1,"FAIL: gap endpoints metadata/reason");
            held={result_count,result_bad_range,result_unknown,result_first_meta,result_last_meta,result_first_reason,result_last_reason};
            repeat(13) begin
                @(negedge clk);
                if(!result_valid || gap_ready || query_ready || held!=={result_count,result_bad_range,result_unknown,result_first_meta,result_last_meta,result_first_reason,result_last_reason})
                    $fatal(1,"FAIL: gap snapshot changed during backpressure");
            end
            result_ready=1;@(negedge clk);result_ready=0;
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        query(0,64'hffffffffffffffff);
        for(i=0;i<60;i=i+1) begin
            append(100+i*50);
            query(0,64'hffffffffffffffff);
            query(100+i*50,100+i*50);
            k=($random(seed)&32'h7fffffff)%70;
            query(k*50,k*50+125);
        end
        if(recorded_count!=60 || evicted_count!=60-D) $fatal(1,"FAIL: gap eviction accounting");
        query(500,100);
        append(64'hffffffffffffffff);query(64'hffffffffffffffff,64'hffffffffffffffff);
        // Repeated/backward gap is rejected and every query becomes unknown.
        @(negedge clk);gap_meta=96'd1;gap_valid=1;@(negedge clk);gap_valid=0;
        if(!halted || gap_ready || recorded_count!=61) $fatal(1,"FAIL: invalid gap order accepted");
        query(0,64'hffffffffffffffff);
        @(negedge clk);rst=1;repeat(3) @(negedge clk);rst=0;total=0;
        query(0,100);if(halted || evicted_count || recorded_count) $fatal(1,"FAIL: reset gap journal");
        $display("PASS: history_gap_journal depth%0d ordered points/wrap/eviction unknown/closed-range queries/hold/MAX/reset",D);
        done=1;
    end
    initial begin #1000000;if(!done) $fatal(1,"FAIL: gap journal timeout");end
endmodule
module history_gap_journal_tb;
    wire a,b,c;
    history_gap_journal_case #(.D(1)) one(a);
    history_gap_journal_case #(.D(3)) three(b);
    history_gap_journal_case #(.D(16)) sixteen(c);
    initial begin wait(a && b && c);$display("PASS: history_gap_journal ALL");$finish;end
endmodule
