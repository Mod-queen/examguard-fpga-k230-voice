`timescale 1ns/1ps
// Schema for config256 stored inside the already CRC-protected EEPROM record.
// No state/application here: caller latches at boot/maintenance, never mid-exam.
module persistent_config_decode(
    input wire [255:0] config_data,
    output wire valid,legacy_defaults,
    output wire [31:0] seat_id,
    output wire [15:0] exam_duration_s,
    output wire rtc_offset_known,output wire signed [15:0] rtc_offset_minutes,
    output wire mute
);
    assign legacy_defaults=config_data==0;
    wire signed [15:0] offset=config_data[127:112];
    wire profile_valid=config_data[63:0]==64'h0000200131504745 &&
        config_data[255:129]==0 && config_data[95:64]!=0 &&
        config_data[111:96]>=60 && config_data[111:96]<=7200 &&
        (offset==16'sh7fff || (offset>=-16'sd720 && offset<=16'sd840));
    assign valid=legacy_defaults || profile_valid;
    // Invalid input is flagged; benign outputs must not be mistaken for valid.
    assign seat_id=profile_valid?config_data[95:64]:32'd1;
    assign exam_duration_s=profile_valid?config_data[111:96]:16'd2700;
    assign rtc_offset_known=profile_valid && offset!=16'sh7fff;
    assign rtc_offset_minutes=rtc_offset_known?offset:16'sd0;
    assign mute=profile_valid && config_data[128];
endmodule
