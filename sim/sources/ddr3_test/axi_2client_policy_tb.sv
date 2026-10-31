`timescale 1ns/1ps

// Saturated request streams isolate the weighted policy from master gaps.
// This slave also accepts AW/AR only after long pauses, then deliberately
// returns wrong IDs and early LAST in a separate common-reset epoch.
module policy_case #(parameter Q=3)(output reg passed=0);
    reg clk=0,rst=1,traffic=0,bad=0,pause_w=0,pause_r=0,accept_b=1,accept_r=1;
    always #5 clk=~clk;
    `include "axi_frame_tb_wires.vh"
    `include "axi_2client_tb_wires.vh"
    assign s_axi_awid=0;assign s_axi_arid=0;
    assign s_axi_awaddr={30'd16384,30'd0};assign s_axi_araddr={30'd16384,30'd0};
    assign s_axi_awlen=bad ? 16'h0101 : 0;assign s_axi_arlen=bad ? 16'h0101 : 0;
    assign s_axi_awsize={3'd4,3'd4};assign s_axi_arsize={3'd4,3'd4};
    assign s_axi_awburst={2'd1,2'd1};assign s_axi_arburst={2'd1,2'd1};
    assign s_axi_awlock=0;assign s_axi_arlock=0;
    assign s_axi_awcache=0;assign s_axi_arcache=0;
    assign s_axi_awprot=0;assign s_axi_arprot=0;assign s_axi_awqos=0;assign s_axi_arqos=0;
    assign s_axi_awvalid=traffic ? 2'b11 : 0;assign s_axi_arvalid=traffic ? 2'b11 : 0;
    assign s_axi_wdata={128'h1111,128'h0000};assign s_axi_wstrb=32'hffffffff;
    assign s_axi_wlast=3;assign s_axi_wvalid=3;
    assign s_axi_bready=accept_b ? 3 : 0;assign s_axi_rready=accept_r ? 3 : 0;
    reg wopen=0,bopen=0,ropen=0;
    reg [3:0] wid=0,rid=0;
    assign m_axi_awready=!rst && !pause_w && !wopen && !bopen;
    assign m_axi_wready=!rst && !pause_w && wopen;
    assign m_axi_bid=bad ? 4'hf : wid;
    assign m_axi_bresp=0;assign m_axi_bvalid=!rst && bopen;
    assign m_axi_arready=!rst && !pause_r && !ropen;
    assign m_axi_rid=bad ? 4'he : rid;
    assign m_axi_rdata=0;assign m_axi_rresp=0;
    assign m_axi_rlast=1;assign m_axi_rvalid=!rst && !pause_r && ropen;
    axi_2client_arbiter #(.VIDEO_QUOTA(Q)) dut(.*);
    integer wg=0,rg=0,wu=0,ru=0,expected;
    reg check_sequence=1;
    always @(posedge clk) begin
        if(rst) begin wopen<=0;bopen<=0;ropen<=0;wg=0;rg=0;wu=0;ru=0;end
        else begin
            if(m_axi_awvalid && m_axi_awready) begin wopen<=1;wid<=m_axi_awid;end
            if(m_axi_wvalid && m_axi_wready && m_axi_wlast) begin wopen<=0;bopen<=1;end
            if(m_axi_bvalid && m_axi_bready) bopen<=0;
            if(m_axi_arvalid && m_axi_arready) begin ropen<=1;rid<=m_axi_arid;end
            if(m_axi_rvalid && m_axi_rready && m_axi_rlast) ropen<=0;
            if(check_sequence && |s_axi_awready) begin
                expected=wg%(Q+1)==Q;
                if(s_axi_awready!==(expected ? 2'b10 : 2'b01)) $fatal(1,"FAIL: saturated weighted write policy Q=%d grant=%d",Q,wg);
                wg=wg+1;
            end
            if(check_sequence && |s_axi_arready) begin
                expected=rg%(Q+1)==Q;
                if(s_axi_arready!==(expected ? 2'b10 : 2'b01)) $fatal(1,"FAIL: saturated weighted read policy Q=%d grant=%d",Q,rg);
                rg=rg+1;
            end
            if(m_axi_bvalid && m_axi_bready) wu=wu+1;
            if(m_axi_rvalid && m_axi_rready && m_axi_rlast) ru=ru+1;
        end
    end
    task reset_epoch;
        begin
            @(negedge clk);rst=1;traffic=0;
            repeat(3) @(negedge clk);rst=0;
        end
    endtask
    initial begin
        repeat(6) @(negedge clk);rst=0;traffic=1;
        wait(wg>=100 && rg>=100);@(negedge clk);traffic=0;
        wait(!write_busy && !read_busy);
        if(protocol_fault) $fatal(1,"FAIL: legal saturated traffic fault");
        // Independent directions: indefinitely paused write must not stop read.
        check_sequence=0;reset_epoch();pause_w=1;traffic=1;
        repeat(160) @(negedge clk);
        if(wu!=0 || ru<20 || !write_busy) $fatal(1,"FAIL: read blocked by stalled write");
        reset_epoch();pause_w=0;pause_r=1;traffic=1;
        repeat(160) @(negedge clk);
        if(ru!=0 || wu<15 || !read_busy) $fatal(1,"FAIL: write blocked by stalled read");
        // Response backpressure must retain ownership, not grant another burst.
        reset_epoch();pause_r=0;accept_b=0;accept_r=0;traffic=1;
        wait(m_axi_bvalid && m_axi_rvalid);
        repeat(50) begin
            @(negedge clk);
            if(s_axi_awready || s_axi_arready || !write_busy || !read_busy)
                $fatal(1,"FAIL: ownership released before B/RLAST handshake");
        end
        // Common reset cancels both stalled responses and owners.
        reset_epoch();
        if(s_axi_bvalid || s_axi_rvalid || protocol_fault || write_busy || read_busy)
            $fatal(1,"FAIL: stale response across reset");
        accept_b=1;accept_r=1;bad=1;traffic=1;
        wait(protocol_fault==4'hf);@(negedge clk);traffic=0;
        wait(!write_busy && !read_busy);
        repeat(6) @(negedge clk);
        if(protocol_fault!=15) $fatal(1,"FAIL: protocol faults not sticky");
        // Seed saturating counters then exercise the actual handshake paths.
        reset_epoch();bad=0;
        @(negedge clk);
        dut.write_grants=64'hffffffffffffffff;dut.read_grants=64'hffffffffffffffff;
        dut.write_completed=64'hffffffffffffffff;dut.read_completed=64'hffffffffffffffff;
        dut.write_beats=64'hffffffffffffffff;dut.read_beats=64'hffffffffffffffff;
        dut.write_wait_max=64'hffffffffffffffff;dut.read_wait_max=64'hffffffffffffffff;
        traffic=1;repeat(70) @(negedge clk);traffic=0;wait(!write_busy && !read_busy);@(negedge clk);
        if(write_grants!==64'hffffffffffffffff || read_grants!==64'hffffffffffffffff ||
            write_completed!==64'hffffffffffffffff || read_completed!==64'hffffffffffffffff ||
            write_beats!==64'hffffffffffffffff || read_beats!==64'hffffffffffffffff ||
            write_wait_max!==64'hffffffffffffffff || read_wait_max!==64'hffffffffffffffff)
            $fatal(1,"FAIL: arbiter counter saturation");
        $display("arbiter policy Q=%0d saturated grants>=100, independent directions, stalled responses/reset, fault flags, saturation PASS",Q);
        passed=1;
    end
endmodule
module axi_2client_policy_tb;
    wire a,b;
    policy_case #(.Q(1)) round_robin(a);
    policy_case #(.Q(3)) weighted(b);
    initial begin wait(a&&b);$display("PASS: axi_2client_policy all checks");$finish;end
    initial begin #1000000;$fatal(1,"FAIL: policy timeout");end
endmodule
