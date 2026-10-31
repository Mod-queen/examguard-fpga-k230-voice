`timescale 1ns/1ps
// MC byte stream -> endpoint -> actual shared service -> wire I2C devices -> MR.
// Reuses the pin-only media fixture from the already verified service TB.
module maintenance_system_tb;
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
    wire request_valid,request_ready,result_ready;
    reg maintenance_allowed=1;
    wire maintenance_busy,result_valid,config_known;
    wire [1:0] opcode;wire [255:0] proposed_config;wire [55:0] calendar_data;
    wire [1:0] result_opcode,result_recovery_error;
    wire [3:0] result_error,result_detail,result_store_error;wire result_write_attempted;
    wire [71:0] result_snapshot;wire [255:0] active_config;wire [31:0] config_generation;
    persistent_maintenance_service #(.STARTUP_CYCLES(20),.QUARTER_CYCLES(4),.TIMEOUT_CYCLES(120),
        .MAX_POLLS(4),.REFRESH_CYCLES(10000),.RTC_MAX_READ_CYCLES(1000000)) dut(.*);
    reg rx_valid=0;reg [7:0] rx_data=0;
    wire mr_valid,mr_last,command_pending;wire [7:0] mr_data;wire [31:0] rejected_lines;
    reg mr_ready=1;
    maintenance_endpoint endpoint(.clk(clk),.rst(rst),.rx_valid(rx_valid),.rx_data(rx_data),
        .device_id(expected_device),.boot_id(boot_id),.generation(generation),.boot_done(done),
        .config_known(config_known),.active_config(active_config),
        .request_valid(request_valid),.request_ready(request_ready),.opcode(opcode),
        .proposed_config(proposed_config),.calendar_data(calendar_data),.result_valid(result_valid),
        .result_ready(result_ready),.result_opcode(result_opcode),.result_recovery_error(result_recovery_error),
        .result_error(result_error),.result_detail(result_detail),.result_store_error(result_store_error),
        .result_write_attempted(result_write_attempted),.result_snapshot(result_snapshot),
        .byte_valid(mr_valid),.byte_last(mr_last),.byte_data(mr_data),.byte_ready(mr_ready),
        .command_pending(command_pending),.rejected_lines(rejected_lines));
    reg [7:0] rtc[0:255],media[0:8191];
    integer mode=0,bitno=0,stage=0,device=0,pointer=0,starts=0,stops=0,rtc_writes=0,eeprom_writes=0;
    integer busy_polls=0;
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
                    rtc[pointer&255]=rx;pointer=pointer+1;rtc_writes=rtc_writes+1;
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
    reg [511:0] commands[0:5];integer replies=0,executes=0,fd,mr_bytes=0;
    always @(posedge clk) if(!rst) begin
        if(request_valid && request_ready) executes=executes+1;
        if(mr_valid && mr_ready) begin
            $fwrite(fd,"%c",mr_data);mr_bytes=mr_bytes+1;
            if(mr_last) begin
                if(mr_bytes!=196) $fatal(1,"FAIL: system MR length");
                mr_bytes=0;replies=replies+1;
            end
        end
    end
    task automatic send_byte(input [7:0] data);
        begin @(negedge clk);rx_valid=1;rx_data=data;@(negedge clk);rx_valid=0;end
    endtask
    task automatic send(input [511:0] data);
        reg [3:0] n;integer k;
        begin
            send_byte("M");send_byte("C");send_byte(",");
            for(k=0;k<128;k=k+1) begin n=data[511-k*4 -: 4];send_byte(n<10?"0"+n:"A"+n-10);end
            send_byte(10);
        end
    endtask
    integer i,writes_before;
    initial begin
        fd=$fopen("maintenance_system_results.txt","w");
        $readmemh("D:/fpga_race/docs/baselines/maintenance_commands_20261021.mem",commands);
        for(i=0;i<8192;i=i+1) media[i]=8'hff;
        for(i=0;i<256;i=i+1) rtc[i]=0;
        rtc[2]='h10;rtc[3]='h30;rtc[4]='h12;rtc[5]='h21;rtc[6]=3;rtc[7]='h10;rtc[8]='h26;
        seed();repeat(4) @(negedge clk);rst=0;wait(admission && config_known);
        send(commands[0]);wait(replies==1);repeat(3) @(negedge clk);
        send(commands[1]);wait(replies==2);repeat(3) @(negedge clk);
        if(config_generation!=19 || boot_id!=18 || active_config[95:64]!=42) $fatal(1,"FAIL: UART SAVE result publication");
        writes_before=eeprom_writes;
        send(commands[1]);wait(replies==3);repeat(3) @(negedge clk);
        if(eeprom_writes!=writes_before) $fatal(1,"FAIL: UART duplicate wrote EEPROM twice");
        send(commands[2]);wait(replies==4);repeat(3) @(negedge clk);
        if(rtc_writes!=9 || boot_id!=18 || executes!=3 || rejected_lines!=0) $fatal(1,"FAIL: UART SET_RTC shared service");
        $fclose(fd);$display("PASS: maintenance_system MC/endpoint/service/pin-only dual devices/MR executes=%0d replies=%0d RTCwrites=%0d EEPROMwrites=%0d",executes,replies,rtc_writes,eeprom_writes);$finish;
    end
    initial begin #20000000;$fatal(1,"FAIL: maintenance_system timeout endpoint=%0d service=%0d",endpoint.state,dut.state);end
endmodule
