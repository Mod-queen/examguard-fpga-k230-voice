`timescale 1ns/1ps

// UI-domain, one buffered chunk at a time. EG v2 packets preserve the ENTIRE
// event transaction and 96-bit source frame metadata. Pixels do not imply a
// successful window: a separate result packet is mandatory, even on failure
// before any pixel. tx_* is a holding byte stream, tx_last ends ONE datagram.
// All inputs share clk/reset epoch with the serial evidence dispatcher. Reset
// cancels partial packets/windows; no result is invented for a cancelled epoch.
module evidence_window_packetizer #(
    parameter integer WIDTH=320, HEIGHT=180, CHUNK_PIXELS=512
)(
    input wire clk,rst,
    input wire out_valid,out_sof,out_last,
    input wire [15:0] out_data,
    input wire [95:0] out_meta,
    input wire [255:0] out_event,
    input wire out_deferred,
    output wire out_ready,
    input wire result_valid,result_ok,result_deferred,
    input wire [255:0] result_event,
    input wire [31:0] result_frames,
    output wire result_ready,
    output wire tx_valid,tx_last,
    output wire [7:0] tx_data,
    input wire tx_ready,
    output reg protocol_fault,
    output reg [31:0] packets_sent,results_sent
);
    localparam integer FRAME_PIXELS=WIDTH*HEIGHT;
    localparam integer FRAME_BYTES=FRAME_PIXELS*2;
    localparam integer CW=CHUNK_PIXELS<2 ? 1 : $clog2(CHUNK_PIXELS+1);
    localparam [1:0] COLLECT=0,HEADER=1,PAYLOAD=2,CRC=3;
    reg [1:0] state;
    (* ram_style="distributed" *) reg [15:0] pixels[0:CHUNK_PIXELS-1];
    reg [CW-1:0] count;
    reg [15:0] payload_length,payload_pos;
    reg [6:0] header_pos;
    reg [1:0] crc_pos;
    reg [31:0] crc_reg;
    reg active,window_bad;
    reg [255:0] active_event,packet_event;
    reg [95:0] frame_meta,packet_meta;
    reg active_deferred;
    reg [31:0] frame_pos,complete_frames;
    reg [31:0] packet_index,packet_offset,packet_frames;
    reg [7:0] packet_flags,packet_kind;

    function [31:0] crc32_byte;
        input [31:0] crc;
        input [7:0] data;
        reg [31:0] c;
        integer i;
        begin
            c=crc;
            for(i=0;i<8;i=i+1) begin
                if(c[0]^data[i]) c=(c>>1)^32'hedb88320;
                else c=c>>1;
            end
            crc32_byte=c;
        end
    endfunction
    function [31:0] inc_sat;
        input [31:0] n;
        begin inc_sat=n==32'hffffffff ? n : n+1'b1;end
    endfunction
    function [7:0] header_byte;
        input [6:0] pos;
        begin
            header_byte=0;
            case(pos)
                0:header_byte=8'h45; 1:header_byte=8'h47; // EG
                2:header_byte=2; 3:header_byte=packet_kind;
                4:header_byte=0; 5:header_byte=80;
                6:header_byte=packet_flags; 7:header_byte=1; // RGB565 BE
                40:header_byte=packet_index[31:24];41:header_byte=packet_index[23:16];
                42:header_byte=packet_index[15:8];43:header_byte=packet_index[7:0];
                56:header_byte=packet_offset[31:24];57:header_byte=packet_offset[23:16];
                58:header_byte=packet_offset[15:8];59:header_byte=packet_offset[7:0];
                60:header_byte=(FRAME_BYTES>>24)&255;61:header_byte=(FRAME_BYTES>>16)&255;
                62:header_byte=(FRAME_BYTES>>8)&255;63:header_byte=FRAME_BYTES&255;
                64:header_byte=packet_frames[31:24];65:header_byte=packet_frames[23:16];
                66:header_byte=packet_frames[15:8];67:header_byte=packet_frames[7:0];
                68:header_byte=payload_length[15:8];69:header_byte=payload_length[7:0];
                70:header_byte=(WIDTH>>8)&255;71:header_byte=WIDTH&255;
                72:header_byte=(HEIGHT>>8)&255;73:header_byte=HEIGHT&255;
                default:begin
                    if(pos>=8 && pos<40) header_byte=packet_event[255-(pos-8)*8 -: 8];
                    if(pos>=44 && pos<56) header_byte=packet_meta[95-(pos-44)*8 -: 8];
                end
            endcase
        end
    endfunction
    wire input_bad = out_sof!=(frame_pos==0) || out_last!=(frame_pos==FRAME_PIXELS-1) ||
        (active && (out_event!=active_event || out_deferred!=active_deferred)) ||
        (frame_pos!=0 && out_meta!=frame_meta);
    wire [31:0] crc_final=~crc_reg;
    wire [15:0] payload_word=pixels[payload_pos>>1];
    // A pending window result has priority over the NEXT window's first pixel.
    // Otherwise the next window can become active before the previous result is
    // serialized, producing a result/event mismatch (stream_bad) and an extra
    // frame. Block out_ready only for the pending result; result_ready itself
    // does not require !out_valid, so this cannot deadlock.
    assign out_ready=!rst && state==COLLECT && !result_valid;
    // Serial dispatcher cannot produce a new event until this result is taken.
    // Drain a buffered partial chunk first if a failing engine stops mid-frame.
    assign result_ready=!rst && state==COLLECT && count==0;
    assign tx_valid=!rst && state!=COLLECT;
    assign tx_last=state==CRC && crc_pos==3;
    assign tx_data=state==HEADER ? header_byte(header_pos) :
        state==PAYLOAD ? (payload_pos[0] ? payload_word[7:0] : payload_word[15:8]) :
        crc_pos==0 ? crc_final[31:24] : crc_pos==1 ? crc_final[23:16] :
        crc_pos==2 ? crc_final[15:8] : crc_final[7:0];

    always @(posedge clk) begin
        if(rst) begin
            state<=COLLECT;count<=0;payload_length<=0;payload_pos<=0;header_pos<=0;crc_pos<=0;crc_reg<=0;
            active<=0;window_bad<=0;active_event<=0;active_deferred<=0;frame_meta<=0;
            frame_pos<=0;complete_frames<=0;packet_event<=0;packet_meta<=0;packet_index<=0;
            packet_offset<=0;packet_frames<=0;packet_flags<=0;packet_kind<=0;
            protocol_fault<=0;packets_sent<=0;results_sent<=0;
        end else begin
            case(state)
                COLLECT:begin
                    if(out_valid && out_ready) begin
                        pixels[count]<=out_data;count<=count+1'b1;
                        if(!active) begin active<=1;active_event<=out_event;active_deferred<=out_deferred;end
                        if(frame_pos==0) frame_meta<=out_meta;
                        if(input_bad) begin window_bad<=1;protocol_fault<=1;end
                        if(count==0) begin
                            packet_event<=out_event;packet_meta<=out_meta;
                            packet_offset<=frame_pos*2;packet_index<=complete_frames;
                        end
                        if(out_last || frame_pos==FRAME_PIXELS-1) begin
                            frame_pos<=0;complete_frames<=inc_sat(complete_frames);
                        end else frame_pos<=frame_pos+1'b1;
                        if(count==CHUNK_PIXELS-1 || out_last || frame_pos==FRAME_PIXELS-1) begin
                            payload_length<=(count+1)*2;packet_kind<=1;packet_frames<=0;
                            packet_flags<={4'd0,(window_bad || input_bad),(out_last || frame_pos==FRAME_PIXELS-1),1'b0,out_deferred};
                            state<=HEADER;header_pos<=0;crc_reg<=32'hffffffff;
                        end
                    end else if(result_valid && count!=0) begin
                        payload_length<=count*2;packet_kind<=1;packet_frames<=0;
                        packet_flags<={4'd0,window_bad,2'b00,active_deferred};
                        state<=HEADER;header_pos<=0;crc_reg<=32'hffffffff;
                    end else if(result_valid && result_ready) begin
                        packet_event<=result_event;packet_meta<=0;packet_index<=complete_frames;
                        packet_offset<=0;packet_frames<=result_frames;payload_length<=0;packet_kind<=2;
                        packet_flags<={4'd0,(window_bad || frame_pos!=0 ||
                            (active && (result_event!=active_event || result_deferred!=active_deferred)) ||
                            (result_ok && (complete_frames==0 || complete_frames!=result_frames))),1'b0,result_ok,result_deferred};
                        if(frame_pos!=0 || (active && (result_event!=active_event || result_deferred!=active_deferred)) ||
                            (result_ok && (complete_frames==0 || complete_frames!=result_frames))) protocol_fault<=1;
                        state<=HEADER;header_pos<=0;crc_reg<=32'hffffffff;
                    end
                end
                HEADER:if(tx_ready) begin
                    crc_reg<=crc32_byte(crc_reg,tx_data);
                    if(header_pos==79) begin
                        payload_pos<=0;crc_pos<=0;
                        state<=payload_length==0 ? CRC : PAYLOAD;
                    end else header_pos<=header_pos+1'b1;
                end
                PAYLOAD:if(tx_ready) begin
                    crc_reg<=crc32_byte(crc_reg,tx_data);
                    if(payload_pos==payload_length-1) begin state<=CRC;crc_pos<=0;end
                    else payload_pos<=payload_pos+1'b1;
                end
                CRC:if(tx_ready) begin
                    if(crc_pos==3) begin
                        state<=COLLECT;count<=0;packets_sent<=inc_sat(packets_sent);
                        if(packet_kind==2) begin
                            active<=0;window_bad<=0;frame_pos<=0;complete_frames<=0;
                            results_sent<=inc_sat(results_sent);
                        end
                    end else crc_pos<=crc_pos+1'b1;
                end
            endcase
        end
    end
    // synthesis translate_off
    initial if(WIDTH<1 || HEIGHT<1 || WIDTH>65535 || HEIGHT>65535 ||
        CHUNK_PIXELS<1 || CHUNK_PIXELS>512 || FRAME_PIXELS>32'h7fffffff)
        $fatal(1,"FAIL: evidence packetizer parameters");
    // synthesis translate_on
endmodule

