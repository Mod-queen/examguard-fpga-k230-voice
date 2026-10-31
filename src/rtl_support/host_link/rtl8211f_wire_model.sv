`timescale 1ns/1ps
// TEST ONLY C22 PHY. Decoder is driven by MDC/MDIO, never DUT FSM signals.
module rtl8211f_wire_model(
    input rst_n,mdc,respond,ignore_page_write,
    input [31:0] id_value,
    input [15:0] bmsr_value,physr_value,speed_value,tx_value,rx_value,
    input [15:0] fail_page,
    input [4:0] fail_address,
    input fail_read,
    inout mdio,
    output reg [15:0] page=0,
    output reg [31:0] bmcr_writes=0,reads=0,page_checks=0,
    output reg framing=0,
    output reg [5:0] index=0
);
    reg drive=0,bit_value=1;
    assign mdio=drive?bit_value:1'bz;
    reg [31:0] shift=0;
    reg [1:0] op=0;
    reg [4:0] address=0;
    reg [15:0] reply;
    reg reply_valid;
    integer preamble=0;
    always @(negedge rst_n) begin page=0;framing=0;index=0;preamble=0;drive=0;end
    always @(posedge mdc) if(rst_n) begin
        if(!framing) begin
            if(mdio===1'b1) preamble=preamble+1;
            else if(mdio===1'b0 && preamble>=32) begin framing=1;index=1;shift=0;preamble=0;end
            else preamble=0;
        end else begin
            shift={shift[30:0],mdio};
            if(index==3) begin
                op=shift[1:0];
                if(shift[3:2]!==2'b01 || (op!=1 && op!=2)) $fatal(1,"FAIL: MDIO ST/OP");
            end
            if(index==13) begin
                address=shift[4:0];
                if(shift[9:5]!==0) $fatal(1,"FAIL: PHY address");
                reply_valid=respond && !(fail_read && page==fail_page && address==fail_address);
                reply=16'hffff;
                if(address==31) reply=page;
                else if(page==0 && address==2) reply=id_value[31:16];
                else if(page==0 && address==3) reply=id_value[15:0];
                else if(page==0 && address==1) reply=bmsr_value;
                // Deliberately advertise gigabit partner at ALL actual speeds.
                else if(page==0 && address==10) reply=16'h0800;
                else if(page==16'hd08 && address==17) reply=tx_value;
                else if(page==16'hd08 && address==21) reply=rx_value;
                else if(page==16'ha43 && address==26) reply=physr_value;
                else if(page==16'ha43 && address==18) reply=speed_value;
                else if(op==2 && respond) $fatal(1,"FAIL: unexpected page/address read %h/%d",page,address);
            end
            if(index==31) begin
                if(op==1) begin
                    if(shift[17:16]!==2'b10) $fatal(1,"FAIL: write TA");
                    if(address==31) begin
                        if(shift[15:0]!=0 && shift[15:0]!=16'hd08 && shift[15:0]!=16'ha43)
                            $fatal(1,"FAIL: unexpected page write");
                        if(respond && !ignore_page_write) page=shift[15:0];
                    end else if(address==0 && page==0 && shift[15:0]===16'h1340) bmcr_writes=bmcr_writes+1;
                    else $fatal(1,"FAIL: unexpected PHY write; delay registers must remain read-only");
                end else begin
                    reads=reads+1;
                    if(address==31) page_checks=page_checks+1;
                end
                framing=0;index=0;
            end else index=index+1;
        end
    end
    always @(negedge mdc or negedge rst_n) begin
        #1;drive=0;bit_value=1;
        if(rst_n && framing && op==2 && reply_valid) begin
            if(index==15) begin drive=1;bit_value=0;end
            if(index>=16 && index<=31) begin drive=1;bit_value=reply[31-index];end
        end
    end
endmodule
