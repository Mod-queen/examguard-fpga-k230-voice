`timescale 1ns/1ps
// One NEXT_BOOT allocation per system reset. A blank device needs explicit
// format authorization; SCAN can never open admission. Any allocation error
// latches closed until system reset / externally controlled maintenance retry.
module persistent_boot_gate(
    input wire clk,rst,start,format_blank,
    input wire [31:0] device,input wire [255:0] initial_config,
    output wire store_cmd_valid,input wire store_cmd_ready,output reg [1:0] store_cmd,
    output reg [31:0] store_device,output reg [255:0] store_config,
    input wire store_result_valid,output wire store_result_ready,
    input wire [3:0] store_error,input wire store_loaded,
    input wire [31:0] store_boot,
    output reg admission,done,output reg [3:0] error,output reg [31:0] boot_id
);
    reg [1:0] state;
    assign store_cmd_valid=!rst && state==1;
    assign store_result_ready=!rst && state==2;
    always @(posedge clk) begin
        if(rst) begin state<=0;store_cmd<=0;store_device<=0;store_config<=0;admission<=0;done<=0;error<=0;boot_id<=0;end
        else case(state)
            0:if(start) begin
                store_cmd<=format_blank?3:1;store_device<=device;store_config<=initial_config;state<=1;
            end
            1:if(store_cmd_ready) state<=2;
            2:if(store_result_valid) begin
                error<=store_error;done<=1;state<=3;
                if(store_error==0 && store_loaded && store_boot!=0) begin admission<=1;boot_id<=store_boot;end
                else begin admission<=0;if(store_error==0) error<=7;end
            end
        endcase
    end
endmodule
