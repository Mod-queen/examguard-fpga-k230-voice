`timescale 1ns/1ps
// Exclusive read-only DRP owner for the XADC already used by MIG tempmon.
// One completed sequencer scan -> TEMP/VCCINT/VCCAUX/VCCBRAM. Publish atomically.
module xadc_monitor_reader #(parameter integer TIMEOUT_CYCLES=1024)(
    input wire clk,rst,eos,input wire drdy,input wire [15:0] drp_data,
    output wire den,output wire [6:0] daddr,
    output reg valid,output reg [31:0] sequence_id,output reg [63:0] samples,
    output reg [11:0] temperature,output reg fault
);
    reg [1:0] state,channel;reg [63:0] held;reg [31:0] timeout;
    assign den=!rst && state==1;
    assign daddr=channel==3?7'h06:{5'd0,channel};
    always @(posedge clk) begin
        if(rst) begin state<=0;channel<=0;held<=0;timeout<=0;valid<=0;sequence_id<=0;samples<=0;temperature<=0;fault<=0;end
        else case(state)
            0:if(eos) begin state<=1;channel<=0;end
            1:begin state<=2;timeout<=0;end
            2:if(drdy) begin
                held[channel*16+:16]<=drp_data;
                if(channel==0) temperature<=drp_data[15:4];
                if(channel==3) begin
                    samples<={drp_data,held[47:0]};valid<=1;
                    if(sequence_id!=32'hffffffff) sequence_id<=sequence_id+1'b1;
                    state<=0;
                end else begin channel<=channel+1'b1;state<=1;end
            end else if(timeout==TIMEOUT_CYCLES-1) begin fault<=1;valid<=0;state<=3;end
            else timeout<=timeout+1'b1;
            3:begin valid<=0;end // No abandoning a live DRP request; common reset recovers.
        endcase
    end
endmodule
