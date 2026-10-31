`timescale 1ns/1ps
module i2c_transaction_arbiter_tb;
    reg clk=0,rst=1;
    always #10 clk=~clk;
    reg [1:0] s_req_valid=0,s_rsp_ready=0;
    wire [1:0] s_req_ready,s_rsp_valid;
    reg [13:0] s_device=0;reg [3:0] s_addr_bytes=0;
    reg [31:0] s_address=0;reg [11:0] s_wr_count=0,s_rd_count=0;
    reg [511:0] s_wr_data=0;
    wire [3:0] s_error;wire [511:0] s_rd_data;
    wire m_req_valid,m_rsp_ready,busy,owner,next_owner;
    reg m_req_ready=0,m_rsp_valid=0;
    wire [6:0] m_device;wire [1:0] m_addr_bytes;wire [15:0] m_address;
    wire [5:0] m_wr_count,m_rd_count;wire [255:0] m_wr_data;
    reg [1:0] m_error=0;reg [255:0] m_rd_data=0;
    wire [63:0] grants,completed;
    i2c_transaction_arbiter dut(.*);
    integer accepted[0:1],retired[0:1],served=0,selected=-1,phase=0,delay_cycles=0;
    integer wanted=0,request_owner,checks=0,k,n;
    reg [31:0] rng=32'h10293451;
    reg downstream_active=0,stall_old=0,response_old=0;
    reg [292:0] held_request;
    reg [1:0] held_response_valid;
    reg [515:0] held_response;
    function automatic [255:0] payload(input integer who,input integer seqnum);
        integer b;
        begin for(b=0;b<32;b=b+1) payload[b*8 +: 8]=8'(who*53+seqnum*7+b);end
    endfunction
    task automatic fill_client(input integer who);
        begin
            s_device[who*7 +: 7]=who?7'h50:7'h51;
            s_addr_bytes[who*2 +: 2]=who?2:1;
            s_address[who*16 +: 16]=16'(accepted[who]*32+who);
            s_wr_count[who*6 +: 6]=who?32:0;s_rd_count[who*6 +: 6]=who?0:9;
            s_wr_data[who*256 +: 256]=payload(who,accepted[who]);
        end
    endtask
    // Independent handshake scoreboards: source mutation after acceptance must
    // never change a stalled master's request or route another client's reply.
    always @(posedge clk) if(!rst) begin
        if(stall_old && (!m_req_valid || {m_device,m_addr_bytes,m_address,m_wr_count,m_rd_count,m_wr_data}!==held_request))
            $fatal(1,"FAIL: captured master request changed under stall");
        if(response_old && ({s_rsp_valid,s_error,s_rd_data}!=={held_response_valid,held_response}))
            $fatal(1,"FAIL: held response changed/delivered to another client");
        if((s_req_valid & s_req_ready)==2'b11 || s_rsp_valid==2'b11)
            $fatal(1,"FAIL: two owners");
        for(k=0;k<2;k=k+1) begin
            if(s_req_valid[k] && s_req_ready[k]) begin
                if(selected!=-1) $fatal(1,"FAIL: accepted another owner before response");
                selected=k;
                if(phase==1 && selected!=wanted) $fatal(1,"FAIL: saturated grant not round robin");
                wanted=1-selected;accepted[k]=accepted[k]+1;
            end
            if(s_rsp_valid[k] && s_rsp_ready[k]) begin
                if(selected!=k || s_error[k*2 +: 2]!==2'(retired[k]%4) ||
                    s_rd_data[k*256 +: 256]!==~payload(k,retired[k]))
                    $fatal(1,"FAIL: response ownership/error/data");
                retired[k]=retired[k]+1;selected=-1;downstream_active=0;
            end
        end
        if(m_req_valid && m_req_ready) begin
            if(selected<0 || downstream_active) $fatal(1,"FAIL: duplicated/ownerless request");
            request_owner=selected;
            if(m_device!==(request_owner?7'h50:7'h51) || m_addr_bytes!==(request_owner?2:1) ||
                m_address!==16'((accepted[request_owner]-1)*32+request_owner) ||
                m_wr_count!==(request_owner?32:0) || m_rd_count!==(request_owner?0:9) ||
                m_wr_data!==payload(request_owner,accepted[request_owner]-1))
                $fatal(1,"FAIL: request fields/payload");
            downstream_active=1;served=served+1;delay_cycles=3+rng[7:4];
        end
        stall_old<=m_req_valid && !m_req_ready;
        held_request<={m_device,m_addr_bytes,m_address,m_wr_count,m_rd_count,m_wr_data};
        response_old<=|s_rsp_valid && !m_rsp_ready;
        held_response_valid<=s_rsp_valid;held_response<={s_error,s_rd_data};
        checks=checks+1;
    end else begin stall_old<=0;response_old<=0;end
    always @(negedge clk) if(!rst && phase!=0) begin
        rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        for(n=0;n<2;n=n+1) begin
            fill_client(n);
            s_req_valid[n]=accepted[n]<120 && (phase==1 || rng[n]);
        end
        s_rsp_ready=rng[11:10];m_req_ready=rng[12];
        if(downstream_active && !m_rsp_valid) begin
            if(delay_cycles>0) delay_cycles=delay_cycles-1;
            else begin m_rsp_valid=1;m_error=2'(retired[request_owner]%4);m_rd_data=~payload(request_owner,retired[request_owner]);end
        end
        if(!downstream_active) m_rsp_valid=0;
    end
    task automatic reset_all;
        begin
            @(negedge clk);phase=0;rst=1;s_req_valid=0;s_rsp_ready=0;m_req_ready=0;m_rsp_valid=0;
            selected=-1;downstream_active=0;served=0;wanted=0;
            accepted[0]=0;accepted[1]=0;retired[0]=0;retired[1]=0;
            repeat(4) @(negedge clk);rst=0;
        end
    endtask
    initial begin
        reset_all();phase=1;
        wait(retired[0]==120 && retired[1]==120);@(negedge clk);phase=0;
        if(served!=240 || grants!={32'd120,32'd120} || completed!={32'd120,32'd120})
            $fatal(1,"FAIL: saturated accounting");
        $display("ARB saturation 240 complete with alternating grants and independent master/response stalls");
        reset_all();phase=2;
        wait(retired[0]==120 && retired[1]==120);@(negedge clk);phase=0;
        if(served!=240 || completed!={32'd120,32'd120}) $fatal(1,"FAIL: random accounting");
        // Common reset cancels a captured not-issued request, then recovery must
        // use only new input. Common reset also represents master cancellation.
        reset_all();fill_client(0);s_req_valid=1;
        @(posedge clk);@(negedge clk);s_req_valid=0;
        repeat(7) @(negedge clk);if(!m_req_valid) $fatal(1,"FAIL: expected pending issue");
        reset_all();#1;if(m_req_valid || |s_rsp_valid || busy || grants || completed) $fatal(1,"FAIL: reset pending");
        // Reset held error response using a manual transaction, no fake timeout.
        fill_client(0);s_req_valid=1;
        @(posedge clk);@(negedge clk);s_req_valid=0;m_req_ready=1;
        @(posedge clk);@(negedge clk);m_req_ready=0;m_rsp_valid=1;m_error=0;m_rd_data=~payload(0,0);
        repeat(8) @(negedge clk);if(s_rsp_valid!=1) $fatal(1,"FAIL: held response missing");
        reset_all();#1;if(|s_rsp_valid || busy) $fatal(1,"FAIL: response survived common reset");
        phase=1;wait(retired[0]==120 && retired[1]==120);@(negedge clk);phase=0;
        $display("PASS: i2c_transaction_arbiter 720 completed transactions saturation/random/reset-recovery checks=%0d",checks);$finish;
    end
    initial begin #2000000;$fatal(1,"FAIL: arbiter timeout accepted=%0d/%0d retired=%0d/%0d",accepted[0],accepted[1],retired[0],retired[1]);end
endmodule
