`timescale 1ns/1ps
// History-client source-domain adapter for canonical EHealth v2 word layout.
// UI and Ethernet paths are independent domains; CDC remains the telemetry's
// responsibility. No statistics from one domain are sampled in the other.
module history_health_stats(
    input wire ui_clk,ui_rst,eth_clk,eth_rst,
    input wire request_fire,result_fire,result_ok,
    input wire [2:0] result_code,pending_windows,
    input wire result_valid,out_valid,axi_fault,pixel_fault,hr_fault,
    input wire [31:0] frames_committed,frames_failed,
    input wire pixel_packet_fire,hr_packet_fire,
    input wire packet_stall,udp_fault,
    input wire [31:0] udp_sent,udp_dropped,
    output wire [255:0] ui_stats,output wire [127:0] eth_stats
);
    reg [31:0] accepted,completed,read_failed,windows_failed,packets_serialized;
    reg [7:0] high_water;
    always @(posedge ui_clk) begin
        if(ui_rst) begin
            accepted<=0;completed<=0;read_failed<=0;windows_failed<=0;packets_serialized<=0;high_water<=0;
        end else begin
            if(request_fire && accepted!=32'hffffffff) accepted<=accepted+1'b1;
            if(result_fire && completed!=32'hffffffff) completed<=completed+1'b1;
            if(result_fire && result_code==4 && read_failed!=32'hffffffff) read_failed<=read_failed+1'b1;
            if(result_fire && !result_ok && windows_failed!=32'hffffffff) windows_failed<=windows_failed+1'b1;
            case({pixel_packet_fire,hr_packet_fire})
                1,2:if(packets_serialized!=32'hffffffff) packets_serialized<=packets_serialized+1'b1;
                3:packets_serialized<=packets_serialized>=32'hfffffffe ? 32'hffffffff : packets_serialized+2;
            endcase
            if({5'd0,pending_windows}>high_water) high_water<={5'd0,pending_windows};
        end
    end
    wire busy=(pending_windows!=0) || result_valid || out_valid;
    wire [31:0] ui_state={busy,(axi_fault || pixel_fault || hr_fault),14'd0,high_water,5'd0,pending_windows};
    assign ui_stats={ui_state,accepted,completed,frames_committed,frames_failed,read_failed,windows_failed,packets_serialized};
    assign eth_stats={30'd0,udp_fault,packet_stall,udp_sent,udp_dropped,32'd0};
endmodule
