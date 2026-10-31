`timescale 1ns/1ps
module pcf8563_calendar_tb;
    reg [71:0] raw=0;
    wire valid,voltage_low,stopped,unsupported_century;
    wire [15:0] year;wire [7:0] month,day,hour,minute,second;wire [2:0] weekday;
    pcf8563_calendar dut(.*);
    integer yy,mm,dd,maxday,checks=0;
    function [7:0] bcd(input integer n);bcd=((n/10)<<4)|(n%10);endfunction
    task automatic check_date(input integer ok);
        begin #1;if(valid!==1'(ok)) $fatal(1,"FAIL: PCF calendar raw=%h valid=%0d expected=%0d",raw,valid,ok);checks=checks+1;end
    endtask
    initial begin
        // Every real day across the full supported 100 year range, plus invalid
        // month ends. Independent loop calendar oracle, not DUT next-date logic.
        for(yy=0;yy<100;yy=yy+1) for(mm=1;mm<=12;mm=mm+1) begin
            case(mm)
                2:maxday=yy%4==0?29:28;
                4,6,9,11:maxday=30;
                default:maxday=31;
            endcase
            for(dd=1;dd<=maxday+1;dd=dd+1) begin
                raw={bcd(yy),bcd(mm),8'd1,bcd(dd),8'h23,8'h59,8'h59,16'd0};
                check_date(dd<=maxday);
                if(dd<=maxday && (year!=2000+yy || month!=mm || day!=dd || hour!=23 || minute!=59 || second!=59 || weekday!=1))
                    $fatal(1,"FAIL: decoded calendar fields");
            end
        end
        raw={8'h26,8'h10,8'd1,8'h19,8'h12,8'h34,8'h56,16'd0};check_date(1);
        raw[23]=1;check_date(0);raw[23]=0;raw[5]=1;check_date(0);raw[5]=0;
        raw[63]=1;check_date(0);raw[63]=0;raw[7]=1;check_date(0);raw[7]=0;
        raw[3]=1;check_date(0);raw[3]=0;
        raw[23:16]=8'h6a;check_date(0);raw[23:16]=8'h60;check_date(0);raw[23:16]=0;
        raw[31:24]=8'h60;check_date(0);raw[31:24]=0;raw[39:32]=8'h24;check_date(0);raw[39:32]=0;
        raw[55:48]=7;check_date(0);raw[55:48]=0;
        raw[63:56]=0;check_date(0);raw[63:56]=8'h13;check_date(0);
        raw[63:56]=8'h12;raw[47:40]=0;check_date(0);
        $display("PASS: pcf8563_calendar checks=%0d full2000..2099/leap/month-end/BCD/VL/STOP/test/century",checks);$finish;
    end
endmodule
