`timescale 1ns/1ps
// Actual boot/store/RTC/setter/arbiter/master with retained pin-only media.
module persistent_maintenance_service_tb;
    reg clk=0,rst=1;always #10 clk=~clk;
    reg [31:0] expected_device=1;reg [63:0] monotonic_ms=0;
    always @(posedge clk) if(rst) monotonic_ms<=0;else monotonic_ms<=monotonic_ms+1;
    tri1 scl_i,sda_i;wire scl_low,sda_low;
    reg slave_low=0;
    assign scl_i=scl_low?1'b0:1'bz;
    assign sda_i=(sda_low||slave_low)?1'b0:1'bz;
    wire admission,done,active_slot,rtc_known,rtc_fresh,byte_valid,byte_last;
    wire [3:0] error;wire [31:0] boot_id,generation,rtc_age_cycles;
    wire [7:0] byte_data;reg byte_ready=1;
    reg request_valid=0,maintenance_allowed=1,result_ready=0;
    wire request_ready,maintenance_busy,result_valid,config_known;
    reg [1:0] opcode=0;
    reg [255:0] proposed_config={120'd0,8'h00,16'sd480,16'd2700,32'd42,64'h0000200131504745};
    reg [55:0] calendar_data=56'h26100321123456;
    wire [1:0] result_opcode,result_recovery_error;
    wire [3:0] result_error,result_detail,result_store_error;wire result_write_attempted;
    wire [71:0] result_snapshot;wire [255:0] active_config;wire [31:0] config_generation;
    persistent_maintenance_service #(.STARTUP_CYCLES(20),.QUARTER_CYCLES(4),.TIMEOUT_CYCLES(120),
        .MAX_POLLS(4),.REFRESH_CYCLES(200),.RTC_MAX_READ_CYCLES(1000000)) dut(.*);
    reg [7:0] rtc[0:255],media[0:8191];
    integer mode=0,bitno=0,stage=0,device=0,pointer=0,starts=0,stops=0,rtc_writes=0,eeprom_writes=0;
    integer busy_polls=0,nack_rtc_register=-1,nacks=0;
    reg [7:0] rx=0,tx=0;
    reg ack_ok=0,ack_risen=0,reading=0,master_ack_seen=0,ack_value=0,page_written=0;
    always @(negedge sda_i) if(scl_i===1'b1 && !rst) begin
        starts=starts+1;mode=1;bitno=0;stage=0;rx=0;reading=0;slave_low=0;
    end
    always @(posedge sda_i) if(scl_i===1'b1 && !rst) begin
        stops=stops+1;mode=0;slave_low=0;
        if(page_written) begin busy_polls=2;page_written=0;end
    end
    always @(posedge scl_i) if(!rst) case(mode)
        1:begin
            rx={rx[6:0],sda_i};
            if(bitno==7) begin
                ack_ok=1;
                if(stage==0) begin
                    device=rx[7:1];reading=rx[0];
                    if(device!='h50 && device!='h51) $fatal(1,"FAIL: unknown I2C device");
                    if(device=='h50 && busy_polls>0) begin ack_ok=0;busy_polls=busy_polls-1;end
                end else if(device=='h51 && stage==1) pointer=rx;
                else if(device=='h50 && stage==1) pointer=rx<<8;
                else if(device=='h50 && stage==2) pointer=pointer|rx;
                else if(device=='h51) begin
                    if(!maintenance_busy) $fatal(1,"FAIL: RTC write outside maintenance");
                    if(pointer==nack_rtc_register) begin ack_ok=0;nack_rtc_register=-1;nacks=nacks+1;end
                    else begin rtc[pointer&255]=rx;pointer=pointer+1;rtc_writes=rtc_writes+1;end
                end else begin
                    if(pointer<'h1e00 || pointer>='h1f00 || (pointer&127)>=96) $fatal(1,"FAIL: EEPROM write outside slots");
                    media[pointer]=rx;pointer=pointer+1;eeprom_writes=eeprom_writes+1;page_written=1;
                end
                stage=stage+1;mode=2;ack_risen=0;bitno=0;
            end else bitno=bitno+1;
        end
        2:ack_risen=1;
        3:if(bitno==7) begin mode=4;master_ack_seen=0;end else bitno=bitno+1;
        4:begin ack_value=sda_i;master_ack_seen=1;end
    endcase
    always @(negedge scl_i) if(!rst) case(mode)
        2:if(!ack_risen) slave_low=ack_ok;
        else begin
            slave_low=0;
            if(!ack_ok) mode=5;
            else if(reading && stage==1) begin
                tx=device=='h51 ? rtc[pointer&255] : media[pointer&8191];pointer=pointer+1;
                mode=3;bitno=0;slave_low=!tx[7];
            end else begin mode=1;bitno=0;rx=0;end
        end
        3:slave_low=!tx[7-bitno];
        4:if(!master_ack_seen) slave_low=0;
        else if(ack_value) begin slave_low=0;mode=5;end
        else begin
            tx=device=='h51 ? rtc[pointer&255] : media[pointer&8191];pointer=pointer+1;
            mode=3;bitno=0;slave_low=!tx[7];
        end
    endcase
    function automatic [31:0] crc(input integer addr,input integer count);
        reg [31:0] c;integer i,j;
        begin c=32'hffffffff;
            for(i=0;i<count;i=i+1) for(j=0;j<8;j=j+1)
                if(c[0]^media[addr+i][j]) c=(c>>1)^32'hedb88320;else c=c>>1;
            crc=~c;
        end
    endfunction
    task automatic word(input integer addr,input [31:0] value);
        begin for(integer i=0;i<4;i=i+1) media[addr+i]=value[8*i+:8];end
    endtask
    task automatic seed;
        begin
            for(integer i=0;i<96;i=i+1) media['h1e00+i]=0;
            word('h1e00,32'h46434745);word('h1e04,32'h4001);word('h1e08,1);
            word('h1e0c,17);word('h1e10,17);word('h1e3c,crc('h1e00,60));
            word('h1e40,32'h4d434745);word('h1e44,17);word('h1e48,~32'd17);
            word('h1e4c,crc('h1e00,60));word('h1e5c,crc('h1e40,28));
        end
    endtask
    integer anchors=0,bytes_seen=0,results=0;
    always @(posedge clk) if(!rst && byte_valid && byte_ready) begin
        bytes_seen=bytes_seen+1;
        if(byte_last) begin
            if(bytes_seen!=132) $fatal(1,"FAIL: RA interrupted packet");
            anchors=anchors+1;bytes_seen=0;
        end
    end
    task automatic command(input [1:0] operation);
        begin
            @(negedge clk);opcode=operation;request_valid=1;
            @(posedge clk);while(!request_ready) @(posedge clk);
            @(negedge clk);request_valid=0;
        end
    endtask
    task automatic consume(input integer expected_error);
        reg [88:0] held;
        begin
            wait(result_valid);#1;held={result_opcode,result_error,result_detail,result_store_error,result_recovery_error,result_write_attempted,result_snapshot};
            repeat(9) begin @(negedge clk);
                if(result_error!=expected_error || !result_valid || request_ready || !maintenance_busy ||
                  {result_opcode,result_error,result_detail,result_store_error,result_recovery_error,result_write_attempted,result_snapshot}!==held)
                    $fatal(1,"FAIL: maintenance held result %0d/%0d",result_error,expected_error);
            end
            result_ready=1;@(negedge clk);result_ready=0;results=results+1;
        end
    endtask
    integer i,before_writes,old_anchors;
    reg [255:0] wanted;
    initial begin
        for(i=0;i<8192;i=i+1) media[i]=8'hff;
        for(i=0;i<256;i=i+1) rtc[i]=0;
        rtc[2]='h10;rtc[3]='h30;rtc[4]='h12;rtc[5]='h21;rtc[6]=3;rtc[7]='h10;rtc[8]='h26;
        seed();repeat(4) @(negedge clk);rst=0;
        wait(admission && config_known);#1;
        if(boot_id!=18 || active_config!=0 || config_generation!=18) $fatal(1,"FAIL: boot first/profile publication");
        // Hold old RA output, accept maintenance, and prove it waits with no writes.
        byte_ready=0;wait(byte_valid);before_writes=rtc_writes;
        command(2);repeat(200) @(negedge clk);
        if(result_valid || rtc_writes!=before_writes || !maintenance_busy) $fatal(1,"FAIL: maintenance overtook old anchor");
        byte_ready=1;consume(0);
        if(result_snapshot[71:16]!==calendar_data || rtc_known || boot_id!=18) $fatal(1,"FAIL: RTC set/old trust/boot");
        old_anchors=anchors;wait(anchors>old_anchors);#1;if(!rtc_known) $fatal(1,"FAIL: post-set refresh");
        // Active-exam commands rejected, no RTC writes; force request between anchors.
        maintenance_allowed=0;before_writes=rtc_writes;command(2);consume(1);
        if(rtc_writes!=before_writes) $fatal(1,"FAIL: active exam write");maintenance_allowed=1;
        command(3);consume(2);
        wanted=proposed_config;command(1);proposed_config=0;consume(0);
        if(active_config!==wanted || config_generation!=19 || boot_id!=18 || !result_write_attempted)
            $fatal(1,"FAIL: config save boot/profile");
        command(0);consume(0);
        if(result_write_attempted || active_config!==wanted) $fatal(1,"FAIL: read-only LOAD");
        nack_rtc_register=4;calendar_data=56'h26100422123456;command(2);consume(4);
        if(result_detail!=3 || result_recovery_error!=0 || rtc[0]!=0 || nacks!=1 || !admission)
            $fatal(1,"FAIL: partial RTC failure lost admission/recovery");
        command(2);consume(0);
        @(negedge clk);rst=1;repeat(5) @(negedge clk);rst=0;mode=0;slave_low=0;
        wait(admission && config_known);#1;
        if(boot_id!=19 || config_generation!=20 || active_config!==wanted) $fatal(1,"FAIL: system reset/config retention");
        for(i=0;i<'h1e00;i=i+1) if(media[i]!=8'hff) $fatal(1,"FAIL: outside EEPROM region");
        $display("PASS: persistent_maintenance_service results=%0d RA=%0d START=%0d STOP=%0d RTCwrites=%0d EEPROMwrites=%0d boot-priority/drain/held/save/load/reject/RTC-failure/reset",results,anchors,starts,stops,rtc_writes,eeprom_writes);
        $finish;
    end
    initial begin #20000000;$fatal(1,"FAIL: maintenance service timeout state=%0d setter=%0d phase=%0d arb=%0d master=%0d req=%b ready=%b rsp=%b take=%b mode=%0d results=%0d starts=%0d",dut.state,dut.setter.state,dut.setter.phase,dut.arbiter.busy,dut.master.state,dut.c_valid,dut.c_ready,dut.c_rsp_valid,dut.c_rsp_ready,mode,results,starts);end
endmodule
