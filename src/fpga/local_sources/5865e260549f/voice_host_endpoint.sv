`timescale 1ns/1ps
// VC64 byte-stream endpoint, no UART instance. Presentation/handling never writes
// EEPROM or touches exam timing. Exactly bound duplicate tokens replay feedback.
module voice_host_endpoint (
    input wire clk,rst,
    input wire rx_valid,input wire [7:0] rx_data,
    input wire [31:0] device_id,boot_id,round_id,seat_id,
    input wire [63:0] info_tag,
    input wire [2:0] exam_stage,
    input wire help_pending,input wire [31:0] help_ticket,
    output reg presented,
    output reg [31:0] presented_round,
    output reg [63:0] presented_tag,
    output reg handled_pulse,
    output reg [31:0] handled_round,handled_ticket,
    output reg [63:0] handled_tag,
    output reg [31:0] command_token,
    output reg [7:0] command_op,command_result,
    output reg [31:0] rejected_lines
    ,output reg heartbeat_pulse,configure_pulse
    ,output reg [63:0] configured_tag
    ,output reg display_loaded
    ,output reg [127:0] display_text
    ,output reg [31:0] display_token
);
    reg [2:0] phase;
    reg [7:0] index;
    reg [511:0] buffer_data,last_command;
    reg [31:0] crc,last_token;
    reg [31:0] heartbeat_token;
    reg [7:0] last_result;
    reg [3:0] high_nibble;
    reg [31:0] bound_round,bound_boot;
    reg [63:0] bound_tag;
    wire hex_valid=(rx_data>="0" && rx_data<="9") || (rx_data>="A" && rx_data<="F") || (rx_data>="a" && rx_data<="f");
    wire [3:0] nibble=rx_data<="9" ? rx_data-"0" : rx_data<="F" ? rx_data-"A"+10 : rx_data-"a"+10;
    wire [7:0] operation=buffer_data[487:480];
    wire [31:0] token=buffer_data[447:416];
    wire binding_ok=buffer_data[415:384]==device_id && buffer_data[383:352]==boot_id &&
                    buffer_data[351:320]==round_id && (operation==3 || buffer_data[319:256]==info_tag) &&
                    buffer_data[223:192]==seat_id;
    wire valid_fields=buffer_data[511:488]==24'h564301 && buffer_data[479:448]==32'h00400000 &&
                      buffer_data[63:32]==0 && (operation==5 || buffer_data[191:64]==0) &&
                      token!=0 && operation>=1 && operation<=5 &&
                      buffer_data[319:256]!=0 &&
                      (operation!=2 ? buffer_data[255:224]==0 : buffer_data[255:224]!=0);
    function automatic [31:0] crc_byte(input [31:0] old,input [7:0] b);
        reg [31:0] c;integer k;
        begin c=old^{24'd0,b};for(k=0;k<8;k=k+1) c=c[0]?(c>>1)^32'hedb88320:c>>1;crc_byte=c;end
    endfunction
    always @(posedge clk) begin
        if(rst) begin
            phase<=0;index<=0;buffer_data<=0;last_command<=0;crc<=32'hffffffff;
            last_token<=0;heartbeat_token<=0;last_result<=0;high_nibble<=0;
            bound_round<=0;bound_tag<=0;bound_boot<=0;
            presented<=0;presented_round<=0;presented_tag<=0;
            handled_pulse<=0;handled_round<=0;handled_tag<=0;handled_ticket<=0;
            command_token<=0;command_op<=0;command_result<=0;rejected_lines<=0;
            heartbeat_pulse<=0;configure_pulse<=0;configured_tag<=0;
            display_loaded<=0;display_text<=0;display_token<=0;
        end else begin
            handled_pulse<=0;
            heartbeat_pulse<=0;configure_pulse<=0;
            if(bound_round!=round_id || bound_tag!=info_tag || bound_boot!=boot_id) begin
                bound_round<=round_id;bound_tag<=info_tag;bound_boot<=boot_id;presented<=0;display_loaded<=0;
                // Token allocation is per boot, not per presentation round.
                if(bound_boot!=boot_id) begin last_token<=0;heartbeat_token<=0;last_command<=0;last_result<=0;end
            end
            if(rx_valid) case(phase)
                0:if(rx_data=="V") phase<=1;else if(rx_data!=10) phase<=5;
                1:if(rx_data=="C") phase<=2;else phase<=rx_data==10?0:5;
                2:if(rx_data==",") begin phase<=3;index<=0;crc<=32'hffffffff;end
                  else phase<=rx_data==10?0:5;
                3:if(hex_valid) begin
                    buffer_data[511-index*4 -:4]<=nibble;
                    if(!index[0]) high_nibble<=nibble;
                    else if(index<120) crc<=crc_byte(crc,{high_nibble,nibble});
                    if(index==127) phase<=4;else index<=index+1'b1;
                end else begin
                    phase<=rx_data==10?0:5;
                    if(rejected_lines!=32'hffffffff) rejected_lines<=rejected_lines+1'b1;
                end
                4:begin
                    if(rx_data==10 && valid_fields && buffer_data[31:0]==~crc) begin
                        if(operation==4) begin
                            // Separate sequence: heartbeats cannot overwrite a
                            // teacher command acknowledgement while UI waits.
                            if(binding_ok && token>heartbeat_token) begin
                                heartbeat_token<=token;heartbeat_pulse<=1;
                            end
                        end else begin
                        if(operation!=4) begin command_token<=token;command_op<=operation;end
                        if(!binding_ok) command_result<=2;
                        else if(token==last_token) begin
                            command_result<=buffer_data==last_command ? last_result : 3;
                        end else if(token<last_token) command_result<=4;
                        else begin
                            last_token<=token;last_command<=buffer_data;
                            if(operation==1 && exam_stage==2) begin
                                presented<=1;presented_round<=round_id;presented_tag<=info_tag;
                                command_result<=1;last_result<=1;
                            end else if(operation==2 && help_pending && buffer_data[255:224]==help_ticket) begin
                                handled_pulse<=1;handled_round<=round_id;handled_tag<=info_tag;handled_ticket<=help_ticket;
                                command_result<=1;last_result<=1;
                            end else if(operation==3 && exam_stage==2 && !help_pending) begin
                                configure_pulse<=1;configured_tag<=buffer_data[319:256];presented<=0;
                                command_result<=1;last_result<=1;
                            end else if(operation==5 && exam_stage==2) begin
                                display_loaded<=1;display_text<=buffer_data[191:64];display_token<=token;
                                command_result<=1;last_result<=1;
                            end else begin command_result<=2;last_result<=2;end
                        end
                        end
                    end else if(rejected_lines!=32'hffffffff) rejected_lines<=rejected_lines+1'b1;
                    phase<=rx_data==10?0:5;
                end
                5:if(rx_data==10) phase<=0;
                default:phase<=0;
            endcase
        end
    end
endmodule
