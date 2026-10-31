`timescale 1ns/1ps
module persistent_config_decode_tb;
    reg [255:0] config_data;
    wire valid,legacy_defaults,rtc_offset_known,mute;
    wire [31:0] seat_id;wire [15:0] exam_duration_s;wire signed [15:0] rtc_offset_minutes;
    reg [339:0] vectors[0:316];
    reg [82:0] expected;integer i;
    persistent_config_decode dut(.*);
    initial begin
        $readmemh("persistent_config_vectors_20261021.mem",vectors);
        for(i=0;i<317;i=i+1) begin
            config_data=vectors[i][339:84];expected=vectors[i][82:0];#1;
            if(valid!==expected[82]) $fatal(1,"FAIL: config validity index=%0d",i);
            if(valid && {legacy_defaults,mute,seat_id,exam_duration_s,15'd0,rtc_offset_known,rtc_offset_minutes}
                !==expected[81:0]) $fatal(1,"FAIL: config fields index=%0d",i);
        end
        $display("PASS: persistent_config_decode 317 host vectors/defaults/boundaries/single-bit-reserved");$finish;
    end
endmodule
