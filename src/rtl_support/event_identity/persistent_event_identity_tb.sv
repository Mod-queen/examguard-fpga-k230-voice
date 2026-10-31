`timescale 1ns/1ps
module persistent_event_identity_tb;
    reg clk=0,system_rst=1,transport_rst=1,ms_tick=1,session_start=0,session_end=0,boot_admission=0;
    reg [31:0] persistent_boot=0;
    always #10 clk=~clk;
    wire [31:0] device_id,boot_id,session_id;
    wire [63:0] time_ms;wire session_active,request_rst,request_enable;
    persistent_event_identity identity(.device_straps(32'd1),.*);
    reg [3:0] attempts=0;
    wire [3:0] accepted,rejected;
    wire event_valid,id_exhausted;
    wire event_ready=1;
    wire [255:0] event_data;
    wire [3:0] request=attempts & {4{request_enable}};
    event_transaction_queue #(.DEPTH(8),.ID_WIDTH(3),.SEPARATE_ID_RESET(1)) queue(
        .clk(clk),.rst(request_rst),.id_rst(system_rst),.request(request),.request_data(64'h3640365036603670),
        .device_id(device_id),.boot_id(boot_id),.session_id(session_id),.request_time_ms(time_ms),
        .accepted(accepted),.rejected(rejected),.event_valid(event_valid),.event_ready(event_ready),.event_data(event_data),
        .occupancy(),.high_water(),.accepted_count(),.rejected_count(),.delivered_count(),.id_exhausted(id_exhausted));
    integer delivered=0,last_uid=0;
    always @(posedge clk) if(event_valid && event_ready) begin
        if(event_data[255:224]!=1 || event_data[223:192]!=persistent_boot || event_data[159:96]!=last_uid+1)
            $fatal(1,"FAIL: persistent transaction duplicate/wrong boot: %h",event_data);
        last_uid=event_data[159:96];delivered=delivered+1;
    end
    task automatic send(input [3:0] lanes);
        begin @(negedge clk);attempts=lanes;@(negedge clk);attempts=0;repeat(8) @(negedge clk);end
    endtask
    task automatic cancel;
        reg [63:0] old_time;
        begin
            old_time=time_ms;
            // async cancellation survives stopped/short pulses as at top.
            #2;transport_rst=1;#2;
            if(!request_rst || request_enable) $fatal(1,"FAIL: asynchronous source closure");
            repeat(5) @(negedge clk);transport_rst=0;
            // Keep attempts asserted through release; first open edge is guarded.
            wait(!request_rst);#1;
            if(request_enable) $fatal(1,"FAIL: release edge admitted request");
            wait(request_enable);repeat(2) @(negedge clk);
            if(boot_id!=persistent_boot || session_id!=1 || !session_active || time_ms<=old_time)
                $fatal(1,"FAIL: transport altered boot/session/time");
        end
    endtask
    initial begin
        repeat(5) @(negedge clk);system_rst=0;transport_rst=0;
        send(15);if(delivered || request_enable || boot_id) $fatal(1,"FAIL: admitted before EEPROM verify");
        session_start=1;@(negedge clk);session_start=0;
        repeat(5) @(negedge clk);
        persistent_boot=5;boot_admission=1;wait(request_enable);send(15);
        if(delivered!=4 || last_uid!=4) $fatal(1,"FAIL: first four lanes");
        cancel;send(3);
        if(delivered!=6 || last_uid!=6) $fatal(1,"FAIL: UID reset by transport");
        cancel;send(1);
        if(last_uid!=7 || !id_exhausted) $fatal(1,"FAIL: final usable UID");
        cancel;send(15);
        if(last_uid!=7 || !id_exhausted) $fatal(1,"FAIL: transport unlocked exhausted UID");
        @(negedge clk);system_rst=1;transport_rst=1;boot_admission=0;persistent_boot=0;
        repeat(6) @(negedge clk);last_uid=0;system_rst=0;transport_rst=0;
        send(15);if(last_uid) $fatal(1,"FAIL: system reset old boot admission");
        persistent_boot=6;boot_admission=1;wait(request_enable);send(1);
        if(last_uid!=1 || boot_id!=6 || session_id!=0) $fatal(1,"FAIL: new boot UID1");
        $display("PASS: persistent_event_identity pending/asyncCancel/sessionTimePreserved/UID1to7/noReuseAfter3Cancels/MAX/newBootUID1");$finish;
    end
    initial begin #1000000;$fatal(1,"FAIL: persistent identity timeout");end
endmodule
