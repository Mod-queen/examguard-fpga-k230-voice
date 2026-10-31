`timescale 1ns/1ps
module history_reference_directory_case #(parameter N=7,USE_TOKENS=0)(output reg done=0);
    // Extra observation outputs in the released directory interface.
    wire writer_pending_o;
    wire [2:0] active_mask,closed_mask;
    localparam SW=N<2?1:$clog2(N);
    reg clk=0,rst=1;
    always #5 clk=~clk;
    reg reserve_valid=0,grant_ready=0,finish_valid=0,finish_ok=1,request_valid=0;
    reg seal_valid=0,release_valid=0;
    wire reserve_ready,grant_valid,grant_ok,finish_ready,request_ready,seal_ready,release_ready,accepted;
    wire [SW-1:0] grant_slot;
    wire [31:0] grant_token;
    reg [SW-1:0] finish_slot=0,query_slot=0;
    reg [31:0] finish_token=0;
    reg [95:0] finish_meta=0;
    reg [255:0] request_event=0;
    reg [63:0] seal_time=0;
    reg [1:0] release_window=0,query_window=0;
    wire [1:0] accepted_window;
    wire query_active,query_closed,query_truncated,query_capture_error,slot_valid,protocol_fault,token_exhausted;
    wire [N-1:0] query_slots,protected_slots;
    wire [255:0] query_event;
    wire [95:0] slot_meta;
    wire [31:0] reserve_rejected,write_failed;
    wire [31:0] accepted_token,query_token;
    wire window_token_exhausted,release_done,release_ok;
    reg [31:0] release_token=0,tokens[0:2];
    history_reference_directory #(.SLOTS(N),.WINDOWS(3),.PRE_MS(100),.POST_MS(100),.ENABLE_WINDOW_TOKENS(USE_TOKENS)) dut(.*);
    reg [95:0] expected_meta[0:N-1];
    reg [N-1:0] expected_valid=0,expected_refs[0:2];
    reg [255:0] expected_event[0:2];
    reg [63:0] lo[0:2],hi[0:2];
    reg [2:0] expected_active=0,expected_closed=0;
    reg sealed=0;
    reg [63:0] watermark=0,now_ms=100;
    integer seed=12345,uid=1;
    integer i,j,k,choice,selected;
    reg [N-1:0] union_refs;
    reg [SW-1:0] saved_slot;
    reg [31:0] saved_token;
    reg saved_ok;
    function [255:0] event_for(input [63:0] t,input integer id);
        event_for={32'hac750001,32'd5,32'd3,64'(id),t,8'd1,8'd0,16'h3750};
    endfunction
    task automatic quiet;
        begin repeat(N+3) @(negedge clk);end
    endtask
    task automatic check;
        integer a;
        begin
            quiet();union_refs=0;
            for(a=0;a<3;a=a+1) begin
                query_window=a;#1;
                if(query_active!==expected_active[a] || query_closed!==expected_closed[a] || query_slots!==expected_refs[a])
                    $fatal(1,"FAIL: N%0d window%0d got=%h exp=%h active=%b closed=%b",N,a,query_slots,expected_refs[a],query_active,query_closed);
                if(expected_active[a] && query_event!==expected_event[a]) $fatal(1,"FAIL: event identity/time changed");
                if(USE_TOKENS && expected_active[a] && (query_token!==tokens[a] || query_token==0)) $fatal(1,"FAIL: window token mismatch");
                if(expected_active[a]) union_refs=union_refs|expected_refs[a];
            end
            if(protected_slots!==union_refs) $fatal(1,"FAIL: union ref protection");
            for(a=0;a<N;a=a+1) begin
                query_slot=a;#1;
                if(slot_valid!==expected_valid[a]) $fatal(1,"FAIL: slot validity");
                if(slot_valid && slot_meta!==expected_meta[a]) $fatal(1,"FAIL: source descriptor");
            end
        end
    endtask
    task automatic reserve;
        integer a;
        begin
            @(negedge clk);reserve_valid=1;
            @(posedge clk);while(!reserve_ready) @(posedge clk);
            @(negedge clk);reserve_valid=0;
            wait(grant_valid);@(negedge clk);
            saved_ok=grant_ok;saved_slot=grant_slot;saved_token=grant_token;
            union_refs=0;
            for(a=0;a<3;a=a+1) if(expected_active[a]) union_refs=union_refs|expected_refs[a];
            if(grant_ok) begin
                if(union_refs[grant_slot]) $fatal(1,"FAIL: allocated referenced slot");
                expected_valid[grant_slot]=0;
            end else if(!token_exhausted && union_refs!={N{1'b1}}) $fatal(1,"FAIL: false allocation rejection");
            repeat(7) begin
                @(negedge clk);
                if(!grant_valid || grant_ok!==saved_ok || grant_slot!==saved_slot || grant_token!==saved_token)
                    $fatal(1,"FAIL: grant backpressure unstable");
            end
            grant_ready=1;@(negedge clk);grant_ready=0;
        end
    endtask
    task automatic finish(input [63:0] t,input ok);
        integer a;
        begin
            finish_slot=saved_slot;finish_token=saved_token;finish_meta={32'(t/50),t};finish_ok=ok;
            @(negedge clk);finish_valid=1;
            @(posedge clk);while(!finish_ready) @(posedge clk);
            @(negedge clk);finish_valid=0;
            if(ok) begin
                expected_valid[saved_slot]=1;expected_meta[saved_slot]=finish_meta;
                for(a=0;a<3;a=a+1)
                    if(expected_active[a] && !expected_closed[a] && t>=lo[a] && t<=hi[a]) expected_refs[a][saved_slot]=1;
            end
        end
    endtask
    task automatic request(input [63:0] t);
        integer a,w;
        begin
            request_event=event_for(t,uid);uid=uid+1;
            @(negedge clk);request_valid=1;
            @(posedge clk);while(!request_ready) @(posedge clk);
            @(negedge clk);request_valid=0;
            if(!accepted) $fatal(1,"FAIL: missing accepted pulse");
            w=accepted_window;
            tokens[w]=accepted_token;
            if(expected_active[w]) $fatal(1,"FAIL: overwrote active window");
            expected_active[w]=1;expected_event[w]=request_event;expected_refs[w]=0;
            lo[w]=t<100?0:t-100;hi[w]=64'hffffffffffffffff-t<100?64'hffffffffffffffff:t+100;
            expected_closed[w]=sealed && watermark>=hi[w];
            for(a=0;a<N;a=a+1)
                if(expected_valid[a] && expected_meta[a][63:0]>=lo[w] && expected_meta[a][63:0]<=hi[w]) expected_refs[w][a]=1;
            quiet();
        end
    endtask
    task automatic release_one(input integer w);
        begin
            @(negedge clk);release_valid=1;release_window=w;release_token=tokens[w];
            @(posedge clk);while(!release_ready) @(posedge clk);
            @(negedge clk);release_valid=0;
            if(!release_done || !release_ok) $fatal(1,"FAIL: valid release rejected");
            expected_active[w]=0;expected_closed[w]=0;expected_refs[w]=0;
        end
    endtask
    task automatic seal_to(input [63:0] t);
        integer a;
        begin
            @(negedge clk);seal_valid=1;seal_time=t;
            @(posedge clk);while(!seal_ready) @(posedge clk);
            @(negedge clk);seal_valid=0;sealed=1;watermark=t;
            for(a=0;a<3;a=a+1) if(expected_active[a] && t>=hi[a]) expected_closed[a]=1;
        end
    endtask
    task automatic reset_all;
        integer a;
        begin
            @(negedge clk);rst=1;repeat(3) @(negedge clk);rst=0;
            expected_valid=0;expected_active=0;expected_closed=0;sealed=0;watermark=0;now_ms=100;
            for(a=0;a<3;a=a+1) begin expected_refs[a]=0;tokens[a]=0;end
        end
    endtask
    initial begin
        for(i=0;i<3;i=i+1) expected_refs[i]=0;
        reset_all();
        // Late event selects ORIGINAL range, not newest service anchor.
        for(i=0;i<N;i=i+1) begin reserve();finish(now_ms,1);now_ms=now_ms+50;end
        request(100);request(150);check();
        if(N==1) begin reserve();if(saved_ok) $fatal(1,"FAIL: protected sole slot overwritten");end
        // Close only on explicit ordered seal; closed refs survive writer load.
        seal_to(now_ms);check();
        for(i=0;i<12;i=i+1) begin reserve();if(saved_ok) begin finish(now_ms+50,1);now_ms=now_ms+50;end end
        check();release_one(0);check();release_one(1);check();
        request(50);query_window=accepted_window;#1;
        if(!query_truncated) $fatal(1,"FAIL: unavailable prehistory not marked");
        release_one(accepted_window);
        // Independent reference-set oracle under randomized writes, overlapping
        // requests, seals, allocation rejection and explicit release.
        for(i=0;i<240;i=i+1) begin
            choice=($random(seed)&32'h7fffffff)%5;
            if(choice<2) begin
                reserve();if(saved_ok) begin now_ms=now_ms+50;finish(now_ms,1);end
            end else if(choice==2 && expected_active!=3'b111) request(now_ms>150?now_ms-100:now_ms);
            else if(choice==3) begin
                selected=($random(seed)&32'h7fffffff)%3;
                if(expected_active[selected]) release_one(selected);
            end else seal_to(now_ms);
            check();
        end
        if(protocol_fault) $fatal(1,"FAIL: legal command sequence faulted");
        // Complete reset cancels refs and reserved writes together.
        reset_all();reserve();request(150);
        // Wrong token must not release the outstanding slot.
        finish_slot=saved_slot;finish_token=saved_token+1;finish_meta={32'd3,64'd150};finish_ok=1;
        @(negedge clk);finish_valid=1;@(negedge clk);finish_valid=0;
        if(!protocol_fault) $fatal(1,"FAIL: stale completion accepted");
        finish(150,0);quiet();query_window=0;#1;
        if(!query_capture_error || write_failed!=1 || slot_valid) $fatal(1,"FAIL: failed B published descriptor");
        reset_all();reserve();finish(100,1);seal_to(100);
        reserve();
        // Successful DDR write carrying a duplicate/backward timestamp is NOT
        // eligible for publication; independent of the write response itself.
        finish_slot=saved_slot;finish_token=saved_token;finish_meta={32'd9,64'd100};finish_ok=1;
        @(negedge clk);finish_valid=1;@(negedge clk);finish_valid=0;quiet();query_slot=saved_slot;#1;
        if(!protocol_fault || slot_valid || write_failed!=1) $fatal(1,"FAIL: sealed/duplicate timestamp published");
        reset_all();reserve();
        // An in-flight writer prevents sealing; the rejected seal must not
        // prevent a later legitimate finish at that earlier source time.
        @(negedge clk);seal_time=200;seal_valid=1;@(negedge clk);seal_valid=0;
        if(!protocol_fault) $fatal(1,"FAIL: seal while writer pending accepted");
        finish(150,1);check();
        reset_all();
        // Saturating endpoint arithmetic: no wrap into small timestamps.
        request(64'hfffffffffffffff0);seal_to(64'hfffffffffffffffe);quiet();query_window=accepted_window;#1;
        if(query_closed || query_slots) $fatal(1,"FAIL: time upper bound wrapped");
        seal_to(64'hffffffffffffffff);quiet();#1;
        if(!query_closed) $fatal(1,"FAIL: saturated end never closed");
        reset_all();reserve();finish(100,1);
        dut.next_token=32'hffffffff;
        reserve();if(saved_token!=32'hffffffff) $fatal(1,"FAIL: last token");finish(150,1);
        reserve();if(saved_ok || !token_exhausted) $fatal(1,"FAIL: token wrapped");
        reset_all();check();
        $display("PASS: history_reference_directory N=%0d original-time/shared refs/write protection/seal/late/truncation/backpressure/errors/reset/token",N);
        done=1;
    end
    initial begin #2000000;$fatal(1,"FAIL: directory timeout N=%0d",N);end
endmodule
module history_reference_directory_tb;
    wire a,b,c,d;
    history_reference_directory_case #(.N(1)) one(a);
    history_reference_directory_case #(.N(7)) seven(b);
    history_reference_directory_case #(.N(64)) sixtyfour(c);
    history_reference_directory_case #(.N(7),.USE_TOKENS(1)) tokenized(d);
    initial begin wait(a && b && c && d);$display("PASS: history_reference_directory ALL");$finish;end
endmodule
