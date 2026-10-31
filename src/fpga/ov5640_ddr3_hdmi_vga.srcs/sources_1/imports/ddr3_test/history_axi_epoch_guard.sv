`timescale 1ns/1ps
// Single-outstanding AXI epoch boundary, upstream of the shared video fabric.
// rst is the COMMON fabric/slave reset. cancel resets ONLY the history master.
// Entire W burst is buffered BEFORE downstream AW, so cancellation can never
// strand shared ownership waiting for pixels from a reset history DMA.
// Committed AW/AR remain stable and finish; cancelled B/R never reach a new epoch.
module history_axi_epoch_guard(
    input wire clk,rst,cancel,
    output reg idle,
    output reg protocol_fault,
    input wire [3:0] s_awid,s_arid,
    input wire [29:0] s_awaddr,s_araddr,
    input wire [7:0] s_awlen,s_arlen,
    input wire [2:0] s_awsize,s_arsize,
    input wire [1:0] s_awburst,s_arburst,
    input wire s_awvalid,s_arvalid,
    output wire s_awready,s_arready,
    input wire [127:0] s_wdata,input wire [15:0] s_wstrb,
    input wire s_wlast,s_wvalid,output wire s_wready,
    output wire [3:0] s_bid,s_rid,
    output wire [1:0] s_bresp,s_rresp,
    output wire s_bvalid,s_rvalid,s_rlast,
    output wire [127:0] s_rdata,input wire s_bready,s_rready,
    output wire [3:0] m_awid,m_arid,
    output wire [29:0] m_awaddr,m_araddr,
    output wire [7:0] m_awlen,m_arlen,
    output wire [2:0] m_awsize,m_arsize,
    output wire [1:0] m_awburst,m_arburst,
    output wire m_awvalid,m_arvalid,input wire m_awready,m_arready,
    output wire [127:0] m_wdata,output wire [15:0] m_wstrb,
    output wire m_wlast,m_wvalid,input wire m_wready,
    input wire [3:0] m_bid,m_rid,input wire [1:0] m_bresp,m_rresp,
    input wire m_bvalid,m_rvalid,m_rlast,input wire [127:0] m_rdata,
    output wire m_bready,m_rready
);
    localparam WI=0,WC=1,WA=2,WD=3,WB=4,WF=5;
    localparam RI=0,RA=1,RD=2;
    reg [2:0] ws;
    reg [1:0] rs;
    reg [3:0] wid,rid;
    reg [29:0] wa,ra;
    reg [7:0] wl,rl;
    reg [2:0] wz,rz;
    reg [1:0] wt,rt;
    reg wp,rp;
    reg [5:0] wc,wi;
    reg [8:0] rn;
    (* ram_style="distributed" *) reg [143:0] data[0:31];
    wire write_discard=wp || cancel;
    wire read_discard=rp || cancel;
    assign s_awready=!rst && !cancel && ws==WI;
    assign s_wready=!rst && !cancel && ws==WC;
    assign s_arready=!rst && !cancel && rs==RI;
    assign m_awid=wid;assign m_awaddr=wa;assign m_awlen=wl;assign m_awsize=wz;assign m_awburst=wt;
    assign m_arid=rid;assign m_araddr=ra;assign m_arlen=rl;assign m_arsize=rz;assign m_arburst=rt;
    assign m_awvalid=!rst && ws==WA;
    assign m_arvalid=!rst && rs==RA;
    assign {m_wstrb,m_wdata}=data[wi[4:0]];
    assign m_wlast=wi==wl;
    assign m_wvalid=!rst && ws==WD;
    assign s_bid=m_bid;assign s_bresp=m_bresp;
    assign s_bvalid=!rst && ws==WB && !write_discard && m_bvalid;
    assign m_bready=!rst && ws==WB && (write_discard || s_bready);
    assign s_rid=m_rid;assign s_rdata=m_rdata;assign s_rresp=m_rresp;assign s_rlast=m_rlast;
    assign s_rvalid=!rst && rs==RD && !read_discard && m_rvalid;
    assign m_rready=!rst && rs==RD && (read_discard || s_rready);
    // RAM has one unreset write port; no BRAM/FF explosion from async reset.
    always @(posedge clk)
        if(!rst && s_wvalid && s_wready) data[wc[4:0]]<={s_wstrb,s_wdata};
    always @(posedge clk) begin
        if(rst) begin
            ws<=WI;rs<=RI;wid<=0;rid<=0;wa<=0;ra<=0;wl<=0;rl<=0;wz<=0;rz<=0;wt<=0;rt<=0;
            wp<=0;rp<=0;wc<=0;wi<=0;rn<=0;protocol_fault<=0;idle<=1;
        end else begin
            // Register before CDC: a combinational decode of two FSMs can
            // glitch "idle" while an old transaction is still outstanding.
            idle<=ws==WI && rs==RI && !(s_awvalid && s_awready) && !(s_arvalid && s_arready);
            if(cancel) begin wp<=1;rp<=1;end
            case(ws)
                WI:if(s_awvalid && s_awready) begin
                    wid<=s_awid;wa<=s_awaddr;wl<=s_awlen;wz<=s_awsize;wt<=s_awburst;
                    wc<=0;wi<=0;wp<=0;
                    if(s_awlen>31 || s_awsize!=4 || s_awburst!=1 || s_awaddr[3:0]!=0 ||
                        {1'b0,s_awaddr[11:0]}+({5'd0,s_awlen}+13'd1)*13'd16>4096) begin
                        protocol_fault<=1;ws<=WF;
                    end else ws<=WC;
                end
                WC:if(cancel) ws<=WI;
                else if(s_wvalid && s_wready) begin
                    if(s_wlast!=(wc==wl)) begin protocol_fault<=1;ws<=WF;end
                    else if(wc==wl) begin ws<=WA;wi<=0;end
                    else wc<=wc+1'b1;
                end
                // Even before READY, asserting VALID is an irrevocable promise.
                WA:if(m_awready) ws<=WD;
                WD:if(m_wready) begin
                    if(m_wlast) ws<=WB;else wi<=wi+1'b1;
                end
                WB:if(m_bvalid && m_bready) begin
                    if(m_bid!=wid) protocol_fault<=1;
                    ws<=WI;
                end
                WF:if(cancel) ws<=WI;
                default:begin ws<=WF;protocol_fault<=1;end
            endcase
            case(rs)
                RI:if(s_arvalid && s_arready) begin
                    rid<=s_arid;ra<=s_araddr;rl<=s_arlen;rz<=s_arsize;rt<=s_arburst;rp<=0;
                    rn<={1'b0,s_arlen}+1'b1;rs<=RA;
                end
                RA:if(m_arready) rs<=RD;
                RD:if(m_rvalid && m_rready) begin
                    if(m_rid!=rid || m_rlast!=(rn==1)) protocol_fault<=1;
                    rn<=rn-1'b1;
                    if(m_rlast) rs<=RI;
                end
                default:begin rs<=RI;protocol_fault<=1;end
            endcase
        end
    end
endmodule
