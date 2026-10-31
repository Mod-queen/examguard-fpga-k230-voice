`timescale 1ns/1ps
// Full service -> actual I2C master -> pin-only EEPROM oracle, retained on reset.
module persistent_boot_service_tb #(parameter SHARED_RTC=0);
    reg clk=0,rst=1;
    always #10 clk=~clk;
    tri1 scl,sda;
    wire scl_low,sda_low,admission,done,active_slot;
    wire [3:0] error;
    wire [31:0] boot_id,generation;
    reg [31:0] expected_device=1;
    // Main-top glue: actual service publication drives identity/context/queue.
    reg transport_rst=1;
    reg [2:0] stage_id=1;
    reg [3:0] event_attempts=0;
    wire session_start,session_end,session_active,request_rst,request_enable;
    wire [31:0] event_device,event_boot,event_session;
    wire [63:0] event_time;
    persistent_event_identity identity(.clk(clk),.system_rst(rst),.transport_rst(transport_rst),.ms_tick(1'b1),
        .session_start(session_start),.session_end(session_end),.device_straps(32'd1),.persistent_boot(boot_id),
        .boot_admission(admission),.device_id(event_device),.boot_id(event_boot),.session_id(event_session),
        .time_ms(event_time),.session_active(session_active),.request_rst(request_rst),.request_enable(request_enable));
    wire [3:0] aligned_request;
    wire [63:0] aligned_time,aligned_data;
    wire [31:0] aligned_device,aligned_boot,aligned_session;
    exam_event_context context_inst(.clk(clk),.rst(rst),.stage(stage_id),.request(event_attempts & {4{request_enable}}),
        .request_data(64'h3640365036603670),.device_id(event_device),.boot_id(event_boot),.session_id(event_session),
        .session_active(session_active),.time_ms(event_time),.session_start(session_start),.session_end(session_end),
        .aligned_request(aligned_request),.aligned_data(aligned_data),.aligned_time_ms(aligned_time),
        .aligned_device(aligned_device),.aligned_boot(aligned_boot),.aligned_session(aligned_session));
    wire transaction_valid;
    reg transaction_ready=0;
    wire [255:0] transaction_data;
    event_transaction_queue #(.DEPTH(8),.SEPARATE_ID_RESET(1)) event_queue(
        .clk(clk),.rst(request_rst),.id_rst(rst),.request(aligned_request & {4{request_enable}}),.request_data(aligned_data),
        .device_id(aligned_device),.boot_id(aligned_boot),.session_id(aligned_session),.request_time_ms(aligned_time),
        .accepted(),.rejected(),.event_valid(transaction_valid),.event_ready(transaction_ready),.event_data(transaction_data),
        .occupancy(),.high_water(),.accepted_count(),.rejected_count(),.delivered_count(),.id_exhausted());
    task automatic send_event;
        begin @(negedge clk);event_attempts=1;@(negedge clk);event_attempts=0;repeat(4) @(negedge clk);end
    endtask
    task automatic check_event(input integer expected_boot,input integer expected_uid);
        begin
            wait(transaction_valid);#1;
            if(transaction_data[255:224]!=1 || transaction_data[223:192]!=expected_boot ||
                transaction_data[191:160]!=1 || transaction_data[159:96]!=expected_uid || transaction_data[7:0]!=8'h70)
                $fatal(1,"FAIL: integrated persistent identity/context/queue %h",transaction_data);
            @(negedge clk);transaction_ready=1;@(negedge clk);transaction_ready=0;
        end
    endtask
    reg slave_low=0,wp=0;
    assign scl=scl_low?1'b0:1'bz;
    assign sda=(sda_low || slave_low)?1'b0:1'bz;
    wire ra_valid,ra_last,rtc_known,rtc_fresh;
    wire [7:0] ra_data;
    reg ra_ready=1,rtc_nack=0;
    integer ra_records=0;
    always @(posedge clk) if(SHARED_RTC && !rst && ra_valid && ra_ready && ra_last) ra_records=ra_records+1;
    generate if(SHARED_RTC) begin: shared
        persistent_rtc_service #(.STARTUP_CYCLES(20),.QUARTER_CYCLES(4),.TIMEOUT_CYCLES(120),.MAX_POLLS(4),
            .REFRESH_CYCLES(200),.RTC_MAX_READ_CYCLES(1000000)) dut(
            .clk(clk),.rst(rst),.expected_device(expected_device),.monotonic_ms(event_time),.scl_i(scl),.sda_i(sda),
            .scl_low(scl_low),.sda_low(sda_low),.admission(admission),.done(done),.error(error),
            .boot_id(boot_id),.generation(generation),.active_slot(active_slot),
            .rtc_known(rtc_known),.rtc_fresh(rtc_fresh),.rtc_age_cycles(),
            .byte_valid(ra_valid),.byte_last(ra_last),.byte_data(ra_data),.byte_ready(ra_ready));
    end else begin: boot_only
    persistent_boot_service #(.STARTUP_CYCLES(20),.QUARTER_CYCLES(4),.TIMEOUT_CYCLES(120),.MAX_POLLS(4)) dut(
        .clk(clk),.rst(rst),.expected_device(expected_device),.scl_i(scl),.sda_i(sda),
        .scl_low(scl_low),.sda_low(sda_low),.admission(admission),.done(done),.error(error),
        .boot_id(boot_id),.generation(generation),.active_slot(active_slot));
    end endgenerate
    reg [7:0] rtc_media[0:255];
    reg [7:0] media[0:8191],saved[0:127];
    integer mode=0,bitno=0,stage=0,device=0,pointer=0;
    integer starts=0,stops=0,wr_bytes=0,busy_polls=0,busy_nacks=0;
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
                    device=rx[7:1];reading=rx[0];ack_ok=device=='h50 || (SHARED_RTC && device=='h51 && !rtc_nack);
                    if(device=='h50 && busy_polls>0) begin ack_ok=0;busy_polls=busy_polls-1;busy_nacks=busy_nacks+1;end
                end
                if(ack_ok && stage!=0) begin
                    if(stage==1 && device=='h51) pointer=rx;
                    else if(stage==1) pointer=rx<<8;
                    else if(stage==2) pointer=pointer|rx;
                    else begin
                        if(device!='h50 || pointer<'h1e00 || pointer>='h1f00 || (pointer&127)>=96)
                            $fatal(1,"FAIL: service write outside record used region");
                        if(!wp) begin media[pointer]=rx;page_written=1;end
                        pointer=pointer+1;wr_bytes=wr_bytes+1;
                    end
                end
                stage=stage+1;mode=2;ack_risen=0;bitno=0;
            end else bitno=bitno+1;
        end
        2:ack_risen=1;
        3:if(bitno==7) begin mode=4;master_ack_seen=0;end else bitno=bitno+1;
        4:begin ack_value=sda;master_ack_seen=1;end
    endcase
    always @(negedge scl) if(!rst) case(mode)
        2:if(!ack_risen) slave_low=ack_ok;
            else begin
                slave_low=0;
                if(!ack_ok) mode=5;
                else if(reading && stage==1) begin
                    tx=(device=='h51) ? rtc_media[pointer&255] : media[pointer];pointer=pointer+1;mode=3;bitno=0;slave_low=!tx[7];
                end else begin mode=1;bitno=0;rx=0;end
            end
        3:slave_low=!tx[7-bitno];
        4:if(!master_ack_seen) slave_low=0;
            else if(ack_value) begin slave_low=0;mode=5;end
            else begin tx=(device=='h51) ? rtc_media[pointer&255] : media[pointer];pointer=pointer+1;mode=3;bitno=0;slave_low=!tx[7];end
    endcase
    function automatic [31:0] crc(input integer address,input integer count);
        reg [31:0] c;integer j,k;
        begin
            c=32'hffffffff;
            for(j=0;j<count;j=j+1) begin
                c=c^media[address+j];
                for(k=0;k<8;k=k+1) c=c[0]?(c>>1)^32'hedb88320:c>>1;
            end
            crc=~c;
        end
    endfunction
    task automatic seed(input integer slot,input [31:0] gen,input [31:0] boot);
        integer a,j;reg [31:0] c;
        begin
            a='h1e00+slot*128;
            for(j=0;j<96;j=j+1) media[a+j]=0;
            media[a]=8'h45;media[a+1]=8'h47;media[a+2]=8'h43;media[a+3]=8'h46;
            media[a+4]=1;media[a+5]=64;media[a+8]=1;
            for(j=0;j<4;j=j+1) begin media[a+12+j]=gen[j*8 +: 8];media[a+16+j]=boot[j*8 +: 8];end
            c=crc(a,60);
            for(j=0;j<4;j=j+1) media[a+60+j]=c[j*8 +: 8];
            media[a+64]=8'h45;media[a+65]=8'h47;media[a+66]=8'h43;media[a+67]=8'h4d;
            for(j=0;j<4;j=j+1) begin
                media[a+68+j]=gen[j*8 +: 8];media[a+72+j]=~gen[j*8 +: 8];media[a+76+j]=c[j*8 +: 8];
            end
            c=crc(a+64,28);for(j=0;j<4;j=j+1) media[a+92+j]=c[j*8 +: 8];
        end
    endtask
    task automatic reset_service;
        begin
            @(negedge clk);rst=1;transport_rst=1;stage_id=1;event_attempts=0;slave_low=0;mode=0;busy_polls=0;page_written=0;
            repeat(8) @(negedge clk);
            if(admission || done) $fatal(1,"FAIL: boot service reset publication");
            rst=0;transport_rst=0;
        end
    endtask
    task automatic check_result(input integer err,input integer boot);
        integer before_starts;
        begin
            wait(done);#1;
            if(error!=err || admission!=(err==0) || (err==0 && (boot_id!=boot || generation!=boot)))
                $fatal(1,"FAIL: service result error/boot/gen %0d/%0d/%0d",error,boot_id,generation);
            before_starts=starts;repeat(2000) @(negedge clk);
            if((!SHARED_RTC || err!=0) && starts!=before_starts) $fatal(1,"FAIL: service automatically retried");
        end
    endtask
    integer i,before_writes;
    reg [63:0] saved_time;
    initial begin
        for(i=0;i<8192;i=i+1) media[i]=8'hff;
        for(i=0;i<256;i=i+1) rtc_media[i]=0;
        rtc_media[2]='h56;rtc_media[3]='h34;rtc_media[4]='h12;rtc_media[5]='h20;rtc_media[6]=2;rtc_media[7]='h10;rtc_media[8]='h26;
        seed(0,3,3);seed(1,4,4);
        for(i=0;i<128;i=i+1) saved[i]=media['h1e80+i];
        reset_service;
        send_event;if(transaction_valid || request_enable) $fatal(1,"FAIL: service pending admitted transaction");
        check_result(0,5);wait(request_enable);
        stage_id=3;repeat(4) @(negedge clk);send_event;check_event(5,1);
        send_event; // accepted UID2 is deliberately cancelled before consumption
        if(!transaction_valid) $fatal(1,"FAIL: cancellation pending queue not covered");
        saved_time=event_time;before_writes=wr_bytes;
        transport_rst=1;repeat(5) @(negedge clk);transport_rst=0;wait(request_enable);
        if(transaction_valid || event_time<=saved_time || boot_id!=5 || event_session!=1 || wr_bytes!=before_writes)
            $fatal(1,"FAIL: local cancellation reset identity or EEPROM");
        send_event;check_event(5,3);
        if(active_slot!=0 || wr_bytes!=128) $fatal(1,"FAIL: boot5 target/write count");
        for(i=0;i<128;i=i+1) if(media['h1e80+i]!==saved[i]) $fatal(1,"FAIL: boot4 oldslot altered");
        if(SHARED_RTC) begin
            wait(ra_records>=2);if(!rtc_known || !rtc_fresh) $fatal(1,"FAIL: shared RTC after boot not trusted");
            before_writes=wr_bytes;rtc_nack=1;
            wait(!rtc_known);repeat(1000) @(negedge clk);
            if(!admission || boot_id!=5 || wr_bytes!=before_writes || !request_enable)
                $fatal(1,"FAIL: RTC failure revoked boot/admission or rewrote EEPROM");
            rtc_nack=0;wait(rtc_known);
            ra_ready=0;repeat(10000) @(negedge clk);
            if(!admission || wr_bytes!=before_writes) $fatal(1,"FAIL: blocked RA caused boot rewrite");
            ra_ready=1;
        end
        reset_service;check_result(0,6);wait(request_enable);
        stage_id=3;repeat(4) @(negedge clk);send_event;check_event(6,1);
        if(active_slot!=1 || wr_bytes!=256) $fatal(1,"FAIL: boot6 target/write count");
        wp=1;reset_service;check_result(9,0);wp=0;
        before_writes=wr_bytes;expected_device=2;reset_service;check_result(4,0);expected_device=1;
        if(wr_bytes!=before_writes) $fatal(1,"FAIL: wrong device wrote");
        media['h1e00]=0;media['h1e80]=0;reset_service;check_result(3,0);
        if(wr_bytes!=before_writes) $fatal(1,"FAIL: corrupt media wrote");
        for(i='h1e00;i<'h1f00;i=i+1) media[i]=8'hff;
        reset_service;check_result(2,0);
        if(wr_bytes!=before_writes) $fatal(1,"FAIL: blank media formatted");
        seed(0,32'hffffffff,32'hffffffff);reset_service;check_result(6,0);
        if(wr_bytes!=before_writes) $fatal(1,"FAIL: exhausted media wrote");
        $display("PASS: persistent_boot_service sharedRTC=%0d actualPins+identity+context+queue boot5UID1/cancelUID2/boot5UID3/newBoot6UID1/WP/wrongDevice/corrupt/blank/MAX/noRetry oldslotPreserved START=%0d STOP=%0d busyNACK=%0d",SHARED_RTC,starts,stops,busy_nacks);$finish;
    end
    initial begin #100000000;$fatal(1,"FAIL: persistent boot service timeout");end
endmodule
