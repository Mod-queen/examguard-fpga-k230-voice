`timescale 1ns/1ps
module candidate_overlay_tb;
    reg clk=0;always #7 clk=~clk;
    reg rst=1,sof=0,snapshot_valid=1,candidate_valid=0,de=1;
    reg [127:0] text_codes=128'h85868720202036303234323032323538;
    reg [31:0] text_token=7,seat=1;
    reg [2:0] stage=2;
    reg [11:0] x=0,y=0;
    reg [23:0] pixel_in=24'h112233;
    wire [23:0] pixel_out;
    wire [31:0] displayed_token;
    candidate_overlay dut(.*);
    integer row,col,n,lit=0;
    reg [7:0] expected;
    wire [15:0] reference_bits;
    candidate_glyph reference_digit(.code(expected),.row(y[3:0]-4'd8),.bits(reference_bits));
    task step;begin @(posedge clk);#1;end endtask
    initial begin
        repeat(3)step;@(negedge clk);rst=0;candidate_valid=1;
        repeat(3)step;if(displayed_token) $fatal(1,"upload treated as displayed before SOF");
        @(negedge clk);sof=1;step;@(negedge clk);sof=0;
        if(displayed_token!=7) $fatal(1,"no frame acknowledgement");
        x=16;y=136;#1;if(dut.code!=8'h8b) $fatal(1,"wrong confirm label palette");
        stage=3;#1;if(dut.code!=8'h82) $fatal(1,"wrong exam label palette");stage=2;
        for(n=0;n<6;n=n+1) begin
            x=16+(3+n)*16;y=88;#1;
            if(dut.code!==text_codes[127-n*8 -:8]) $fatal(1,"name glyph order");
        end
        for(n=0;n<10;n=n+1) begin
            expected=text_codes[79-n*8 -:8];
            for(row=0;row<16;row=row+1) for(col=0;col<10;col=col+1) begin
                x=64+n*10+col;y=104+row;#1;
                if((pixel_out==24'hf8fafc)!==reference_bits[12-col]) $fatal(1,"compact number pixel/order");
            end
        end
        x=164;y=104;#1;if(dut.code!==8'h20) $fatal(1,"number extends beyond compact width");
        for(row=0;row<16;row=row+1) for(col=0;col<16;col=col+1) begin
            x=16+3*16+col;y=88+row;#1;
            if(pixel_out==24'hf8fafc) lit=lit+1;
        end
        if(lit<15) $fatal(1,"Chinese glyph blank");
        text_token=8;text_codes[127:120]=8'h86;repeat(3)step;
        if(displayed_token!=7 || dut.held_text[127:120]!=8'h85) $fatal(1,"mid-frame tearing");
        sof=1;step;sof=0;if(displayed_token!=8) $fatal(1,"new frame not applied");
        x=500;y=500;#1;if(pixel_out!=pixel_in) $fatal(1,"video outside panel changed");
        candidate_valid=0;step;x=64;y=88;#1;
        if(displayed_token || pixel_out!=pixel_in) $fatal(1,"old candidate not hidden");
        $display("PASS: candidate_overlay frame_ack glyphs=16 passthrough lit=%0d",lit);$finish;
    end
    initial begin #100000;$fatal(1,"test timeout");end
endmodule
