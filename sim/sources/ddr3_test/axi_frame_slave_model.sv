`timescale 1ns/1ps

// Byte-addressed independent AXI test memory. Random AW/W/AR/R backpressure,
// delayed B, stable responses under stall, and explicit response injection.
module axi_frame_slave_model #(parameter integer MEM_BYTES=32768, parameter integer INITIALIZE=1)(
    input wire clk, rst, hold_b, inject_b, inject_r,
    input wire [3:0] m_axi_awid,
    input wire [29:0] m_axi_awaddr,
    input wire [7:0] m_axi_awlen,
    input wire [2:0] m_axi_awsize,
    input wire [1:0] m_axi_awburst,
    input wire m_axi_awvalid,
    output wire m_axi_awready,
    input wire [127:0] m_axi_wdata,
    input wire [15:0] m_axi_wstrb,
    input wire m_axi_wlast, m_axi_wvalid,
    output wire m_axi_wready,
    output reg [3:0] m_axi_bid,
    output reg [1:0] m_axi_bresp,
    output reg m_axi_bvalid,
    input wire m_axi_bready,
    input wire [3:0] m_axi_arid,
    input wire [29:0] m_axi_araddr,
    input wire [7:0] m_axi_arlen,
    input wire [2:0] m_axi_arsize,
    input wire [1:0] m_axi_arburst,
    input wire m_axi_arvalid,
    output wire m_axi_arready,
    output reg [3:0] m_axi_rid,
    output reg [127:0] m_axi_rdata,
    output reg [1:0] m_axi_rresp,
    output reg m_axi_rlast, m_axi_rvalid,
    input wire m_axi_rready
);
    reg [7:0] mem [0:MEM_BYTES-1];
    reg [31:0] rng = 32'h9e3779b9;
    reg writing, responding, reading, berr, rerr;
    reg [29:0] wa, ra;
    reg [8:0] wn, rn;
    reg [3:0] wid, rid;
    integer delay_b, i;
    integer aw_count=0, ar_count=0, b_count=0;
    assign m_axi_awready = !rst && !writing && !responding && !m_axi_bvalid && rng[0];
    assign m_axi_wready = !rst && writing && rng[1];
    assign m_axi_arready = !rst && !reading && !m_axi_rvalid && rng[2];
    initial if(INITIALIZE) for (i=0; i<MEM_BYTES; i=i+1) mem[i]=8'ha5;
    task check_addr;
        input [29:0] a;
        input [7:0] len;
        input [2:0] size;
        input [1:0] burst;
        begin
            if (a[3:0]!=0 || size!=4 || burst!=1 || len>31 ||
                a[11:0]+(len+1)*16 > 4096 || a+(len+1)*16 > MEM_BYTES)
                $fatal(1,"FAIL: illegal AXI burst a=%h len=%d",a,len);
        end
    endtask
    always @(posedge clk) begin
        rng <= {rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        if (rst) begin
            writing<=0; responding<=0; reading<=0; delay_b<=0;
            m_axi_bvalid<=0; m_axi_rvalid<=0; m_axi_bresp<=0;
            m_axi_bid<=0; m_axi_rid<=0; m_axi_rlast<=0;
            m_axi_rresp<=0; m_axi_rdata<=0;
            wa<=0; ra<=0; wn<=0; rn<=0; wid<=0; rid<=0; berr<=0; rerr<=0;
            aw_count<=0; ar_count<=0; b_count<=0;
        end else begin
            if (m_axi_awvalid && m_axi_awready) begin
                check_addr(m_axi_awaddr,m_axi_awlen,m_axi_awsize,m_axi_awburst);
                writing<=1; wa<=m_axi_awaddr; wn<=m_axi_awlen+1;
                wid<=m_axi_awid; berr<=inject_b; aw_count<=aw_count+1;
            end
            if (m_axi_wvalid && m_axi_wready) begin
                if (m_axi_wlast != (wn==1)) $fatal(1,"FAIL: WLAST length");
                for (i=0;i<16;i=i+1)
                    if (m_axi_wstrb[i]) mem[wa+i]<=m_axi_wdata[i*8 +: 8];
                wa<=wa+16; wn<=wn-1;
                if (wn==1) begin writing<=0; responding<=1; delay_b<=20+rng[7:4]; end
            end
            if (responding && !hold_b) begin
                if (delay_b!=0) delay_b<=delay_b-1;
                else begin
                    m_axi_bvalid<=1; m_axi_bresp<=berr ? 2'b10 : 0;
                    m_axi_bid<=wid; responding<=0;
                end
            end
            if (m_axi_bvalid && m_axi_bready) begin m_axi_bvalid<=0; b_count<=b_count+1; end
            if (m_axi_arvalid && m_axi_arready) begin
                check_addr(m_axi_araddr,m_axi_arlen,m_axi_arsize,m_axi_arburst);
                reading<=1; ra<=m_axi_araddr; rn<=m_axi_arlen+1;
                rid<=m_axi_arid; rerr<=inject_r; ar_count<=ar_count+1;
            end
            if (reading && !m_axi_rvalid && rng[3]) begin
                for (i=0;i<16;i=i+1) m_axi_rdata[i*8 +: 8]<=mem[ra+i];
                m_axi_rvalid<=1; m_axi_rlast<=rn==1; m_axi_rid<=rid;
                m_axi_rresp<=rerr ? 2'b10 : 0;
            end
            if (m_axi_rvalid && m_axi_rready) begin
                m_axi_rvalid<=0; ra<=ra+16; rn<=rn-1;
                if (rn==1) reading<=0;
            end
        end
    end
    reg aw_stall=0, w_stall=0, ar_stall=0;
    reg [42:0] aw_old, ar_old;
    reg [144:0] w_old;
    always @(posedge clk) begin
        if (!rst) begin
            if (aw_stall && (!m_axi_awvalid ||
                {m_axi_awaddr,m_axi_awlen,m_axi_awsize,m_axi_awburst}!==aw_old))
                $fatal(1,"FAIL: AW changed under stall");
            if (ar_stall && (!m_axi_arvalid ||
                {m_axi_araddr,m_axi_arlen,m_axi_arsize,m_axi_arburst}!==ar_old))
                $fatal(1,"FAIL: AR changed under stall");
            if (w_stall && (!m_axi_wvalid || {m_axi_wdata,m_axi_wstrb,m_axi_wlast}!==w_old))
                $fatal(1,"FAIL: W changed under stall");
        end
        aw_stall<=!rst && m_axi_awvalid && !m_axi_awready;
        ar_stall<=!rst && m_axi_arvalid && !m_axi_arready;
        w_stall<=!rst && m_axi_wvalid && !m_axi_wready;
        aw_old<={m_axi_awaddr,m_axi_awlen,m_axi_awsize,m_axi_awburst};
        ar_old<={m_axi_araddr,m_axi_arlen,m_axi_arsize,m_axi_arburst};
        w_old<={m_axi_wdata,m_axi_wstrb,m_axi_wlast};
    end
endmodule
