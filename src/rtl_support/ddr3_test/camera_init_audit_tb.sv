`timescale 1ns/1ps
// Read-only audit of the real initialization controller and RGB ROM.
// SCCB transport is a TEST-ONLY acknowledgement model, not sensor verification.
module camera_init_audit_tb;
    reg clk=0, rst_n=0;
    always #10 clk=~clk;
    wire done;
    wire scl;
    tri sda;
    camera_init #(.IMAGE_WIDTH(1280),.IMAGE_HEIGHT(720)) dut(
        .Clk(clk),.Rst_n(rst_n),.Init_Done(done),.camera_rst_n(),
        .camera_pwdn(),.i2c_sclk(scl),.i2c_sdat(sda));
    integer writes=0;
    reg saw_polarity=0;
    reg [23:0] last_write;
    always @(posedge clk) begin
        if (rst_n && dut.wrreg_req && !dut.i2c_control.busy) begin
            writes=writes+1;
            last_write={dut.addr,dut.wrdata};
            if (dut.addr==16'h4740) saw_polarity=1;
            if (dut.cnt==208 && last_write!==24'h303521)
                $fatal(1,"FAIL: PLL system divider transaction");
            if (dut.cnt==246 && last_write!==24'h460c20)
                $fatal(1,"FAIL: automatic PCLK transaction");
            $display("CAMERA_WRITE index=%0d address=%04h value=%02h",dut.cnt,dut.addr,dut.wrdata);
        end
    end
    initial begin
        repeat(4) @(negedge clk);
        rst_n=1;
        // Skip only the 21ms power-up delay. Exercise all actual ROM/FSM writes.
        force dut.delay_cnt=21'h1007ff;
        @(negedge clk);
        release dut.delay_cnt;
        wait(done);
        repeat(30) @(negedge clk);
        if (writes!=267 || last_write!==24'h474020 || !saw_polarity)
            $fatal(1,"FAIL: unexpected init boundary writes=%0d last=%06h polarity=%0d",writes,last_write,saw_polarity);
        $display("PASS: camera_init_audit actual indices0..266; final polarity write executed; no sensor timing claim");
        $finish;
    end
    initial begin #1000000; $fatal(1,"FAIL: camera init audit timeout"); end
endmodule

// TEST ONLY: ack=0 means success, matching the real controller contract.
module i2c_control(
    input Clk,Rst_n,wrreg_req,rdreg_req,addr_mode,
    input [15:0] addr,
    input [7:0] wrdata,device_id,
    input [31:0] dly_cnt_max,
    output [7:0] rddata,
    output reg RW_Done,
    output ack,i2c_sclk,
    inout i2c_sdat);
    reg busy;
    reg [2:0] countdown;
    assign rddata=0;
    assign ack=0;
    assign i2c_sclk=1;
    assign i2c_sdat=1'bz;
    always @(posedge Clk) begin
        if (!Rst_n) begin busy<=0;countdown<=0;RW_Done<=0;end
        else begin
            RW_Done<=0;
            if (wrreg_req && !busy) begin busy<=1;countdown<=3;end
            else if (busy) begin
                if (countdown==0) begin busy<=0;RW_Done<=1;end
                else countdown<=countdown-1'b1;
            end
        end
    end
endmodule
