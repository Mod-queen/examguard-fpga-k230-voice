`timescale 1ns/1ps
// Pin-edge oracle, retained media across DUT reset. Not physical brownout model.
module persistent_boot_probe_tb;
    reg clk=0,rst=1,format_request=0;
    always #10 clk=~clk;
    tri1 scl,sda;
    wire scl_low,sda_low,uart_txd,waiting_format,admission,done;
    reg slave_low=0,wp=0;
    assign scl=scl_low?1'b0:1'bz;
    assign sda=(sda_low || slave_low)?1'b0:1'bz;
    persistent_boot_probe #(.QUARTER_CYCLES(4),.TIMEOUT_CYCLES(120),
        .STARTUP_CYCLES(20),.UART_BAUD(115200),.MAX_POLLS(4)) dut(
        .clk(clk),.rst(rst),.format_request(format_request),.scl_i(scl),.sda_i(sda),
        .scl_low(scl_low),.sda_low(sda_low),.uart_txd(uart_txd),
        .waiting_format(waiting_format),.admission(admission),.done(done));
    reg [7:0] media[0:8191],rtc[0:8],saved_slot[0:127];
    integer mode=0,bitno=0,stage=0,device=0,pointer=0;
    integer starts=0,stops=0,wr_bytes=0,rd_bytes=0,busy_polls=0,busy_nacks=0;
    reg [7:0] rx=0,tx=0;
    reg ack_ok=0,ack_risen=0,reading=0,master_ack_seen=0,ack_value=0,page_written=0;
    always @(negedge sda) if(scl===1'b1 && !rst) begin
        starts=starts+1;mode=1;bitno=0;stage=0;rx=0;reading=0;slave_low=0;
    end
    always @(posedge sda) if(scl===1'b1 && !rst) begin
        stops=stops+1;mode=0;slave_low=0;
        if(page_written) begin busy_polls=2;page_written=0;end
    end
    always @(posedge scl) if(!rst) case(mode)
        1:begin
            rx={rx[6:0],sda};
            if(bitno==7) begin
                ack_ok=1;
                if(stage==0) begin
                    device=rx[7:1];reading=rx[0];ack_ok=device=='h50 || device=='h51;
                    if(device=='h50 && busy_polls>0) begin
                        ack_ok=0;busy_polls=busy_polls-1;busy_nacks=busy_nacks+1;
                    end
                end
                if(ack_ok && stage!=0) begin
                    if(device=='h51 && stage==1) pointer=rx;
                    else if(device=='h50 && stage==1) pointer=rx<<8;
                    else if(device=='h50 && stage==2) pointer=pointer|rx;
                    else begin
                        if(device!='h50 || pointer<'h1e00 || pointer>='h1f00)
                            $fatal(1,"FAIL: data write outside reserved EEPROM region/device");
                        if(!wp) begin media[pointer]=rx;page_written=1;end
                        pointer=pointer+1;wr_bytes=wr_bytes+1;
                    end
                end
                stage=stage+1;mode=2;ack_risen=0;bitno=0;
            end else bitno=bitno+1;
        end
        2:ack_risen=1;
        3:if(bitno==7) begin rd_bytes=rd_bytes+1;mode=4;master_ack_seen=0;end
            else bitno=bitno+1;
        4:begin ack_value=sda;master_ack_seen=1;end
    endcase
    always @(negedge scl) if(!rst) case(mode)
        2:if(!ack_risen) slave_low=ack_ok;
            else begin
                slave_low=0;
                if(!ack_ok) mode=5;
                else if(reading && stage==1) begin
                    tx=(device==7'h51) ? rtc[pointer] : media[pointer];pointer=pointer+1;
                    mode=3;bitno=0;slave_low=!tx[7];
                end else begin mode=1;bitno=0;rx=0;end
            end
        3:slave_low=!tx[7-bitno];
        4:if(!master_ack_seen) slave_low=0;
            else if(ack_value) begin slave_low=0;mode=5;end
            else begin
                tx=(device==7'h51) ? rtc[pointer] : media[pointer];pointer=pointer+1;
                mode=3;bitno=0;slave_low=!tx[7];
            end
    endcase
    integer uart_file=0,uart_bytes=0;
    reg [7:0] uart_byte;
    initial forever begin
        @(negedge uart_txd);#13020;
        for(integer b=0;b<8;b=b+1) begin uart_byte[b]=uart_txd;#8680;end
        if(uart_txd!==1 || !uart_file) $fatal(1,"FAIL: boot probe UART stop/file");
        $fdisplay(uart_file,"%02x",uart_byte);uart_bytes=uart_bytes+1;
    end
    task automatic open_trace(input [255:0] filename);
        begin uart_file=$fopen(filename,"w");uart_bytes=0;end
    endtask
    task automatic reset_probe;
        begin
            @(negedge clk);rst=1;format_request=0;slave_low=0;mode=0;
            repeat(8) @(negedge clk);rst=0;
        end
    endtask
    task automatic finish_report(input integer expected_admission,input integer expected_error);
        integer old_writes,old_starts;
        begin
            wait(done);repeat(10) @(negedge clk);
            if(admission!=expected_admission || dut.result_error!=expected_error || uart_bytes!=348)
                $fatal(1,"FAIL: admission/error/UART count %0d/%0d/%0d",admission,dut.result_error,uart_bytes);
            old_writes=wr_bytes;old_starts=starts;
            repeat(4) begin
                format_request=1;@(negedge clk);format_request=0;repeat(20) @(negedge clk);
            end
            if(wr_bytes!=old_writes || starts!=old_starts || uart_bytes!=348)
                $fatal(1,"FAIL: repeated start after completion allocated/wrote/reported twice");
            for(integer k=0;k<8192;k=k+1)
                if((k<'h1e00 || k>='h1f00) && media[k]!==8'(k^'ha7))
                    $fatal(1,"FAIL: outside reserved region changed");
            for(integer k=0;k<32;k=k+1)
                if(media['h1e60+k]!==8'hff || media['h1ee0+k]!==8'hff)
                    $fatal(1,"FAIL: unused page changed");
            $fclose(uart_file);uart_file=0;
        end
    endtask
    integer i,before_writes;
    initial begin
        for(i=0;i<8192;i=i+1) media[i]=i^'ha7;
        for(i='h1e00;i<'h1f00;i=i+1) media[i]=8'hff;
        rtc[0]=0;rtc[1]=0;rtc[2]='h35;rtc[3]='h40;rtc[4]='h14;
        rtc[5]='h20;rtc[6]=2;rtc[7]='h10;rtc[8]='h26;
        open_trace("boot_probe_format.hex");reset_probe;
        // A pulse while scanning must not authorize a future blank format.
        format_request=1;@(negedge clk);format_request=0;
        wait(waiting_format);repeat(1000) @(negedge clk);
        if(wr_bytes || uart_bytes || admission) $fatal(1,"FAIL: blank media automatically formatted/admitted");
        format_request=1;@(negedge clk);format_request=0;
        finish_report(1,0);
        if(wr_bytes!=128 || busy_nacks!=8) $fatal(1,"FAIL: format page/poll accounting");
        for(i=0;i<128;i=i+1) saved_slot[i]=media['h1e00+i];
        before_writes=wr_bytes;open_trace("boot_probe_reset2.hex");reset_probe;finish_report(1,0);
        if(dut.saved_boot!=2 || dut.saved_generation!=2 || dut.saved_slot!=1 || wr_bytes-before_writes!=128)
            $fatal(1,"FAIL: reset boot2 identity/slot/write accounting");
        for(i=0;i<128;i=i+1) if(media['h1e00+i]!==saved_slot[i]) $fatal(1,"FAIL: old active slot modified");
        for(i=0;i<128;i=i+1) saved_slot[i]=media['h1e80+i];
        before_writes=wr_bytes;open_trace("boot_probe_reset3.hex");reset_probe;finish_report(1,0);
        if(dut.saved_boot!=3 || dut.saved_generation!=3 || dut.saved_slot!=0 || wr_bytes-before_writes!=128)
            $fatal(1,"FAIL: reset boot3 identity/slot/write accounting");
        for(i=0;i<128;i=i+1) if(media['h1e80+i]!==saved_slot[i]) $fatal(1,"FAIL: old active slot2 modified");
        // ACKed but write-protected media cannot open admission; old slot survives.
        wp=1;open_trace("boot_probe_wp.hex");reset_probe;finish_report(0,9);wp=0;
        // Both records corrupt: do not silently format even if button pressed.
        media['h1e00]=0;media['h1e80]=0;before_writes=wr_bytes;
        open_trace("boot_probe_corrupt.hex");reset_probe;finish_report(0,3);
        if(wr_bytes!=before_writes) $fatal(1,"FAIL: corrupt nonblank media was written");
        $display("PASS: persistent_boot_probe wireOnlySlave explicitBlankFormat/resetBoot1to3/oldSlot/WP/corrupt/oneAllocation/reservedOnly realUART5x348 START=%0d STOP=%0d busyNACK=%0d",starts,stops,busy_nacks);
        $finish;
    end
    initial begin #300000000;$fatal(1,"FAIL: persistent boot probe timeout state=%0d",dut.state);end
endmodule
