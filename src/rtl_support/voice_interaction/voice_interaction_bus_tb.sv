`timescale 1ns/1ps
// Slave decodes only pin edges, never DUT transaction state.
module voice_interaction_bus_tb;
    reg clk=0,rst=1;always #10 clk=~clk;
    reg [31:0] round_id=1;
    reg poll_eligible=1;
    wire sample_eligible;
    reg [63:0] info_tag=64'h55;
    reg [2:0] req_valid=0;
    wire [2:0] req_ready;
    reg [23:0] req_type=24'hffffff,req_id=24'h474540;
    reg [95:0] req_cookie={32'd1,32'd1,32'd1};
    reg [95:0] req_round={32'd1,32'd1,32'd1};
    reg [191:0] req_tag={64'h55,64'h55,64'h55};
    wire done_valid,sample_valid,link_fresh,busy,scl_low,sda_low;
    reg done_ready=0;
    wire [1:0] done_owner,done_error;
    wire [31:0] done_cookie,done_round,sample_round;
    wire [63:0] done_tag,sample_tag;
    wire [7:0] sample_id;
    tri1 scl_i,sda_i;
    reg slave_low=0,stuck=0,enabled=1;
    assign scl_i=(scl_low || stuck)?1'b0:1'bz;
    assign sda_i=(sda_low || slave_low)?1'b0:1'bz;
    voice_interaction_bus #(.QUARTER_CYCLES(4),.TIMEOUT_CYCLES(120),
        .POLL_CYCLES(25),.STALE_CYCLES(3000)) dut(.*);
    integer mode=0,bitno=0,stage=0,pointer=0,rx_bytes=0,nack_byte=-1;
    integer reads=0,writes=0,starts=0,stops=0,samples=0,completions=0,scenarios=0;
    reg [7:0] rx=0,tx=0,word=0,clip_type=0,clip_id=0;
    reg ack_ok=0,ack_risen=0,reading=0,ack_seen=0,ack_value=0;
    reg [1:0] owners[0:15];
    reg [7:0] clips[0:15];
    always @(negedge sda_i) if(scl_i===1 && !rst) begin
        starts=starts+1;mode=1;bitno=0;stage=0;rx=0;rx_bytes=0;reading=0;slave_low=0;
    end
    always @(posedge sda_i) if(scl_i===1 && !rst) begin stops=stops+1;mode=0;slave_low=0;end
    always @(posedge scl_i) if(!rst) begin
        case(mode)
            1:begin
                rx={rx[6:0],sda_i};
                if(bitno==7) begin
                    ack_ok=enabled && rx_bytes!=nack_byte;
                    if(stage==0) begin
                        if(rx[7:1]!=7'h34) $fatal(1,"wrong slave address");
                        reading=rx[0];
                    end else if(ack_ok) begin
                        if(stage==1) begin
                            pointer=rx;
                            if(pointer!=8'h64 && pointer!=8'h6e) $fatal(1,"wrong register");
                        end else begin
                            if(pointer!=8'h6e || reading) $fatal(1,"unexpected data write");
                            if(stage==2) clip_type=rx;
                            else if(stage==3) begin
                                clip_id=rx;clips[writes]=rx;writes=writes+1;
                                if(clip_type!=8'hff) $fatal(1,"wrong TTS type");
                            end else $fatal(1,"too many write bytes");
                        end
                    end
                    stage=stage+1;rx_bytes=rx_bytes+1;mode=2;ack_risen=0;bitno=0;
                end else bitno=bitno+1;
            end
            2:ack_risen=1;
            3:if(bitno==7) begin reads=reads+1;mode=4;ack_seen=0;end else bitno=bitno+1;
            4:begin ack_value=sda_i;ack_seen=1;if(!sda_i) $fatal(1,"single-byte read requires NACK");end
        endcase
    end
    always @(negedge scl_i) if(!rst) begin
        case(mode)
            2:if(!ack_risen) slave_low=ack_ok;
            else begin
                slave_low=0;
                if(!ack_ok) mode=5;
                else if(reading && stage==1) begin
                    if(pointer!=8'h64) $fatal(1,"read without result pointer");
                    tx=word;mode=3;bitno=0;slave_low=!tx[7];
                end else begin mode=1;bitno=0;rx=0;end
            end
            3:slave_low=!tx[7-bitno];
            4:if(!ack_seen) slave_low=0;
                else begin slave_low=0;mode=5;end
        endcase
    end
    always @(posedge clk) if(!rst) begin
        if(sample_valid) samples=samples+1;
        if(done_valid && done_ready) begin owners[completions]=done_owner;completions=completions+1;end
    end
    task step;begin @(posedge clk);#1;end endtask
    task wait_sample;
        input [7:0] id;
        begin
            @(negedge clk);word=id;
            // A preceding read may have sampled the previous word.
            @(posedge sample_valid);#1;
            if(sample_id!=id) begin @(negedge sample_valid);@(posedge sample_valid);#1;end
            if(sample_id!=id || sample_round!=round_id || sample_tag!=info_tag || !link_fresh)
                $fatal(1,"bad successful raw poll");
            step;
        end
    endtask
    task consume_done;
        input [1:0] owner;
        input [1:0] error_code;
        reg [129:0] held;
        begin
            wait(done_valid);#1;
            if(done_owner!=owner || done_cookie!=1 || done_error!=error_code)
                $fatal(1,"completion owner/cookie/error mismatch %d/%d",done_owner,done_error);
            held={done_owner,done_cookie,done_round,done_tag};
            repeat(8) begin step;
                if(!done_valid || {done_owner,done_cookie,done_round,done_tag}!==held || req_ready)
                    $fatal(1,"completion not held");
            end
            @(negedge clk);done_ready=1;step;
            @(negedge clk);done_ready=0;
        end
    endtask
    task request_one;
        input integer owner;
        begin
            @(negedge clk);req_valid[owner]=1;
            @(posedge clk);while(!req_ready[owner]) @(posedge clk);
            @(negedge clk);req_valid[owner]=0;
        end
    endtask
    integer before_samples,before_reads;
    initial begin
        repeat(5) step;@(negedge clk);rst=0;
        if(link_fresh) $fatal(1,"unproven link fresh");
        wait_sample(0);wait_sample(0);scenarios=scenarios+1;
        wait_sample(7);wait_sample(7); // duplicates AND zero are raw deliveries
        // Eligibility is captured at poll launch, not relabelled at response.
        @(negedge clk);poll_eligible=0;
        wait_sample(0);
        @(negedge sda_i);while(scl_i!==1) @(negedge sda_i);
        @(negedge clk);poll_eligible=1;
        @(posedge sample_valid);#1;
        if(sample_eligible) $fatal(1,"in-audio poll relabelled eligible at return");
        wait_sample(0);
        if(!sample_eligible) $fatal(1,"fresh eligible poll not restored");
        scenarios=scenarios+1;

        // All owners deliberately use the same cookie. Check fair routing and
        // a real result read between every two continuously pending writes.
        @(negedge clk);req_valid=7;before_reads=reads;
        @(posedge clk);while(!req_ready[0]) @(posedge clk);
        @(negedge clk);req_valid[0]=0;
        consume_done(0,0);
        @(posedge clk);while(!req_ready[1]) @(posedge clk);
        @(negedge clk);req_valid[1]=0;
        if(reads<=before_reads) $fatal(1,"poll starved by writes");
        before_reads=reads;consume_done(1,0);
        @(posedge clk);while(!req_ready[2]) @(posedge clk);
        @(negedge clk);req_valid[2]=0;
        if(reads<=before_reads) $fatal(1,"poll starved second write");
        consume_done(2,0);
        if(writes!=3 || clips[0]!=8'h40 || clips[1]!=8'h45 || clips[2]!=8'h47)
            $fatal(1,"wire byte order/fairness");
        scenarios=scenarios+1;

        // Rebind in-flight poll: old sample retains its issue-time identity.
        wait_sample(0);
        @(negedge sda_i);while(scl_i!==1) @(negedge sda_i);
        @(negedge clk);round_id=2;info_tag=64'h66;
        #1;if(link_fresh) $fatal(1,"old poll fresh under new identity");
        @(posedge sample_valid);#1;
        if(sample_round!=1 || sample_tag!=64'h55 || link_fresh) $fatal(1,"old read retagged");
        step;wait_sample(0);scenarios=scenarios+1;

        request_one(0);
        // Update request payload after handshake; completion stays original.
        @(negedge clk);req_cookie[31:0]=32'd9;req_round[31:0]=3;req_tag[63:0]=64'h77;
        consume_done(0,0);
        if(done_round!=1 || done_tag!=64'h55) $fatal(1,"write binding not latched");
        scenarios=scenarios+1;

        // Address NACK must neither yield a valid poll nor claim healthy link.
        @(negedge clk);enabled=0;before_samples=samples;
        repeat(2500) step;
        if(link_fresh || samples>before_samples+1) $fatal(1,"NACK produced trusted poll");
        req_cookie[63:32]=1;request_one(1);consume_done(1,1);
        scenarios=scenarios+1;

        @(negedge clk);enabled=1;wait_sample(8);
        @(negedge clk);stuck=1;
        repeat(500) step;
        if(link_fresh || scl_low || sda_low) $fatal(1,"timeout not released");
        @(negedge clk);stuck=0;slave_low=0;mode=0;
        wait_sample(0);scenarios=scenarios+1;

        request_one(2);wait(done_valid);#1;
        repeat(3100) step;
        if(link_fresh || !done_valid) $fatal(1,"held response failed staleness");
        @(negedge clk);rst=1;step;
        if(sample_valid || done_valid || link_fresh || scl_low || sda_low || req_ready)
            $fatal(1,"reset did not cancel/release");
        scenarios=scenarios+1;
        $display("PASS: voice_interaction_bus scenarios=%0d writes=%0d reads=%0d starts=%0d stops=%0d",
            scenarios,writes,reads,starts,stops);$finish;
    end
    initial begin #5000000;$fatal(1,"test timeout");end
endmodule
