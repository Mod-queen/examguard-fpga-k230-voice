`timescale 1ns/1ps
// Independent byte-addressed retained EEPROM model. Resets clear bus state but
// NOT media. Inject cuts inside writes and before acknowledgement; all checks
// use raw bytes and a CRC oracle, not the controller's codec output.
module eeprom_dualslot_store_tb;
    reg clk=0,rst=1,cmd_valid=0,result_ready=0;
    always #10 clk=~clk;
    reg [1:0] cmd=0;
    reg [31:0] expected_device=32'hac750001;
    reg [255:0] config_data=256'h123456789abcdef;
    wire cmd_ready,result_valid,loaded,active_slot;
    wire [3:0] result_error;wire [31:0] device_id,generation,boot_id;wire [255:0] stored_config;
    wire bus_req_valid,bus_rsp_ready;
    reg bus_req_ready=0,bus_rsp_valid=0;
    wire [6:0] bus_device;wire [1:0] bus_addr_bytes;wire [15:0] bus_address;
    wire [5:0] bus_wr_count,bus_rd_count;wire [255:0] bus_wr_data;
    reg [1:0] bus_error=0;reg [255:0] bus_rd_data=0;
    eeprom_dualslot_store #(.MAX_POLLS(4)) dut(.*);
    reg [7:0] mem[0:8191],baseline[0:8191];
    integer phase=0,delay_count=0,busy_polls=0,write_calls=0,cut=-1,tear_mode=0;
    integer injected_error=-1,requests=0,completions=0,cut_checks=0;
    reg cut_seen=0;
    reg response_taken=0;
    always @(posedge clk) response_taken<=!rst && bus_rsp_valid && bus_rsp_ready;
    reg [15:0] addr_hold;
    reg [5:0] wc_hold,rc_hold;
    reg [1:0] addrlen_hold;
    reg [255:0] data_hold;
    integer q,b,write_index,cut_byte;
    always @(negedge clk) begin
        if(rst) begin phase=0;bus_req_ready=0;bus_rsp_valid=0;busy_polls=0;end
        else case(phase)
            0:begin
                bus_req_ready=0;bus_rsp_valid=0;
                if(bus_req_valid) begin
                    if(bus_device!=7'h50 || bus_wr_count>32 || bus_rd_count>32 ||
                        (bus_wr_count && bus_rd_count) || (bus_addr_bytes!=0 && bus_addr_bytes!=2))
                        $fatal(1,"FAIL: record bus shape");
                    if(bus_addr_bytes!=0 && !(bus_address>=16'h1e00 && bus_address<16'h1ee0))
                        $fatal(1,"FAIL: access outside reserved slots");
                    addr_hold=bus_address;wc_hold=bus_wr_count;rc_hold=bus_rd_count;
                    addrlen_hold=bus_addr_bytes;data_hold=bus_wr_data;
                    bus_req_ready=1;phase=1;
                end
            end
            1:begin bus_req_ready=0;delay_count=4;phase=2;end
            2:if(delay_count) delay_count=delay_count-1;
            else begin
                bus_error=0;bus_rd_data=0;
                if(requests==injected_error) bus_error=2;
                else if(addrlen_hold==0) begin
                    if(busy_polls>0) begin busy_polls=busy_polls-1;bus_error=1;end
                end else if(wc_hold) begin
                    if(addr_hold[4:0]+wc_hold>32) $fatal(1,"FAIL: page crossed");
                    write_index=write_calls;write_calls=write_calls+1;
                    for(q=0;q<wc_hold;q=q+1) begin
                        if(cut<0 || write_index!=cut/32 || q<=cut%32) mem[addr_hold+q]=data_hold[q*8 +: 8];
                    end
                    if(cut>=0 && write_index==cut/32) begin
                        // Alternate model corrupts suffix of addressed page too.
                        if(tear_mode) for(q=cut%32+1;q<32;q=q+1) mem[addr_hold+q]=8'(q*17+cut);
                        cut_seen=1;phase=4;
                    end
                    busy_polls=2;
                end else for(q=0;q<rc_hold;q=q+1) bus_rd_data[q*8 +: 8]=mem[addr_hold+q];
                requests=requests+1;
                if(phase!=4) begin bus_rsp_valid=1;phase=3;end
            end
            3:if(response_taken) begin bus_rsp_valid=0;phase=0;end
            4:begin bus_req_ready=0;bus_rsp_valid=0;end // power cut, no response
        endcase
    end
    task automatic reset_logic;
        begin
            @(negedge clk);rst=1;cmd_valid=0;result_ready=0;
            repeat(4) @(negedge clk);rst=0;
            repeat(2) @(negedge clk);
            if(loaded || result_valid) $fatal(1,"FAIL: reset leaked publication");
        end
    endtask
    task automatic issue(input integer op);
        begin
            @(negedge clk);cmd=op;cmd_valid=1;
            @(posedge clk);while(!cmd_ready) @(posedge clk);
            @(negedge clk);cmd_valid=0;
        end
    endtask
    task automatic consume(input integer error_code);
        reg [353:0] held;
        begin
            wait(result_valid);#1;
            if(result_error!=error_code || loaded!=(error_code==0))
                $fatal(1,"FAIL: record verdict error=%0d expected=%0d",result_error,error_code);
            held={loaded,active_slot,device_id,generation,boot_id,stored_config};
            repeat(5) begin @(negedge clk);
                if(!result_valid || {loaded,active_slot,device_id,generation,boot_id,stored_config}!==held || cmd_ready)
                    $fatal(1,"FAIL: record publication changed under backpressure");
            end
            result_ready=1;@(negedge clk);result_ready=0;completions=completions+1;
        end
    endtask
    function automatic [31:0] word_at(input integer a);
        word_at={mem[a+3],mem[a+2],mem[a+1],mem[a]};
    endfunction
    function automatic [31:0] crc_at(input integer a,input integer count);
        reg [31:0] c;integer i,j;
        begin
            c=32'hffffffff;
            for(i=0;i<count;i=i+1) for(j=0;j<8;j=j+1) begin
                if(c[0]^mem[a+i][j]) c=(c>>1)^32'hedb88320;else c=c>>1;
            end
            crc_at=~c;
        end
    endfunction
    task automatic check_raw(input integer slot,input integer gen,input integer bootnum);
        integer a;
        begin
            a=slot?16'h1e80:16'h1e00;
            if(word_at(a)!=32'h46434745 || word_at(a+4)!=32'h4001 || word_at(a+8)!=expected_device ||
                word_at(a+12)!=gen || word_at(a+16)!=bootnum || word_at(a+60)!=crc_at(a,60) ||
                word_at(a+64)!=32'h4d434745 || word_at(a+68)!=gen || word_at(a+72)!=~32'(gen) ||
                word_at(a+76)!=word_at(a+60) || word_at(a+92)!=crc_at(a+64,28))
                $fatal(1,"FAIL: independent raw record/CRC oracle");
        end
    endtask
    task automatic put_word(input integer a,input [31:0] v);
        begin mem[a]=v[7:0];mem[a+1]=v[15:8];mem[a+2]=v[23:16];mem[a+3]=v[31:24];end
    endtask
    task automatic repair_crc(input integer a);
        begin
            put_word(a+60,crc_at(a,60));put_word(a+68,word_at(a+12));put_word(a+72,~word_at(a+12));
            put_word(a+76,word_at(a+60));put_word(a+92,crc_at(a+64,28));
        end
    endtask
    integer i,c,old_boot,before_writes,slot_addr;
    initial begin
        for(i=0;i<8192;i=i+1) mem[i]=8'hff;
        reset_logic();issue(0);consume(2); // no automatic format
        if(write_calls) $fatal(1,"FAIL: scan wrote blank media");
        issue(3);consume(0);check_raw(0,1,1);
        if(boot_id!=1 || generation!=1) $fatal(1,"FAIL: format identity");
        issue(3);consume(8); // not an erase/format-existing API
        issue(1);consume(0);check_raw(1,2,2);
        config_data=~config_data;issue(2);consume(0);check_raw(0,3,2);
        issue(0);consume(0);
        if(stored_config!==config_data || boot_id!=2) $fatal(1,"FAIL: config preserved boot");
        for(i=0;i<8192;i=i+1) baseline[i]=mem[i];
        // Every byte cut in invalidation/body0/body1/commit, both prefix tear and
        // arbitrary suffix corruption. Last commit byte includes lost ACK case.
        for(tear_mode=0;tear_mode<2;tear_mode=tear_mode+1) for(c=0;c<128;c=c+1) begin
            reset_logic();for(i=0;i<8192;i=i+1) mem[i]=baseline[i];
            write_calls=0;cut=c;cut_seen=0;issue(1);wait(cut_seen);
            if(result_valid || loaded) $fatal(1,"FAIL: published before full verification");
            reset_logic();cut=-1;issue(0);consume(0);
            if(boot_id!=2 && boot_id!=3) $fatal(1,"FAIL: cut lost both old and new records");
            old_boot=boot_id;check_raw(active_slot,generation,boot_id);
            issue(1);consume(0);
            if(boot_id!=old_boot+1) $fatal(1,"FAIL: ambiguous commit reused boot");
            check_raw(active_slot,generation,boot_id);cut_checks=cut_checks+1;
        end
        reset_logic();for(i=0;i<8192;i=i+1) mem[i]=baseline[i];
        expected_device=123;issue(1);consume(4);expected_device=32'hac750001;
        // Invalid newest body falls back to intact old slot, no forged success.
        mem['h1e00+20]=mem['h1e00+20]^1;issue(0);consume(0);
        if(active_slot!=1 || generation!=2) $fatal(1,"FAIL: corrupt newest fallback");
        mem['h1e80+20]=mem['h1e80+20]^1;issue(0);consume(3);
        before_writes=write_calls;issue(3);consume(3);
        if(before_writes!=write_calls) $fatal(1,"FAIL: format overwrote nonblank corruption");
        // Fault during final verification: even if media is committed, no trust
        // until rescan. Fail original command, then allocate from persisted new.
        reset_logic();for(i=0;i<8192;i=i+1) mem[i]=baseline[i];
        injected_error=requests;issue(1);consume(1);injected_error=-1;
        issue(1);consume(0);if(boot_id!=3) $fatal(1,"FAIL: read error recovery");
        // Equal generation and mismatched device are not silently tie-broken.
        for(i=0;i<8192;i=i+1) mem[i]=baseline[i];
        put_word('h1e80+12,3);repair_crc('h1e80);issue(0);consume(5);
        put_word('h1e80+12,2);put_word('h1e80+8,123);repair_crc('h1e80);issue(0);consume(5);
        // Exhaustion is fail-closed, never wraps boot/generation to 0/1.
        for(i=0;i<8192;i=i+1) mem[i]=baseline[i];
        put_word('h1e00+12,32'hffffffff);repair_crc('h1e00);issue(1);consume(6);
        put_word('h1e00+12,3);put_word('h1e00+16,32'hffffffff);repair_crc('h1e00);issue(1);consume(6);
        // Media write succeeds, final reread fails: next command rescans and
        // increments from committed boot3, not stale previously published boot2.
        for(i=0;i<8192;i=i+1) mem[i]=baseline[i];
        injected_error=requests+26;issue(1);consume(1);injected_error=-1;
        check_raw(1,4,3);issue(1);consume(0);if(boot_id!=4) $fatal(1,"FAIL: uncertain committed record reused");
        // Untouched EEPROM and unused slot tails must remain untouched.
        for(i=0;i<'h1e00;i=i+1) if(mem[i]!=8'hff) $fatal(1,"FAIL: wrote outside slots");
        for(i='h1ee0;i<8192;i=i+1) if(mem[i]!=8'hff) $fatal(1,"FAIL: overwrote reserved tail");
        $display("PASS: eeprom_dualslot_store powercuts=%0d results=%0d explicit-format/config/boot/CRC/device/errors/raw-oracle",cut_checks,completions);$finish;
    end
    initial begin #50000000;$fatal(1,"FAIL: dualslot timeout state=%0d phase=%0d cut=%0d",dut.state,phase,cut);end
endmodule
