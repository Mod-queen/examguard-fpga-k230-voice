`timescale 1ns/1ps
// Pin-edge-only slave oracle: never reads DUT state/counters for decode.
// Simplified PCF8563/24LC64 map, EEPROM busy and write-protect hooks. Not a
// full vendor device model; tests bus framing/address widths/ACK/byte ordering.
module i2c_register_master_tb #(parameter SERVICE_MODE=0);
    reg clk=0,rst=1;
    always #10 clk=~clk;
    reg req_valid=0,rsp_ready=0;
    wire req_ready,rsp_valid,scl_low,sda_low;
    reg [6:0] req_device=7'h51;
    reg [1:0] req_addr_bytes=1;
    reg [15:0] req_address=0;
    reg [5:0] req_wr_count=0,req_rd_count=0;
    reg [255:0] req_wr_data=0;
    wire [1:0] rsp_error;
    wire [255:0] rsp_rd_data;
    tri1 scl_i,sda_i;
    reg slave_low=0,stretch_low=0,stuck_sda=0;
    wire probe_scl_low,probe_sda_low,probe_uart,probe_done;
    assign scl_i=((SERVICE_MODE==3?probe_scl_low:scl_low) || stretch_low)?1'b0:1'bz;
    assign sda_i=((SERVICE_MODE==3?probe_sda_low:sda_low) || slave_low || stuck_sda)?1'b0:1'bz;
    persistence_inventory_probe #(.QUARTER_CYCLES(4),.TIMEOUT_CYCLES(120),.STARTUP_CYCLES(20)) inventory(
        .clk(clk),.rst(rst),.scl_i(scl_i),.sda_i(sda_i),.scl_low(probe_scl_low),.sda_low(probe_sda_low),
        .uart_txd(probe_uart),.done(probe_done));
    reg select_eeprom=0,refresh_valid=0,rtc_result_ready=0,write_valid=0,page_result_ready=0;
    wire refresh_ready,rtc_result_valid,rtc_known,rtc_fresh,write_ready,page_result_valid;
    wire [1:0] rtc_result_error;wire [2:0] page_result_error;
    wire [71:0] rtc_snapshot;wire [31:0] rtc_age;
    wire [15:0] rtc_year;wire [7:0] rtc_month,rtc_day,rtc_hour,rtc_minute,rtc_second;wire [2:0] rtc_weekday;
    reg [12:0] write_address=0;reg [5:0] write_count=0;reg [255:0] write_data=0;
    wire [1:0] c_valid,c_ready,c_rsp_valid,c_rsp_ready;
    wire [13:0] c_device;wire [3:0] c_addr_bytes;wire [31:0] c_address;
    wire [11:0] c_wr_count,c_rd_count;wire [511:0] c_wr_data;
    wire [3:0] c_error;wire [511:0] c_rd_data;
    wire a_req_valid,a_rsp_ready;
    wire [6:0] a_device;wire [1:0] a_addr_bytes;wire [15:0] a_address;
    wire [5:0] a_wr_count,a_rd_count;wire [255:0] a_wr_data;
    wire [63:0] a_grants,a_completed;
    wire anchor_byte_valid,anchor_byte_last;
    wire [7:0] anchor_byte_data;
    reg anchor_byte_ready=0;
    reg [63:0] anchor_monotonic=0;
    always @(posedge clk) if(rst) anchor_monotonic<=0;else anchor_monotonic<=anchor_monotonic+1'b1;
    generate if(SERVICE_MODE==4) begin: anchor_client_mode
        rtc_anchor_client #(.MAX_READ_CYCLES(1000000)) client(
            .clk(clk),.rst(rst),.boot_admission(!rst),.device_id(32'd1),.boot_id(32'd7),.monotonic_ms(anchor_monotonic),
            .refresh_valid(refresh_valid),.refresh_ready(refresh_ready),.known(rtc_known),.fresh(rtc_fresh),.age_cycles(rtc_age),
            .byte_valid(anchor_byte_valid),.byte_last(anchor_byte_last),.byte_data(anchor_byte_data),.byte_ready(anchor_byte_ready),
            .bus_req_valid(c_valid[0]),.bus_req_ready(c_ready[0]),.bus_device(c_device[6:0]),.bus_addr_bytes(c_addr_bytes[1:0]),
            .bus_address(c_address[15:0]),.bus_wr_count(c_wr_count[5:0]),.bus_rd_count(c_rd_count[5:0]),.bus_wr_data(c_wr_data[255:0]),
            .bus_rsp_valid(c_rsp_valid[0]),.bus_rsp_ready(c_rsp_ready[0]),.bus_error(c_error[1:0]),.bus_rd_data(c_rd_data[255:0]));
    end else begin: reader_client_mode
    pcf8563_reader #(.STALE_CYCLES(1000000)) rtc_client(
        .clk(clk),.rst(rst),.refresh_valid(refresh_valid),.refresh_ready(refresh_ready),
        .result_valid(rtc_result_valid),.result_ready(rtc_result_ready),.result_error(rtc_result_error),
        .snapshot(rtc_snapshot),.known(rtc_known),.fresh(rtc_fresh),.age_cycles(rtc_age),
        .year(rtc_year),.month(rtc_month),.day(rtc_day),.hour(rtc_hour),.minute(rtc_minute),.second(rtc_second),.weekday(rtc_weekday),
        .bus_req_valid(c_valid[0]),.bus_req_ready(c_ready[0]),.bus_device(c_device[6:0]),.bus_addr_bytes(c_addr_bytes[1:0]),
        .bus_address(c_address[15:0]),.bus_wr_count(c_wr_count[5:0]),.bus_rd_count(c_rd_count[5:0]),.bus_wr_data(c_wr_data[255:0]),
        .bus_rsp_valid(c_rsp_valid[0]),.bus_rsp_ready(c_rsp_ready[0]),.bus_error(c_error[1:0]),.bus_rd_data(c_rd_data[255:0]));
    end endgenerate
    eeprom_page_writer #(.MAX_POLLS(3)) page_client(
        .clk(clk),.rst(rst),.write_valid(write_valid),.write_ready(write_ready),
        .write_address(write_address),.write_count(write_count),.write_data(write_data),
        .result_valid(page_result_valid),.result_ready(page_result_ready),.result_error(page_result_error),
        .bus_req_valid(c_valid[1]),.bus_req_ready(c_ready[1]),.bus_device(c_device[13:7]),.bus_addr_bytes(c_addr_bytes[3:2]),
        .bus_address(c_address[31:16]),.bus_wr_count(c_wr_count[11:6]),.bus_rd_count(c_rd_count[11:6]),.bus_wr_data(c_wr_data[511:256]),
        .bus_rsp_valid(c_rsp_valid[1]),.bus_rsp_ready(c_rsp_ready[1]),.bus_error(c_error[3:2]),.bus_rd_data(c_rd_data[511:256]));
    generate if(SERVICE_MODE==2 || SERVICE_MODE==4) begin: fair
        i2c_transaction_arbiter arbiter(.clk(clk),.rst(rst),
            .s_req_valid(c_valid),.s_req_ready(c_ready),.s_device(c_device),.s_addr_bytes(c_addr_bytes),
            .s_address(c_address),.s_wr_count(c_wr_count),.s_rd_count(c_rd_count),.s_wr_data(c_wr_data),
            .s_rsp_valid(c_rsp_valid),.s_rsp_ready(c_rsp_ready),.s_error(c_error),.s_rd_data(c_rd_data),
            .m_req_valid(a_req_valid),.m_req_ready(req_ready),.m_device(a_device),.m_addr_bytes(a_addr_bytes),
            .m_address(a_address),.m_wr_count(a_wr_count),.m_rd_count(a_rd_count),.m_wr_data(a_wr_data),
            .m_rsp_valid(rsp_valid),.m_rsp_ready(a_rsp_ready),.m_error(rsp_error),.m_rd_data(rsp_rd_data),
            .busy(),.owner(),.next_owner(),.grants(a_grants),.completed(a_completed));
    end else begin: explicit_owner
        // Retain old sequential service regression and raw byte oracle mode.
        assign c_ready=SERVICE_MODE ? (select_eeprom?{req_ready,1'b0}:{1'b0,req_ready}):0;
        assign c_rsp_valid=SERVICE_MODE ? (select_eeprom?{rsp_valid,1'b0}:{1'b0,rsp_valid}):0;
        assign c_error={rsp_error,rsp_error};assign c_rd_data={rsp_rd_data,rsp_rd_data};
        assign a_req_valid=SERVICE_MODE?c_valid[select_eeprom]:req_valid;
        assign a_device=SERVICE_MODE?c_device[select_eeprom*7 +: 7]:req_device;
        assign a_addr_bytes=SERVICE_MODE?c_addr_bytes[select_eeprom*2 +: 2]:req_addr_bytes;
        assign a_address=SERVICE_MODE?c_address[select_eeprom*16 +: 16]:req_address;
        assign a_wr_count=SERVICE_MODE?c_wr_count[select_eeprom*6 +: 6]:req_wr_count;
        assign a_rd_count=SERVICE_MODE?c_rd_count[select_eeprom*6 +: 6]:req_rd_count;
        assign a_wr_data=SERVICE_MODE?c_wr_data[select_eeprom*256 +: 256]:req_wr_data;
        assign a_rsp_ready=SERVICE_MODE?c_rsp_ready[select_eeprom]:rsp_ready;
        assign a_grants=0;assign a_completed=0;
    end endgenerate
    i2c_register_master #(.QUARTER_CYCLES(4),.TIMEOUT_CYCLES(120)) dut(
        .req_valid(a_req_valid),.req_device(a_device),.req_addr_bytes(a_addr_bytes),.req_address(a_address),
        .req_wr_count(a_wr_count),.req_rd_count(a_rd_count),.req_wr_data(a_wr_data),.rsp_ready(a_rsp_ready),.*);
    reg [7:0] rtc[0:255],eeprom[0:8191];
    integer mode=0,bitno=0,stage=0,device=0,pointer=0;
    integer starts=0,stops=0,wr_bytes=0,rd_bytes=0,master_acks=0,master_nacks=0;
    integer nack_byte=-1,rx_bytes=0,busy_polls=0,transactions=0,i,j;
    reg [7:0] rx=0,tx=0;
    reg ack_ok=0,ack_risen=0,reading=0,master_ack_seen=0,ack_value=0;
    reg wp=0;
    reg page_written=0;
    always @(negedge sda_i) if(scl_i===1'b1 && !rst) begin
        starts=starts+1;mode=1;bitno=0;stage=0;rx=0;rx_bytes=0;reading=0;slave_low=0;
    end
    always @(posedge sda_i) if(scl_i===1'b1 && !rst) begin
        stops=stops+1;mode=0;slave_low=0;
        if((SERVICE_MODE==2 || SERVICE_MODE==4) && page_written) begin busy_polls=2;page_written=0;end
    end
    always @(posedge scl_i) if(!rst) begin
        case(mode)
            1:begin
                rx={rx[6:0],sda_i};
                if(bitno==7) begin
                    ack_ok=1;
                    if(stage==0) begin
                        device=rx[7:1];reading=rx[0];
                        ack_ok=device=='h50 || device=='h51;
                        if(device=='h50 && busy_polls>0) begin ack_ok=0;busy_polls=busy_polls-1;end
                    end
                    if(rx_bytes==nack_byte) ack_ok=0;
                    if(ack_ok && stage!=0) begin
                        if(device=='h51 && stage==1) pointer=rx;
                        else if(device=='h50 && stage==1) pointer=rx<<8;
                        else if(device=='h50 && stage==2) pointer=pointer|rx;
                        else begin
                            if(device=='h51) rtc[pointer&255]=rx;
                            else if(!wp) begin eeprom[pointer&8191]=rx;page_written=1;end
                            pointer=pointer+1;wr_bytes=wr_bytes+1;
                        end
                    end
                    stage=stage+1;rx_bytes=rx_bytes+1;mode=2;ack_risen=0;bitno=0;
                end else bitno=bitno+1;
            end
            2:ack_risen=1;
            3:begin
                if(bitno==7) begin rd_bytes=rd_bytes+1;mode=4;master_ack_seen=0;end
                else bitno=bitno+1;
            end
            4:begin
                ack_value=sda_i;master_ack_seen=1;
                if(sda_i) master_nacks=master_nacks+1;else master_acks=master_acks+1;
            end
        endcase
    end
    always @(negedge scl_i) if(!rst) begin
        case(mode)
            2:if(!ack_risen) slave_low=ack_ok;
            else begin
                slave_low=0;
                if(!ack_ok) mode=5;
                else if(reading && stage==1) begin
                    tx=(device==7'h51) ? rtc[pointer&255] : eeprom[pointer&8191];
                    pointer=pointer+1;mode=3;bitno=0;slave_low=!tx[7];
                end else begin mode=1;bitno=0;rx=0;end
            end
            3:slave_low=!tx[7-bitno];
            4:if(!master_ack_seen) slave_low=0;
            else if(ack_value) begin slave_low=0;mode=5;end
            else begin
                tx=(device==7'h51) ? rtc[pointer&255] : eeprom[pointer&8191];pointer=pointer+1;
                mode=3;bitno=0;slave_low=!tx[7];
            end
        endcase
    end
    task automatic request(input [6:0] dev,input integer addr_n,input integer addr,
        input integer writes,input integer reads,input [255:0] data,input integer expected_error);
        reg [257:0] held;
        begin
            @(negedge clk);req_device=dev;req_addr_bytes=addr_n;req_address=addr;
            req_wr_count=writes;req_rd_count=reads;req_wr_data=data;req_valid=1;
            @(posedge clk);while(!req_ready) @(posedge clk);
            @(negedge clk);req_valid=0;
            wait(rsp_valid);#1;
            if(rsp_error!=expected_error) $fatal(1,"FAIL: I2C error %0d expected %0d",rsp_error,expected_error);
            held={rsp_error,rsp_rd_data};
            repeat(13) begin
                @(negedge clk);
                if(!rsp_valid || {rsp_error,rsp_rd_data}!==held || req_ready)
                    $fatal(1,"FAIL: response not held during consumer stall");
            end
            if(scl_low || sda_low || scl_i!==1 || sda_i!==1)
                if(expected_error!=2) $fatal(1,"FAIL: bus not released after transaction");
            rsp_ready=1;@(negedge clk);rsp_ready=0;transactions=transactions+1;
        end
    endtask
    reg [255:0] data;
    integer before_starts,before_stops,before_nacks;
    integer refreshes=0,writes_verified=0;
    integer uart_bytes=0,uart_file;
    reg [7:0] uart_byte;
    initial if(SERVICE_MODE==3) begin
        uart_file=$fopen("persistence_inventory_trace.hex","w");
        wait(!rst);
        forever begin
            @(negedge probe_uart);#(8680+4340);
            for(integer bitnum=0;bitnum<8;bitnum=bitnum+1) begin uart_byte[bitnum]=probe_uart;#8680;end
            if(probe_uart!==1) $fatal(1,"FAIL: inventory UART stop");
            $fdisplay(uart_file,"%02x",uart_byte);uart_bytes=uart_bytes+1;
        end
    end
    integer idle_scl_edges=0;
    integer anchor_file=0,anchor_records=0,anchor_bytes=0;
    reg [31:0] anchor_random=32'hbc123456;
    always @(negedge clk) if(SERVICE_MODE==4) begin
        anchor_random=anchor_random^(anchor_random<<13);anchor_random=anchor_random^(anchor_random>>17);anchor_random=anchor_random^(anchor_random<<5);
        anchor_byte_ready=anchor_random[0] || anchor_random[3];
    end
    always @(posedge clk) if(SERVICE_MODE==4 && !rst && anchor_byte_valid && anchor_byte_ready) begin
        $fwrite(anchor_file,"%c",anchor_byte_data);anchor_bytes=anchor_bytes+1;
        if(anchor_byte_last) begin
            if(anchor_bytes!=132) $fatal(1,"FAIL: wire RTC RA boundary");
            anchor_records=anchor_records+1;anchor_bytes=0;
        end
    end
    always @(negedge scl_i) if(!rst && mode==0) idle_scl_edges=idle_scl_edges+1;
    initial begin
        for(i=0;i<256;i=i+1) rtc[i]=i^8'h96;
        for(i=0;i<8192;i=i+1) eeprom[i]=i^8'h69;
        repeat(5) @(negedge clk);rst=0;
        if(SERVICE_MODE==4) begin
            anchor_file=$fopen("rtc_anchor_wire_records.txt","w");
            rtc[0]=0;rtc[1]=0;rtc[2]=8'h56;rtc[3]=8'h34;rtc[4]=8'h12;rtc[5]=8'h20;rtc[6]=2;rtc[7]=8'h10;rtc[8]=8'h26;
            fork
                begin
                    repeat(4) begin
                        @(negedge clk);refresh_valid=1;@(posedge clk);while(!refresh_ready) @(posedge clk);
                        @(negedge clk);refresh_valid=0;
                        wait(anchor_records==refreshes+1);refreshes=refreshes+1;
                        if(!rtc_known || !rtc_fresh) $fatal(1,"FAIL: concurrent RTC wire anchor trust");
                    end
                end
                begin
                    for(j=0;j<6;j=j+1) begin
                        @(negedge clk);write_address=8000+j*32;write_count=32;
                        for(i=0;i<32;i=i+1) write_data[i*8 +: 8]=j*29+i;
                        write_valid=1;@(posedge clk);while(!write_ready) @(posedge clk);
                        @(negedge clk);write_valid=0;wait(page_result_valid);#1;
                        if(page_result_error) $fatal(1,"FAIL: concurrent anchor EEPROM verification");
                        for(i=0;i<32;i=i+1) if(eeprom[8000+j*32+i]!==8'(j*29+i)) $fatal(1,"FAIL: anchor EEPROM media oracle");
                        @(negedge clk);page_result_ready=1;@(negedge clk);page_result_ready=0;
                        writes_verified=writes_verified+1;
                    end
                end
            join
            if(a_grants!={32'd30,32'd8} || a_completed!=a_grants) $fatal(1,"FAIL: concurrent anchor arbiter accounting");
            // Invalid RTC calendar and I2C NACK remain visible RA failures, while
            // the EEPROM client's ownership stays separate.
            rtc[2]=8'hd6;
            @(negedge clk);refresh_valid=1;@(posedge clk);while(!refresh_ready) @(posedge clk);
            @(negedge clk);refresh_valid=0;wait(anchor_records==5);
            if(rtc_known || rtc_fresh) $fatal(1,"FAIL: wire VL anchor falsely trusted");
            rtc[2]=8'h56;nack_byte=0;
            @(negedge clk);refresh_valid=1;@(posedge clk);while(!refresh_ready) @(posedge clk);
            @(negedge clk);refresh_valid=0;wait(anchor_records==6);
            if(rtc_known || rtc_fresh) $fatal(1,"FAIL: wire I2C anchor falsely trusted");
            $fclose(anchor_file);
            $display("PASS: rtc_anchor_wire fairOwner+oneMaster+pinOnlyDualSlave concurrent4RA/6pages/VL+I2CfailedRA/randomStream START=%0d STOP=%0d",starts,stops);$finish;
        end
        if(SERVICE_MODE==3) begin
            wait(probe_done);repeat(20) @(negedge clk);$fclose(uart_file);
            if(wr_bytes!=0 || uart_bytes!=284 || starts!=18 || stops!=9)
                $fatal(1,"FAIL: read-only inventory W/UART/START/STOP %0d/%0d/%0d/%0d",wr_bytes,uart_bytes,starts,stops);
            for(i=0;i<8192;i=i+1) if(eeprom[i]!==8'(i^'h69)) $fatal(1,"FAIL: inventory changed EEPROM");
            $display("PASS: persistence_inventory 284 realUART bytes/9readTransactions/noDeviceWrites/mediaUnchanged");$finish;
        end
        if(SERVICE_MODE==2) begin
            rtc[0]=0;rtc[1]=0;rtc[2]=8'h56;rtc[3]=8'h34;rtc[4]=8'h12;rtc[5]=8'h19;rtc[6]=1;rtc[7]=8'h10;rtc[8]=8'h26;
            fork
                begin
                    repeat(10) begin
                        @(negedge clk);refresh_valid=1;@(posedge clk);while(!refresh_ready) @(posedge clk);
                        @(negedge clk);refresh_valid=0;
                        wait(rtc_result_valid);#1;
                        if(rtc_result_error || !rtc_known || !rtc_fresh || rtc_year!=2026 || rtc_second!=56)
                            $fatal(1,"FAIL: concurrent RTC response ownership/calendar");
                        repeat(5) @(negedge clk);rtc_result_ready=1;@(negedge clk);rtc_result_ready=0;
                        refreshes=refreshes+1;
                    end
                end
                begin
                    for(j=0;j<6;j=j+1) begin
                        @(negedge clk);write_address=8000+j*32;write_count=32;
                        for(i=0;i<32;i=i+1) write_data[i*8 +: 8]=j*29+i;
                        write_valid=1;@(posedge clk);while(!write_ready) @(posedge clk);
                        @(negedge clk);write_valid=0;
                        wait(page_result_valid);#1;
                        if(page_result_error) $fatal(1,"FAIL: concurrent EEPROM page/error routing");
                        for(i=0;i<32;i=i+1) if(eeprom[8000+j*32+i]!==8'(j*29+i))
                            $fatal(1,"FAIL: concurrent EEPROM pixels mismatch");
                        repeat(7) @(negedge clk);page_result_ready=1;@(negedge clk);page_result_ready=0;
                        writes_verified=writes_verified+1;
                    end
                end
            join
            repeat(10) @(negedge clk);
            if(a_grants!={32'd30,32'd20} || a_completed!=a_grants)
                $fatal(1,"FAIL: concurrent bus accounting %h/%h",a_grants,a_completed);
            $display("PASS: persistence_fair_services concurrentRTC=%0d verifiedPages=%0d transactions=50 busyNACKs=12 START=%0d STOP=%0d",refreshes,writes_verified,starts,stops);$finish;
        end
        if(SERVICE_MODE) begin
            rtc[0]=0;rtc[1]=0;rtc[2]=8'h56;rtc[3]=8'h34;rtc[4]=8'h12;rtc[5]=8'h19;rtc[6]=1;rtc[7]=8'h10;rtc[8]=8'h26;
            @(negedge clk);refresh_valid=1;@(negedge clk);refresh_valid=0;
            wait(rtc_result_valid);#1;
            if(rtc_result_error || !rtc_known || !rtc_fresh || rtc_year!=2026 || rtc_month!=10 || rtc_day!=19 || rtc_second!=56)
                $fatal(1,"FAIL: real RTC reader/bus/pin slave composition");
            repeat(10) @(negedge clk);rtc_result_ready=1;@(negedge clk);rtc_result_ready=0;
            select_eeprom=1;write_address=8160;write_count=32;
            for(i=0;i<32;i=i+1) write_data[i*8 +: 8]=i*7+3;
            @(negedge clk);write_valid=1;@(negedge clk);write_valid=0;
            wait(page_result_valid);#1;
            if(page_result_error) $fatal(1,"FAIL: real page writer/bus/pin slave verify");
            for(i=0;i<32;i=i+1) if(eeprom[8160+i]!==write_data[i*8 +: 8]) $fatal(1,"FAIL: pin EEPROM page bytes");
            repeat(10) @(negedge clk);page_result_ready=1;@(negedge clk);page_result_ready=0;
            wp=1;write_data=~write_data;
            @(negedge clk);write_valid=1;@(negedge clk);write_valid=0;
            wait(page_result_valid);#1;
            if(page_result_error!=4) $fatal(1,"FAIL: actual pin WP ACK should fail readback");
            page_result_ready=1;@(negedge clk);page_result_ready=0;select_eeprom=0;
            rtc[2]=8'hd6;
            @(negedge clk);refresh_valid=1;@(negedge clk);refresh_valid=0;
            wait(rtc_result_valid);#1;
            if(rtc_known || rtc_fresh || rtc_result_error!=2) $fatal(1,"FAIL: actual pin RTC VL not invalidated");
            $display("PASS: persistence_services RTC+page-writer+one-I2C-master+wire-only-two-device-slave/readback-WP/VL starts=%0d stops=%0d",starts,stops);$finish;
        end
        // RTC burst read must be 2 STARTs/1 STOP and NACK only final byte.
        before_starts=starts;before_stops=stops;before_nacks=master_nacks;
        request('h51,1,2,0,7,0,0);
        for(i=0;i<7;i=i+1) if(rsp_rd_data[i*8 +: 8]!==8'((i+2)^'h96)) $fatal(1,"FAIL: RTC read byte %0d",i);
        if(starts-before_starts!=2 || stops-before_stops!=1 || master_nacks-before_nacks!=1 || master_acks!=6)
            $fatal(1,"FAIL: RTC repeatedSTART/last NACK");
        if(idle_scl_edges) $fatal(1,"FAIL: initial START generated spurious SCL before SDA START");
        // Full EEPROM page and random-address readback.
        for(i=0;i<32;i=i+1) data[i*8 +: 8]=8'(i*13+1);
        request('h50,2,'h1fe0,32,0,data,0);
        request('h50,2,'h1fe0,0,32,0,0);
        if(rsp_rd_data!==data) $fatal(1,"FAIL: EEPROM 16bit address/page bytes");
        for(i=0;i<32;i=i+1) if(eeprom['h1fe0+i]!==data[i*8 +: 8]) $fatal(1,"FAIL: EEPROM wire write");
        // Busy NACK polling is explicit, not false success. No address/data sent.
        busy_polls=2;
        request('h50,0,0,0,0,0,1);request('h50,0,0,0,0,0,1);request('h50,0,0,0,0,0,0);
        request('h52,1,0,0,1,0,1);
        // NACK every write phase including address/pointer/data: STOP exactly once.
        for(j=0;j<4;j=j+1) begin
            nack_byte=j;before_stops=stops;
            request('h50,2,32,1,0,256'hf3,1);
            if(stops-before_stops!=1) $fatal(1,"FAIL: NACK cleanup stop");
        end
        nack_byte=-1;
        // Invalid length/write+read rejected without touching pins.
        before_starts=starts;request('h51,1,0,33,0,0,3);request('h51,1,0,1,1,0,3);
        if(starts!=before_starts) $fatal(1,"FAIL: illegal request touched bus");
        // Stretch a real clock in mid-byte, then release before timeout.
        fork
            request('h51,1,2,0,1,0,0);
            begin wait(scl_low);@(negedge clk);stretch_low=1;repeat(35) @(negedge clk);stretch_low=0;end
        join
        // Stuck SCL and SDA must terminate with line timeout and release pins.
        stretch_low=1;request('h51,1,0,0,1,0,2);stretch_low=0;
        repeat(8) @(negedge clk);mode=0;slave_low=0;
        stuck_sda=1;request('h51,1,0,0,1,0,2);stuck_sda=0;
        repeat(8) @(negedge clk);mode=0;slave_low=0;
        request('h51,1,2,0,1,0,0);
        // Reset mid-transaction releases open drain without a fabricated success.
        @(negedge clk);req_valid=1;req_rd_count=7;req_device='h51;
        @(posedge clk);while(!req_ready) @(posedge clk);
        @(negedge clk);req_valid=0;wait(sda_low);@(negedge clk);rst=1;
        repeat(5) @(negedge clk);
        if(scl_low || sda_low || rsp_valid) $fatal(1,"FAIL: reset pin release");
        mode=0;slave_low=0;rst=0;repeat(6) @(negedge clk);
        request('h51,1,2,0,1,0,0);
        $display("PASS: i2c_register_master transactions=%0d wireSTART=%0d STOP=%0d writebytes=%0d readbytes=%0d NACK/timeout/stretch/reset/response-stall",transactions,starts,stops,wr_bytes,rd_bytes);
        $finish;
    end
    initial begin #40000000;$fatal(1,"FAIL: I2C wire timeout mode=%0d byte_state=%0d anchorRecords=%0d refreshes=%0d writes=%0d grants=%h ready=%b valid=%b pending=%b",mode,dut.bytes.state,anchor_records,refreshes,writes_verified,a_grants,refresh_ready,refresh_valid,c_valid);end
endmodule
