`timescale 1ns/1ps
// Replaces (not supplements) MIG's internal XADC instance in monitor candidate.
// UG480 sequence48 bits8,9,10,14 plus calibration0; all measured rails on-chip.
module shared_xadc_monitor(
    input wire clk,rst,output wire [11:0] temperature,
    output wire [96:0] monitor
);
    wire den,drdy,eos,valid,fault;wire [6:0] daddr;wire [15:0] dout;
    wire [31:0] sequence_id;wire [63:0] samples;
    xadc_monitor_reader reader(.clk(clk),.rst(rst),.eos(eos),.drdy(drdy),.drp_data(dout),
        .den(den),.daddr(daddr),.valid(valid),.sequence_id(sequence_id),.samples(samples),.temperature(temperature),.fault(fault));
    assign monitor={valid && !fault,sequence_id,samples};
    XADC #(.INIT_40(16'h1000),.INIT_41(16'h2fff),.INIT_42(16'h0800),
        .INIT_48(16'h4701),.INIT_49(16'h0000),.INIT_4A(16'h4700),.INIT_4B(16'h0000),
        .INIT_4C(16'h0000),.INIT_4D(16'h0000),.INIT_4E(16'h0000),.INIT_4F(16'h0000),
        .INIT_50(16'hb5ed),.INIT_51(16'h57e4),.INIT_52(16'ha147),.INIT_53(16'hca33),
        .INIT_54(16'ha93a),.INIT_55(16'h52c6),.INIT_56(16'h9555),.INIT_57(16'hae4e),
        .INIT_58(16'h5999),.INIT_5C(16'h5111),.SIM_DEVICE("7SERIES")) xadc(
        .DCLK(clk),.RESET(1'b0),.DEN(den),.DADDR(daddr),.DI(16'd0),.DWE(1'b0),.DO(dout),.DRDY(drdy),
        .EOS(eos),.EOC(),.BUSY(),.CHANNEL(),.ALM(),.OT(),.JTAGBUSY(),.JTAGLOCKED(),.JTAGMODIFIED(),.MUXADDR(),
        .CONVST(1'b0),.CONVSTCLK(1'b0),.VAUXP(16'd0),.VAUXN(16'd0),.VP(1'b0),.VN(1'b0));
endmodule
