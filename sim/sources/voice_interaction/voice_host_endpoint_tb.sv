`timescale 1ns/1ps
module voice_host_endpoint_tb;
    reg clk=0,rst=1;always #10 clk=~clk;
    reg rx_valid=0;reg [7:0] rx_data=0;
    reg [31:0] device_id=1,boot_id=42,round_id=9,seat_id=1;
    reg [63:0] info_tag=5;
    reg [2:0] exam_stage=2;
    reg help_pending=1;reg [31:0] help_ticket=1;
    wire presented,handled_pulse;
    wire heartbeat_pulse,configure_pulse;
    wire [63:0] configured_tag;
    wire display_loaded;
    wire [127:0] display_text;
    wire [31:0] display_token;
    wire [31:0] presented_round,handled_round,handled_ticket,command_token,rejected_lines;
    wire [63:0] presented_tag,handled_tag;
    wire [7:0] command_op,command_result;
    reg status_valid=0,byte_ready=0;
    wire status_ready,byte_valid,byte_last;
    wire [7:0] byte_data;
    reg [735:0] payload;
    reg [511:0] commands[0:9];
    integer handled_count=0,heartbeat_count=0,configure_count=0,file_handle,bytes=0,i,k;
    reg [511:0] extended_command;
    reg [31:0] extended_crc;
    function [31:0] crc_byte;
        input [31:0] old;input [7:0] b;
        reg [31:0] c;integer n;
        begin c=old^b;for(n=0;n<8;n=n+1)c=c[0]?(c>>1)^32'hedb88320:c>>1;crc_byte=c;end
    endfunction
    reg [7:0] held_byte;
    voice_host_endpoint dut(.*);
    voice_status_record record(.*);
    always @(posedge clk) if(!rst && handled_pulse) begin
        if(handled_round!=9 || handled_tag!=5 || handled_ticket!=1) $fatal(1,"handler misbound");
        handled_count=handled_count+1;
    end
    always @(posedge clk) if(!rst) begin
        if(heartbeat_pulse) heartbeat_count=heartbeat_count+1;
        if(configure_pulse) configure_count=configure_count+1;
    end
    always @(posedge clk) if(byte_valid && byte_ready) begin
        $fwrite(file_handle,"%c",byte_data);bytes=bytes+1;
        if(byte_last && bytes!=196) $fatal(1,"wrong VI boundary");
    end
    task send_byte;
        input [7:0] b;
        begin @(negedge clk);rx_valid=1;rx_data=b;@(negedge clk);rx_valid=0;end
    endtask
    task send_command;
        input [511:0] data;
        reg [3:0] nibble;
        begin
            send_byte("V");send_byte("C");send_byte(",");
            for(k=0;k<128;k=k+1) begin
                nibble=data[511-k*4 -:4];send_byte(nibble<10?"0"+nibble:"A"+nibble-10);
            end
            send_byte(10);@(negedge clk);
        end
    endtask
    initial begin
        $readmemh("commands.hex",commands);
        file_handle=$fopen("voice_status_trace.txt","w");
        repeat(5) @(negedge clk);rst=0;repeat(3) @(negedge clk);
        for(i=0;i<10;i=i+1) begin
            send_command(commands[i]);
            case(i)
                0,1:if(!presented || presented_round!=9 || presented_tag!=5 || command_result!=1)
                    $fatal(1,"presentation not bound");
                2,3:if(handled_count!=1 || command_result!=1) $fatal(1,"duplicate handling repeated");
                4:if(command_result!=3) $fatal(1,"token conflict accepted");
                5:if(command_result!=4) $fatal(1,"stale token accepted");
                6:if(command_result!=2) $fatal(1,"wrong revision accepted");
                7:if(command_result!=1 || handled_count!=2) $fatal(1,"new exact handler rejected");
                8,9:if(command_token!=4 || rejected_lines!=i-7) $fatal(1,"invalid frame not dropped");
            endcase
        end
        payload={64'h5649010000601302,32'd1,32'd42,32'd0,32'd1,32'd9,64'd5,
                 32'd1,32'd1,64'd1234,8'd1,8'd5,8'd4,8'd0,32'd4,8'd2,8'd1,240'd0};
        @(negedge clk);status_valid=1;@(negedge clk);status_valid=0;payload=0;
        wait(byte_valid);
        while(bytes<196) begin
            @(negedge clk);byte_ready=0;held_byte=byte_data;
            repeat(2) begin @(negedge clk);if(byte_data!==held_byte) $fatal(1,"held byte changed");end
            byte_ready=1;@(negedge clk);
        end
        byte_ready=0;
        $fclose(file_handle);
        if(!status_ready) $fatal(1,"record did not finish");
        // Heartbeat has a separate highwater and never overwrites the held
        // teacher acknowledgement. Same heartbeat replay must not refresh.
        extended_command=commands[0];extended_command[487:480]=4;
        extended_command[447:416]=32'd100;
        extended_crc=32'hffffffff;
        for(i=0;i<60;i=i+1) extended_crc=crc_byte(extended_crc,extended_command[511-i*8 -:8]);
        extended_command[31:0]=~extended_crc;
        send_command(extended_command);send_command(extended_command);
        if(heartbeat_count!=1 || command_token!=4 || command_op!=2 || command_result!=1)
            $fatal(1,"heartbeat replay or teacher feedback overwritten");
        extended_command[487:480]=3;extended_command[447:416]=5;
        extended_command[319:256]=64'h1234;
        extended_crc=32'hffffffff;
        for(i=0;i<60;i=i+1) extended_crc=crc_byte(extended_crc,extended_command[511-i*8 -:8]);
        extended_command[31:0]=~extended_crc;
        help_pending=0;send_command(extended_command);send_command(extended_command);
        if(configure_count!=1 || configured_tag!=64'h1234 || presented || command_result!=1)
            $fatal(1,"configuration/replay not explicit");
        extended_command[487:480]=5;extended_command[447:416]=6;
        extended_command[319:256]=info_tag;
        extended_command[191:64]=128'h85868720202036303234323032323538;
        extended_crc=32'hffffffff;
        for(i=0;i<60;i=i+1) extended_crc=crc_byte(extended_crc,extended_command[511-i*8 -:8]);
        extended_command[31:0]=~extended_crc;send_command(extended_command);
        if(!display_loaded || display_token!=6 || display_text!==128'h85868720202036303234323032323538)
            $fatal(1,"display payload endian/identity");
        info_tag=6;@(negedge clk);
        if(presented || display_loaded) $fatal(1,"presentation/text survived revision");
        $display("PASS: voice_host_endpoint commands=10 handled=2 bytes=196");$finish;
    end
    initial begin #1000000;$fatal(1,"test timeout");end
endmodule
