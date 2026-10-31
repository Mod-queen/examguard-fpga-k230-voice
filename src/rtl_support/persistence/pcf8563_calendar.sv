`timescale 1ns/1ps
// Decode a single burst of registers 00..08, byte0 at raw[7:0].
// Frozen application date range: 2000..2099, century C=0 per supplied manual.
// Never clear VL or STOP implicitly; bad data remains explicitly untrusted.
module pcf8563_calendar(
    input wire [71:0] raw,
    output wire valid,
    output wire voltage_low,stopped,unsupported_century,
    output wire [15:0] year,
    output wire [7:0] month,day,hour,minute,second,
    output wire [2:0] weekday
);
    wire [7:0] sec_bcd=raw[23:16]&8'h7f,min_bcd=raw[31:24]&8'h7f;
    wire [7:0] hour_bcd=raw[39:32]&8'h3f,day_bcd=raw[47:40]&8'h3f;
    wire [7:0] month_bcd=raw[63:56]&8'h1f,year_bcd=raw[71:64];
    function automatic bcd_ok(input [7:0] b);
        bcd_ok=b[3:0]<=9 && b[7:4]<=9;
    endfunction
    function automatic [7:0] unbcd(input [7:0] b);
        unbcd=b[7:4]*8'd10+b[3:0];
    endfunction
    assign second=unbcd(sec_bcd);assign minute=unbcd(min_bcd);assign hour=unbcd(hour_bcd);
    assign day=unbcd(day_bcd);assign month=unbcd(month_bcd);assign year=16'd2000+unbcd(year_bcd);
    assign weekday=raw[50:48];
    assign voltage_low=raw[23];assign stopped=raw[5];assign unsupported_century=raw[63];
    wire leap=unbcd(year_bcd)%4==0;
    wire [7:0] days_in_month=month==2 ? (leap ? 29 : 28) :
        (month==4 || month==6 || month==9 || month==11) ? 30 : 31;
    assign valid=!voltage_low && !stopped && !unsupported_century && !raw[7] && !raw[3] &&
        bcd_ok(sec_bcd) && bcd_ok(min_bcd) && bcd_ok(hour_bcd) && bcd_ok(day_bcd) &&
        bcd_ok(month_bcd) && bcd_ok(year_bcd) && second<60 && minute<60 && hour<24 &&
        month>=1 && month<=12 && day>=1 && day<=days_in_month && weekday<=6;
endmodule
