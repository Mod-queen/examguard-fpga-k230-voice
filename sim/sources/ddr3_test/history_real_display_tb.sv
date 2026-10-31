`timescale 1ns/1ps
// Real disp_driver 1280x720 timing + color_enhance + history sampler/source.
// Checks whether the actual display coordinate/SOF pipeline produces complete
// 320x180 sample frames or index/LAST drops.
module history_real_display_tb;
    reg clk=0,rst=1,src_rst=1;
    always #6.734 clk=~clk; // ~74.25 MHz
    wire [11:0] x,y;
    wire [7:0] dr,dg,db;
    wire de,sof,vs,hs,pclk,req;
    disp_driver #(.AHEAD_CLK_CNT(1)) disp(
        .ClkDisp(clk),.Rst_n(!rst),.Data(24'habcdef),.DataReq(req),
        .H_Addr(x),.V_Addr(y),.Disp_Sof(sof),.Disp_HS(hs),.Disp_VS(vs),
        .Disp_Red(dr),.Disp_Green(dg),.Disp_Blue(db),.Disp_DE(de),.Disp_PCLK(pclk));
    wire [7:0] er,eg,eb;
    wire [11:0] ex,ey;
    wire ede,esof;
    color_enhance #(.SAT(320)) enh(.clk(clk),.rst(rst),.pixel_r(dr),.pixel_g(dg),.pixel_b(db),
        .x(x),.y(y),.de(de),.sof(sof),.enh_r(er),.enh_g(eg),.enh_b(eb),
        .enh_x(ex),.enh_y(ey),.enh_de(ede),.enh_sof(esof));
    reg [63:0] time_ms=0;
    always @(negedge clk) if(!rst && esof) time_ms<=time_ms+1'b1;
    wire cmd_valid,cmd_ready,pix_valid,pix_ready,pix_last;
    wire [1:0] cmd_kind;
    wire [95:0] cmd_meta;
    wire [7:0] cmd_reason;
    wire [15:0] pix_data;
    wire halted;
    wire [2:0] halt_reason;
    wire [4:0] occupancy;
    wire [1:0] banks;
    wire [31:0] seen,published,dropped,decisions;
    assign cmd_ready=1'b1;
    assign pix_ready=1'b1;
    history_sample_source #(.SRC_WIDTH(1280),.SRC_HEIGHT(720),.SAMPLE_STRIDE(4),.FRAME_INTERVAL(1),.DEPTH(8)) dut(
        .clk(clk),.rst(src_rst),.enable(1'b1),.pixel_r(er),.pixel_g(eg),.pixel_b(eb),
        .x(ex-12'd2),.y(ey-12'd2),.de(ede),.sof(esof),.frame_id(32'd0),.time_ms(time_ms),.time_valid(1'b1),.age_cycles(32'd0),
        .command_valid(cmd_valid),.command_ready(cmd_ready),.command_kind(cmd_kind),.command_meta(cmd_meta),
        .command_reason(cmd_reason),.pixel_valid(pix_valid),.pixel_ready(pix_ready),.pixel_last(pix_last),
        .pixel_data(pix_data),.halted(halted),.halt_reason(halt_reason),.occupancy(occupancy),
        .banks_occupied(banks),.frames_seen(seen),.frames_published(published),.frames_dropped(dropped),
        .decisions_sent(decisions),.source_sofs(),.cadence_skipped(),.time_unknown(),.time_stale());
    integer frames=0;
    integer dbg_samples=0;
    always @(posedge clk) if(!src_rst && dut.sample_valid && dbg_samples<12) begin
        $display("SAMPLE idx=%0d x=%0d y=%0d last=%0d",dut.sample_index,ex,ey,dut.sample_last);
        dbg_samples=dbg_samples+1;
    end
    always @(posedge clk) if(!src_rst && cmd_valid && cmd_ready) $display("CMD kind=%0d reason=%0d meta=%h time=%0t",cmd_kind,cmd_reason,cmd_meta,$time);
    always @(posedge clk) if(!src_rst && pix_valid && pix_ready && pix_last) $display("PIXLAST time=%0t",$time);
    always @(posedge clk) if(!rst && cmd_valid && cmd_ready && cmd_kind==0) frames=frames+1;
    initial begin
        repeat(4) @(negedge clk);rst=0; #20000000 src_rst=0;
        wait(published>=1 || seen>=3 || halted);
        repeat(20) @(negedge clk);
        $display("REAL_DISPLAY published=%0d dropped=%0d seen=%0d decisions=%0d halted=%0d halt_reason=%0d frames=%0d x=%0d y=%0d de=%0d sof=%0d",
            published,dropped,seen,decisions,halted,halt_reason,frames,ex,ey,ede,esof);
        if(halted || dropped!=0 || published<1) $fatal(1,"FAIL: real display sampler did not produce complete frames");
        $display("PASS: history_real_display 1280x720 disp_driver/color_enhance/sampler");
        $finish;
    end
    initial begin #60000000; $display("DBG2 halted=%0d reason=%0d seen=%0d pub=%0d drop=%b occ=%0d banks=%0d state=%0d count=%0d capidx=%0d nextidx=%0d svalid=%0d slast=%0d sidx=%0d x=%0d y=%0d de=%0d sof=%0d", halted,halt_reason,seen,published,dropped,occupancy,banks,dut.source.state,dut.source.count,dut.source.capture_index,dut.source.next_index,dut.sample_valid,dut.sample_last,dut.sample_index,ex,ey,ede,esof); $fatal(1,"FAIL: real display timeout published%0d dropped%0d seen%0d",published,dropped,seen);end
endmodule







