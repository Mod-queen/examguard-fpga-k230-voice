`timescale 1ns/1ps
// Four regions are ALL written before ANY read, detecting high address aliases.
// Fixed board AXI128/addr30, 32-beat aligned bursts. Default covers whole 1GiB.
// Sticky timeout observes a stalled transaction, never abandons a live owner.
module ddr3_capacity_test #(
    parameter integer REGION_BYTES=268435456,PASSES=2,STALL_CYCLES=100000000
)(
    input wire clk,rst,start,
    output wire [3:0] m_axi_awid,output wire [29:0] m_axi_awaddr,
    output wire [7:0] m_axi_awlen,output wire [2:0] m_axi_awsize,output wire [1:0] m_axi_awburst,
    output wire m_axi_awvalid,input wire m_axi_awready,
    output wire [127:0] m_axi_wdata,output wire [15:0] m_axi_wstrb,output wire m_axi_wlast,m_axi_wvalid,
    input wire m_axi_wready,input wire [3:0] m_axi_bid,input wire [1:0] m_axi_bresp,
    input wire m_axi_bvalid,output wire m_axi_bready,
    output wire [3:0] m_axi_arid,output wire [29:0] m_axi_araddr,
    output wire [7:0] m_axi_arlen,output wire [2:0] m_axi_arsize,output wire [1:0] m_axi_arburst,
    output wire m_axi_arvalid,input wire m_axi_arready,
    input wire [3:0] m_axi_rid,input wire [127:0] m_axi_rdata,input wire [1:0] m_axi_rresp,
    input wire m_axi_rlast,m_axi_rvalid,output wire m_axi_rready,
    output wire busy,output reg done,output reg timed_out,
    output reg [31:0] errors,passes_done,beats_written,beats_read,
    output reg [127:0] region_errors,write_cycles,read_cycles
);
    localparam IDLE=0,AW=1,W=2,B=3,AR=4,R=5,FINISH=6;
    reg [2:0] state;reg [1:0] region;
    reg [31:0] burst_index,pass,stall;
    reg [7:0] beat;
    wire [29:0] address={region,28'd0}+(burst_index<<9);
    wire [29:0] beat_address=address+{18'd0,beat,4'd0};
    function automatic [31:0] inc(input [31:0] n);inc=&n?n:n+1'b1;endfunction
    function automatic [127:0] pattern(input [29:0] addr,input [31:0] iteration);
        reg [31:0] a;
        begin a={2'd0,addr};pattern={a^iteration,~a^iteration,(a+32'h13579bdf)^iteration,(a^32'h2468ace0)^iteration};end
    endfunction
    assign busy=state!=IDLE;
    assign m_axi_awid=0;assign m_axi_arid=0;
    assign m_axi_awaddr=address;assign m_axi_araddr=address;
    assign m_axi_awlen=31;assign m_axi_arlen=31;
    assign m_axi_awsize=4;assign m_axi_arsize=4;
    assign m_axi_awburst=1;assign m_axi_arburst=1;
    assign m_axi_awvalid=!rst && state==AW;assign m_axi_arvalid=!rst && state==AR;
    assign m_axi_wvalid=!rst && state==W;assign m_axi_wlast=beat==31;
    assign m_axi_wstrb=16'hffff;assign m_axi_wdata=pattern(beat_address,pass);
    assign m_axi_bready=!rst && state==B;assign m_axi_rready=!rst && state==R;
    wire progress=(m_axi_awvalid && m_axi_awready)||(m_axi_wvalid && m_axi_wready)||
        (m_axi_bvalid && m_axi_bready)||(m_axi_arvalid && m_axi_arready)||(m_axi_rvalid && m_axi_rready);
    wire read_error=m_axi_rdata!==pattern(beat_address,pass) || m_axi_rresp!=0 || m_axi_rid!=0 || m_axi_rlast!=(beat==31);
    task record_error;
        begin errors<=inc(errors);region_errors[region*32+:32]<=inc(region_errors[region*32+:32]);end
    endtask
    always @(posedge clk) begin
        if(rst) begin state<=IDLE;region<=0;burst_index<=0;pass<=0;stall<=0;beat<=0;
            done<=0;timed_out<=0;errors<=0;passes_done<=0;beats_written<=0;beats_read<=0;
            region_errors<=0;write_cycles<=0;read_cycles<=0;end
        else begin
            done<=0;
            if(state>=AW && state<=B) write_cycles[region*32+:32]<=inc(write_cycles[region*32+:32]);
            if(state==AR || state==R) read_cycles[region*32+:32]<=inc(read_cycles[region*32+:32]);
            if(state==IDLE || state==FINISH || progress) stall<=0;
            else begin stall<=inc(stall);if(stall==STALL_CYCLES-1) timed_out<=1;end
            case(state)
                IDLE:if(start) begin state<=AW;region<=0;burst_index<=0;pass<=0;beat<=0;
                    timed_out<=0;errors<=0;passes_done<=0;beats_written<=0;beats_read<=0;
                    region_errors<=0;write_cycles<=0;read_cycles<=0;end
                AW:if(m_axi_awready) begin state<=W;beat<=0;end
                W:if(m_axi_wready) begin
                    beats_written<=inc(beats_written);
                    if(beat==31) state<=B;else beat<=beat+1'b1;
                end
                B:if(m_axi_bvalid) begin
                    if(m_axi_bresp!=0 || m_axi_bid!=0) record_error();
                    if(burst_index==REGION_BYTES/512-1) begin
                        burst_index<=0;region<=region+1'b1;state<=region==3?AR:AW;
                    end else begin burst_index<=burst_index+1'b1;state<=AW;end
                end
                AR:if(m_axi_arready) begin state<=R;beat<=0;end
                R:if(m_axi_rvalid) begin
                    beats_read<=inc(beats_read);if(read_error) record_error();
                    if(m_axi_rlast) begin
                        if(burst_index==REGION_BYTES/512-1) begin
                            burst_index<=0;region<=region+1'b1;
                            if(region==3) begin
                                passes_done<=inc(passes_done);
                                if(pass==PASSES-1) state<=FINISH;else begin pass<=pass+1'b1;state<=AW;end
                            end else state<=AR;
                        end else begin burst_index<=burst_index+1'b1;state<=AR;end
                    end else if(beat!=255) beat<=beat+1'b1;
                end
                FINISH:begin done<=1;state<=IDLE;end
                default:state<=IDLE;
            endcase
        end
    end
    // synthesis translate_off
    initial if(REGION_BYTES<512 || REGION_BYTES>268435456 || REGION_BYTES%512!=0 || PASSES<1 || STALL_CYCLES<1)
        $fatal(1,"FAIL: capacity parameters");
    // synthesis translate_on
endmodule
