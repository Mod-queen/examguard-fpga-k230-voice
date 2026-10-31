`timescale 1ns/1ps

// Single-clock AXI4 2-client -> 1-slave arbiter. Client 0=video, 1=evidence.
// Packed client buses: client0 is the LOW slice. Independent read/write FSMs,
// one outstanding burst PER DIRECTION globally; both directions can overlap.
// Address handshake first latches ALL attributes; a stalled downstream address
// never depends on changing clients. Write owner locks through B handshake;
// read owner locks through accepted RLAST. No ID bits stolen/remapped.
// Weighted burst scheduling: while both clients keep VALID, at most
// VIDEO_QUOTA video bursts precede evidence. This is NOT a cycle/deadline bound:
// an owner/slave that stalls indefinitely blocks that direction indefinitely.
// AXI peers must obey VALID stability, WLAST/RLAST and reset together with MIG.
// Errors are reported, not synthesized into successful transfers or retries.
module axi_2client_arbiter #(
    parameter integer ADDR_WIDTH=30, DATA_WIDTH=128, ID_WIDTH=4,
    parameter integer VIDEO_QUOTA=3,
    parameter integer QUOTA_W=VIDEO_QUOTA<2 ? 1 : $clog2(VIDEO_QUOTA+1)
)(
    input wire clk, rst,
    input wire [2*ID_WIDTH-1:0] s_axi_awid,
    input wire [2*ADDR_WIDTH-1:0] s_axi_awaddr,
    input wire [15:0] s_axi_awlen,
    input wire [5:0] s_axi_awsize,
    input wire [3:0] s_axi_awburst,
    input wire [1:0] s_axi_awlock,
    input wire [7:0] s_axi_awcache,
    input wire [5:0] s_axi_awprot,
    input wire [7:0] s_axi_awqos,
    input wire [1:0] s_axi_awvalid,
    output wire [1:0] s_axi_awready,
    input wire [2*DATA_WIDTH-1:0] s_axi_wdata,
    input wire [2*(DATA_WIDTH/8)-1:0] s_axi_wstrb,
    input wire [1:0] s_axi_wlast, s_axi_wvalid,
    output wire [1:0] s_axi_wready,
    output wire [2*ID_WIDTH-1:0] s_axi_bid,
    output wire [3:0] s_axi_bresp,
    output wire [1:0] s_axi_bvalid,
    input wire [1:0] s_axi_bready,
    input wire [2*ID_WIDTH-1:0] s_axi_arid,
    input wire [2*ADDR_WIDTH-1:0] s_axi_araddr,
    input wire [15:0] s_axi_arlen,
    input wire [5:0] s_axi_arsize,
    input wire [3:0] s_axi_arburst,
    input wire [1:0] s_axi_arlock,
    input wire [7:0] s_axi_arcache,
    input wire [5:0] s_axi_arprot,
    input wire [7:0] s_axi_arqos,
    input wire [1:0] s_axi_arvalid,
    output wire [1:0] s_axi_arready,
    output wire [2*ID_WIDTH-1:0] s_axi_rid,
    output wire [2*DATA_WIDTH-1:0] s_axi_rdata,
    output wire [3:0] s_axi_rresp,
    output wire [1:0] s_axi_rlast, s_axi_rvalid,
    input wire [1:0] s_axi_rready,
    output wire [ID_WIDTH-1:0] m_axi_awid,
    output wire [ADDR_WIDTH-1:0] m_axi_awaddr,
    output wire [7:0] m_axi_awlen,
    output wire [2:0] m_axi_awsize,
    output wire [1:0] m_axi_awburst,
    output wire m_axi_awlock,
    output wire [3:0] m_axi_awcache,
    output wire [2:0] m_axi_awprot,
    output wire [3:0] m_axi_awqos,
    output wire m_axi_awvalid,
    input wire m_axi_awready,
    output wire [DATA_WIDTH-1:0] m_axi_wdata,
    output wire [DATA_WIDTH/8-1:0] m_axi_wstrb,
    output wire m_axi_wlast, m_axi_wvalid,
    input wire m_axi_wready,
    input wire [ID_WIDTH-1:0] m_axi_bid,
    input wire [1:0] m_axi_bresp,
    input wire m_axi_bvalid,
    output wire m_axi_bready,
    output wire [ID_WIDTH-1:0] m_axi_arid,
    output wire [ADDR_WIDTH-1:0] m_axi_araddr,
    output wire [7:0] m_axi_arlen,
    output wire [2:0] m_axi_arsize,
    output wire [1:0] m_axi_arburst,
    output wire m_axi_arlock,
    output wire [3:0] m_axi_arcache,
    output wire [2:0] m_axi_arprot,
    output wire [3:0] m_axi_arqos,
    output wire m_axi_arvalid,
    input wire m_axi_arready,
    input wire [ID_WIDTH-1:0] m_axi_rid,
    input wire [DATA_WIDTH-1:0] m_axi_rdata,
    input wire [1:0] m_axi_rresp,
    input wire m_axi_rlast, m_axi_rvalid,
    output wire m_axi_rready,
    output wire write_busy, read_busy,
    output reg write_owner, read_owner,
    output reg [3:0] protocol_fault,
    output reg [63:0] write_grants, read_grants, write_completed, read_completed,
    output reg [63:0] write_beats, read_beats, write_errors, read_errors,
    output reg [63:0] write_wait_max, read_wait_max
);
    localparam CMD_W=ID_WIDTH+ADDR_WIDTH+25;
    localparam [1:0] W_IDLE=0,W_ADDR=1,W_DATA=2,W_RESP=3;
    localparam [1:0] R_IDLE=0,R_ADDR=1,R_DATA=2;
    reg [1:0] ws,rs;
    reg [CMD_W-1:0] wcmd,rcmd;
    reg [QUOTA_W-1:0] wquota,rquota;
    reg [8:0] wleft,rleft;
    reg [63:0] wwait,rwait;
    wire wpick = s_axi_awvalid[1] && (!s_axi_awvalid[0] || wquota==VIDEO_QUOTA);
    wire rpick = s_axi_arvalid[1] && (!s_axi_arvalid[0] || rquota==VIDEO_QUOTA);
    wire take_w = !rst && ws==W_IDLE && |s_axi_awvalid;
    wire take_r = !rst && rs==R_IDLE && |s_axi_arvalid;
    assign s_axi_awready = take_w ? (wpick ? 2'b10 : 2'b01) : 2'b00;
    assign s_axi_arready = take_r ? (rpick ? 2'b10 : 2'b01) : 2'b00;
    assign {m_axi_awid,m_axi_awaddr,m_axi_awlen,m_axi_awsize,m_axi_awburst,
        m_axi_awlock,m_axi_awcache,m_axi_awprot,m_axi_awqos}=wcmd;
    assign {m_axi_arid,m_axi_araddr,m_axi_arlen,m_axi_arsize,m_axi_arburst,
        m_axi_arlock,m_axi_arcache,m_axi_arprot,m_axi_arqos}=rcmd;
    assign m_axi_awvalid=!rst && ws==W_ADDR;
    assign m_axi_arvalid=!rst && rs==R_ADDR;
    assign m_axi_wdata=s_axi_wdata[write_owner*DATA_WIDTH +: DATA_WIDTH];
    assign m_axi_wstrb=s_axi_wstrb[write_owner*(DATA_WIDTH/8) +: DATA_WIDTH/8];
    assign m_axi_wlast=s_axi_wlast[write_owner];
    assign m_axi_wvalid=!rst && ws==W_DATA && s_axi_wvalid[write_owner];
    assign s_axi_wready=(!rst && ws==W_DATA && m_axi_wready) ? (write_owner ? 2'b10 : 2'b01) : 0;
    assign m_axi_bready=!rst && ws==W_RESP && s_axi_bready[write_owner];
    assign m_axi_rready=!rst && rs==R_DATA && s_axi_rready[read_owner];
    assign s_axi_bvalid=(!rst && ws==W_RESP && m_axi_bvalid) ? (write_owner ? 2'b10 : 2'b01) : 0;
    assign s_axi_rvalid=(!rst && rs==R_DATA && m_axi_rvalid) ? (read_owner ? 2'b10 : 2'b01) : 0;
    assign s_axi_bid={2{m_axi_bid}};
    assign s_axi_bresp={2{m_axi_bresp}};
    assign s_axi_rid={2{m_axi_rid}};
    assign s_axi_rdata={2{m_axi_rdata}};
    assign s_axi_rresp={2{m_axi_rresp}};
    assign s_axi_rlast={2{m_axi_rlast}};
    assign write_busy=ws!=W_IDLE;
    assign read_busy=rs!=R_IDLE;
    wire wf=m_axi_wvalid && m_axi_wready;
    wire bf=m_axi_bvalid && m_axi_bready;
    wire rf=m_axi_rvalid && m_axi_rready;
    function [31:0] inc_sat;
        input [31:0] n;
        begin inc_sat=n==32'hffffffff ? n : n+1'b1; end
    endfunction
    integer i;
    always @(posedge clk) begin
        if(rst) begin
            ws<=W_IDLE;rs<=R_IDLE;wcmd<=0;rcmd<=0;wquota<=0;rquota<=0;wleft<=0;rleft<=0;
            write_owner<=0;read_owner<=0;protocol_fault<=0;
            write_grants<=0;read_grants<=0;write_completed<=0;read_completed<=0;
            write_beats<=0;read_beats<=0;write_errors<=0;read_errors<=0;
            wwait<=0;rwait<=0;write_wait_max<=0;read_wait_max<=0;
        end else begin
            if(take_w) begin
                write_owner<=wpick;
                wcmd<={s_axi_awid[wpick*ID_WIDTH +: ID_WIDTH],s_axi_awaddr[wpick*ADDR_WIDTH +: ADDR_WIDTH],
                    s_axi_awlen[wpick*8 +: 8],s_axi_awsize[wpick*3 +: 3],s_axi_awburst[wpick*2 +: 2],
                    s_axi_awlock[wpick],s_axi_awcache[wpick*4 +: 4],s_axi_awprot[wpick*3 +: 3],s_axi_awqos[wpick*4 +: 4]};
                wleft<={1'b0,s_axi_awlen[wpick*8 +: 8]}+9'd1;ws<=W_ADDR;
                if(wpick || !s_axi_awvalid[1]) wquota<=0;
                else if(wquota<VIDEO_QUOTA) wquota<=wquota+1'b1;
            end
            if(take_r) begin
                read_owner<=rpick;
                rcmd<={s_axi_arid[rpick*ID_WIDTH +: ID_WIDTH],s_axi_araddr[rpick*ADDR_WIDTH +: ADDR_WIDTH],
                    s_axi_arlen[rpick*8 +: 8],s_axi_arsize[rpick*3 +: 3],s_axi_arburst[rpick*2 +: 2],
                    s_axi_arlock[rpick],s_axi_arcache[rpick*4 +: 4],s_axi_arprot[rpick*3 +: 3],s_axi_arqos[rpick*4 +: 4]};
                rleft<={1'b0,s_axi_arlen[rpick*8 +: 8]}+9'd1;rs<=R_ADDR;
                if(rpick || !s_axi_arvalid[1]) rquota<=0;
                else if(rquota<VIDEO_QUOTA) rquota<=rquota+1'b1;
            end
            if(m_axi_awvalid && m_axi_awready) ws<=W_DATA;
            if(m_axi_arvalid && m_axi_arready) rs<=R_DATA;
            if(wf) begin
                if(m_axi_wlast!=(wleft==1)) protocol_fault[0]<=1;
                wleft<=wleft-1'b1;
                if(m_axi_wlast) ws<=W_RESP;
            end
            if(bf) begin
                ws<=W_IDLE;
                if(m_axi_bid!=m_axi_awid) protocol_fault[2]<=1;
            end
            if(rf) begin
                if(m_axi_rlast!=(rleft==1)) protocol_fault[1]<=1;
                if(m_axi_rid!=m_axi_arid) protocol_fault[3]<=1;
                rleft<=rleft-1'b1;
                if(m_axi_rlast) rs<=R_IDLE;
            end
            for(i=0;i<2;i=i+1) begin
                if(take_w && wpick==i) write_grants[i*32 +: 32]<=inc_sat(write_grants[i*32 +: 32]);
                if(take_r && rpick==i) read_grants[i*32 +: 32]<=inc_sat(read_grants[i*32 +: 32]);
                if(wf && write_owner==i) write_beats[i*32 +: 32]<=inc_sat(write_beats[i*32 +: 32]);
                if(rf && read_owner==i) read_beats[i*32 +: 32]<=inc_sat(read_beats[i*32 +: 32]);
                if(bf && write_owner==i) begin
                    write_completed[i*32 +: 32]<=inc_sat(write_completed[i*32 +: 32]);
                    if(m_axi_bresp!=0) write_errors[i*32 +: 32]<=inc_sat(write_errors[i*32 +: 32]);
                end
                if(rf && read_owner==i) begin
                    if(m_axi_rlast) read_completed[i*32 +: 32]<=inc_sat(read_completed[i*32 +: 32]);
                    if(m_axi_rresp!=0) read_errors[i*32 +: 32]<=inc_sat(read_errors[i*32 +: 32]);
                end
                if(!s_axi_awvalid[i] || s_axi_awready[i]) wwait[i*32 +: 32]<=0;
                else begin
                    wwait[i*32 +: 32]<=inc_sat(wwait[i*32 +: 32]);
                    if(inc_sat(wwait[i*32 +: 32])>write_wait_max[i*32 +: 32])
                        write_wait_max[i*32 +: 32]<=inc_sat(wwait[i*32 +: 32]);
                end
                if(!s_axi_arvalid[i] || s_axi_arready[i]) rwait[i*32 +: 32]<=0;
                else begin
                    rwait[i*32 +: 32]<=inc_sat(rwait[i*32 +: 32]);
                    if(inc_sat(rwait[i*32 +: 32])>read_wait_max[i*32 +: 32])
                        read_wait_max[i*32 +: 32]<=inc_sat(rwait[i*32 +: 32]);
                end
            end
        end
    end
    // synthesis translate_off
    initial if(VIDEO_QUOTA<1 || DATA_WIDTH%8!=0) $fatal(1,"FAIL: arbiter parameters");
    // synthesis translate_on
endmodule
