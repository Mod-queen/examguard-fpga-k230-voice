`timescale 1ns/1ps

// Stallable independent AXI client. Writes a deterministic byte-address pattern
// with partial strobes; reads verify every byte, incl untouched sentinel bytes.
module arbitration_master #(parameter CLIENT=0,N=160,CHECK_RESP=1)(
    input wire clk,rst,run,reads_enable,continuous,
    output reg writes_done,reads_done,
    output wire [3:0] awid,arid,
    output wire [29:0] awaddr,araddr,
    output wire [7:0] awlen,arlen,
    output wire [2:0] awsize,arsize,awprot,arprot,
    output wire [1:0] awburst,arburst,
    output wire awlock,arlock,
    output wire [3:0] awcache,arcache,awqos,arqos,
    output wire awvalid,arvalid,
    input wire awready,arready,
    output wire [127:0] wdata,
    output wire [15:0] wstrb,
    output wire wlast,wvalid,
    input wire wready,
    input wire [3:0] bid,rid,
    input wire [1:0] bresp,rresp,
    input wire bvalid,rvalid,rlast,
    input wire [127:0] rdata,
    output wire bready,rready
);
    reg [31:0] rng;
    reg [2:0] ws,rs;
    integer wi,ri,wb,rb,wcount,rcount;
    reg offered_w;
    wire [29:0] wbaddr=CLIENT*16384+(wi%16)*512;
    wire [29:0] rbaddr=CLIENT*16384+(ri%16)*512;
    wire [7:0] wlength=(wi%16==0) ? 0 : ((wi%16==1) ? 31 : wi%32);
    wire [7:0] rlength=(ri%16==0) ? 0 : ((ri%16==1) ? 31 : ri%32);
    assign awaddr=wbaddr;assign araddr=rbaddr;
    // Both clients intentionally use overlapping ID values, including zero.
    assign awid=wi%16;assign arid=ri%16;
    assign awlen=wlength;assign arlen=rlength;
    assign awsize=4;assign arsize=4;assign awburst=1;assign arburst=1;
    assign awlock=0;assign arlock=0;
    assign awcache=CLIENT ? 4'ha : 4'h3;assign arcache=CLIENT ? 4'h5 : 4'hc;
    assign awprot=CLIENT ? 3'd2 : 3'd1;assign arprot=CLIENT ? 3'd3 : 3'd4;
    assign awqos=CLIENT ? 4'd1 : 4'd9;assign arqos=CLIENT ? 4'd2 : 4'd8;
    assign awvalid=!rst && run && (ws==0 || ws==1) && wi<N;
    assign arvalid=!rst && run && reads_enable && (rs==0 || rs==1) && ri<N;
    // Offer W BEFORE AW too. Arbiter must accept it only after its own AW.
    assign wvalid=!rst && run && offered_w && (ws<3) && wi<N;
    assign wlast=wb==wlength;
    assign wstrb=16'h7f7f; // bytes7/15 stay untouched across all writes
    function [127:0] pattern;
        input integer address;
        integer k;
        begin for(k=0;k<16;k=k+1) pattern[k*8 +: 8]=(address+k)^((address+k)>>8)^8'h3c;end
    endfunction
    assign wdata=pattern(wbaddr+wb*16);
    assign bready=!rst && run && ws==3 && (continuous || rng[1]);
    assign rready=!rst && run && rs==2 && (continuous || rng[3]);
    always @(negedge clk) begin
        rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
        if(!rst && run && !offered_w && ws<3 && wi<N && (continuous || rng[0])) offered_w<=1;
    end
    integer k;
    reg [127:0] expected;
    always @(posedge clk) begin
        if(rst) begin
            ws<=0;rs<=0;wi<=0;ri<=0;wb<=0;rb<=0;wcount<=0;rcount<=0;
            writes_done<=0;reads_done<=0;offered_w<=0;rng<=32'h62b25a9d+CLIENT;
        end else if(run) begin
            if(awvalid && awready) ws<=2;
            if(wvalid && wready) begin
                if(ws!=2) $fatal(1,"FAIL: accepted W before client AW");
                offered_w<=0;wcount<=wcount+1;
                if(wlast) begin ws<=3;wb<=0;end else wb<=wb+1;
            end
            if(bvalid && bready) begin
                if(bid!==awid || bresp!==((CHECK_RESP && wbaddr[9]) ? 2'b10 : 2'b00))
                    $fatal(1,"FAIL: B response wrong owner/id/status client=%d",CLIENT);
                wi<=wi+1;ws<=0;
                if(wi==N-1) writes_done<=1;
            end
            if(arvalid && arready) begin rs<=2;rb<=0;end
            if(rvalid && rready) begin
                expected=pattern(rbaddr+rb*16);
                expected[7*8 +: 8]=8'ha5;expected[15*8 +: 8]=8'ha5;
                if(rid!==arid || rdata!==expected || rlast!==(rb==rlength) ||
                    rresp!==((CHECK_RESP && rbaddr[10]) ? 2'b10 : 2'b00))
                    $fatal(1,"FAIL: read data/ID/response client=%d burst=%d beat=%d data=%h expected=%h",CLIENT,ri,rb,rdata,expected);
                rcount<=rcount+1;
                if(rlast) begin ri<=ri+1;rs<=0;end else rb<=rb+1;
                if(rlast && ri==N-1) reads_done<=1;
            end
        end
    end
endmodule

module arbiter_case #(parameter QUOTA=3)(output reg passed=0);
    reg clk=0,rst=1,run=0,reads_enable=0,continuous=0;
    always #5 clk=~clk;
    `include "axi_frame_tb_wires.vh"
    `include "axi_2client_tb_wires.vh"
    axi_2client_arbiter #(.VIDEO_QUOTA(QUOTA)) dut(.*);
    wire hold_b=0,inject_b=m_axi_awaddr[9],inject_r=m_axi_araddr[10];
    axi_frame_slave_model memory(.*);
    wire [1:0] writes_done,reads_done;
    genvar c;
    generate for(c=0;c<2;c=c+1) begin: masters
        arbitration_master #(.CLIENT(c)) source (
            .clk(clk),.rst(rst),.run(run),.reads_enable(reads_enable),.continuous(continuous),
            .writes_done(writes_done[c]),.reads_done(reads_done[c]),
            .awid(s_axi_awid[c*4 +: 4]),.awaddr(s_axi_awaddr[c*30 +: 30]),.awlen(s_axi_awlen[c*8 +: 8]),
            .awsize(s_axi_awsize[c*3 +: 3]),.awburst(s_axi_awburst[c*2 +: 2]),.awlock(s_axi_awlock[c]),
            .awcache(s_axi_awcache[c*4 +: 4]),.awprot(s_axi_awprot[c*3 +: 3]),.awqos(s_axi_awqos[c*4 +: 4]),
            .awvalid(s_axi_awvalid[c]),.awready(s_axi_awready[c]),
            .wdata(s_axi_wdata[c*128 +: 128]),.wstrb(s_axi_wstrb[c*16 +: 16]),
            .wlast(s_axi_wlast[c]),.wvalid(s_axi_wvalid[c]),.wready(s_axi_wready[c]),
            .bid(s_axi_bid[c*4 +: 4]),.bresp(s_axi_bresp[c*2 +: 2]),.bvalid(s_axi_bvalid[c]),.bready(s_axi_bready[c]),
            .arid(s_axi_arid[c*4 +: 4]),.araddr(s_axi_araddr[c*30 +: 30]),.arlen(s_axi_arlen[c*8 +: 8]),
            .arsize(s_axi_arsize[c*3 +: 3]),.arburst(s_axi_arburst[c*2 +: 2]),.arlock(s_axi_arlock[c]),
            .arcache(s_axi_arcache[c*4 +: 4]),.arprot(s_axi_arprot[c*3 +: 3]),.arqos(s_axi_arqos[c*4 +: 4]),
            .arvalid(s_axi_arvalid[c]),.arready(s_axi_arready[c]),
            .rid(s_axi_rid[c*4 +: 4]),.rdata(s_axi_rdata[c*128 +: 128]),.rresp(s_axi_rresp[c*2 +: 2]),
            .rlast(s_axi_rlast[c]),.rvalid(s_axi_rvalid[c]),.rready(s_axi_rready[c]));
    end endgenerate
    reg [58:0] expected_aw,expected_ar,held_aw,held_ar;
    reg [144:0] held_w;
    reg [134:0] held_r;
    reg [5:0] held_b;
    reg aw_pending=0,ar_pending=0,aw_stall=0,ar_stall=0,w_stall=0,b_stall=0,r_stall=0;
    integer wg0=0,wg1=0,rg0=0,rg1=0,wc0=0,wc1=0,rc0=0,rc1=0;
    integer wv=0,rv=0,wr_overlap=0,k,w_owner_expected=0,r_owner_expected=0;
    integer aw_stalls=0,w_stalls=0,ar_stalls=0,b_stalls=0,r_stalls=0;
    // Independent transaction ownership scoreboard. Client address admission
    // and downstream address may be separated by many stalled cycles.
    always @(posedge clk) begin
        if(rst) begin
            aw_pending=0;ar_pending=0;aw_stall=0;ar_stall=0;w_stall=0;b_stall=0;r_stall=0;
            wg0=0;wg1=0;rg0=0;rg1=0;wc0=0;wc1=0;rc0=0;rc1=0;wv=0;rv=0;
        end else begin
            if(aw_stall && (!m_axi_awvalid || {m_axi_awid,m_axi_awaddr,m_axi_awlen,m_axi_awsize,m_axi_awburst,
                m_axi_awlock,m_axi_awcache,m_axi_awprot,m_axi_awqos}!==held_aw)) $fatal(1,"FAIL: AW attributes unstable");
            if(ar_stall && (!m_axi_arvalid || {m_axi_arid,m_axi_araddr,m_axi_arlen,m_axi_arsize,m_axi_arburst,
                m_axi_arlock,m_axi_arcache,m_axi_arprot,m_axi_arqos}!==held_ar)) $fatal(1,"FAIL: AR attributes unstable");
            if(w_stall && (!m_axi_wvalid || {m_axi_wdata,m_axi_wstrb,m_axi_wlast}!==held_w)) $fatal(1,"FAIL: W unstable");
            if(b_stall && ({m_axi_bid,m_axi_bresp}!==held_b || !s_axi_bvalid[w_owner_expected])) $fatal(1,"FAIL: stalled B owner");
            if(r_stall && ({m_axi_rid,m_axi_rdata,m_axi_rresp,m_axi_rlast}!==held_r || !s_axi_rvalid[r_owner_expected]))
                $fatal(1,"FAIL: stalled R owner");
            if(s_axi_awready==3 || s_axi_arready==3 || s_axi_bvalid==3 || s_axi_rvalid==3)
                $fatal(1,"FAIL: broadcast handshake");
            for(k=0;k<2;k=k+1) begin
                if(s_axi_awvalid[k] && s_axi_awready[k]) begin
                    if(aw_pending) $fatal(1,"FAIL: AW overbook");aw_pending=1;w_owner_expected=k;
                    expected_aw={s_axi_awid[k*4 +: 4],s_axi_awaddr[k*30 +: 30],s_axi_awlen[k*8 +: 8],s_axi_awsize[k*3 +: 3],
                        s_axi_awburst[k*2 +: 2],s_axi_awlock[k],s_axi_awcache[k*4 +: 4],s_axi_awprot[k*3 +: 3],s_axi_awqos[k*4 +: 4]};
                    if(k==0) wg0=wg0+1;else wg1=wg1+1;
                    if(s_axi_awvalid==3) begin
                        if(k==0) wv=wv+1;else wv=0;
                        if(wv>QUOTA) $fatal(1,"FAIL: evidence write starvation");
                    end else wv=0;
                end
                if(s_axi_arvalid[k] && s_axi_arready[k]) begin
                    if(ar_pending) $fatal(1,"FAIL: AR overbook");ar_pending=1;r_owner_expected=k;
                    expected_ar={s_axi_arid[k*4 +: 4],s_axi_araddr[k*30 +: 30],s_axi_arlen[k*8 +: 8],s_axi_arsize[k*3 +: 3],
                        s_axi_arburst[k*2 +: 2],s_axi_arlock[k],s_axi_arcache[k*4 +: 4],s_axi_arprot[k*3 +: 3],s_axi_arqos[k*4 +: 4]};
                    if(k==0) rg0=rg0+1;else rg1=rg1+1;
                    if(s_axi_arvalid==3) begin
                        if(k==0) rv=rv+1;else rv=0;
                        if(rv>QUOTA) $fatal(1,"FAIL: evidence read starvation");
                    end else rv=0;
                end
            end
            if(m_axi_awvalid && m_axi_awready && (!aw_pending ||
                {m_axi_awid,m_axi_awaddr,m_axi_awlen,m_axi_awsize,m_axi_awburst,m_axi_awlock,m_axi_awcache,m_axi_awprot,m_axi_awqos}!==expected_aw))
                $fatal(1,"FAIL: AW command not the admitted client's");
            if(m_axi_arvalid && m_axi_arready && (!ar_pending ||
                {m_axi_arid,m_axi_araddr,m_axi_arlen,m_axi_arsize,m_axi_arburst,m_axi_arlock,m_axi_arcache,m_axi_arprot,m_axi_arqos}!==expected_ar))
                $fatal(1,"FAIL: AR command not the admitted client's");
            if(m_axi_wvalid && m_axi_wready && !s_axi_wready[w_owner_expected]) $fatal(1,"FAIL: W owner");
            if(m_axi_bvalid && m_axi_bready) begin
                if(!s_axi_bvalid[w_owner_expected]) $fatal(1,"FAIL: B owner");aw_pending=0;
                if(w_owner_expected==0) wc0=wc0+1;else wc1=wc1+1;
            end
            if(m_axi_rvalid && m_axi_rready && m_axi_rlast) begin
                if(!s_axi_rvalid[r_owner_expected]) $fatal(1,"FAIL: R owner");ar_pending=0;
                if(r_owner_expected==0) rc0=rc0+1;else rc1=rc1+1;
            end
            aw_stall=m_axi_awvalid && !m_axi_awready;ar_stall=m_axi_arvalid && !m_axi_arready;
            w_stall=m_axi_wvalid && !m_axi_wready;b_stall=m_axi_bvalid && !m_axi_bready;r_stall=m_axi_rvalid && !m_axi_rready;
            held_aw={m_axi_awid,m_axi_awaddr,m_axi_awlen,m_axi_awsize,m_axi_awburst,m_axi_awlock,m_axi_awcache,m_axi_awprot,m_axi_awqos};
            held_ar={m_axi_arid,m_axi_araddr,m_axi_arlen,m_axi_arsize,m_axi_arburst,m_axi_arlock,m_axi_arcache,m_axi_arprot,m_axi_arqos};
            held_w={m_axi_wdata,m_axi_wstrb,m_axi_wlast};held_b={m_axi_bid,m_axi_bresp};held_r={m_axi_rid,m_axi_rdata,m_axi_rresp,m_axi_rlast};
            if(aw_stall) aw_stalls=aw_stalls+1;if(ar_stall) ar_stalls=ar_stalls+1;
            if(w_stall) w_stalls=w_stalls+1;if(b_stall) b_stalls=b_stalls+1;if(r_stall) r_stalls=r_stalls+1;
            if(write_busy && read_busy) wr_overlap=wr_overlap+1;
        end
    end
    initial begin
        repeat(6) @(negedge clk);rst=0;run=1;
        // Reset with live ownership, then restart both clients AND slave.
        wait(m_axi_wvalid);@(negedge clk);rst=1;
        repeat(5) @(negedge clk);rst=0;
        wait(&writes_done);reads_enable=1;
        wait(&reads_done);repeat(5) @(negedge clk);
        if(protocol_fault || write_grants!=={32'd160,32'd160} || read_grants!=={32'd160,32'd160} ||
            write_completed!==write_grants || read_completed!==read_grants ||
            write_beats[31:0]!=masters[0].source.wcount || write_beats[63:32]!=masters[1].source.wcount ||
            read_beats[31:0]!=masters[0].source.rcount || read_beats[63:32]!=masters[1].source.rcount ||
            !write_errors[31:0] || !write_errors[63:32] || !read_errors[31:0] || !read_errors[63:32] ||
            !aw_stalls || !w_stalls || !ar_stalls || !b_stalls || !r_stalls)
            $fatal(1,"FAIL: arbiter counters/coverage quota=%d",QUOTA);
        $display("arbiter quota=%0d W/R bursts=%0d/%0d beats=%0d/%0d stalls AW/W/B/AR/R=%0d/%0d/%0d/%0d/%0d",
            QUOTA,wc0+wc1,rc0+rc1,write_beats[31:0]+write_beats[63:32],read_beats[31:0]+read_beats[63:32],
            aw_stalls,w_stalls,b_stalls,ar_stalls,r_stalls);
        passed=1;
    end
endmodule
module axi_2client_arbiter_tb;
    wire a,b;
    arbiter_case #(.QUOTA(1)) equal_share(a);
    arbiter_case #(.QUOTA(3)) video_weighted(b);
    initial begin wait(a&&b);$display("PASS: axi_2client_arbiter all checks");$finish;end
    initial begin #10000000;$fatal(1,"FAIL: arbiter timeout");end
endmodule
