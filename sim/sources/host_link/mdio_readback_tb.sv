`timescale 1ns/1ps
// Independent real MDIO engine, clause22 wire scoreboard. No hierarchy used
// for slave data alignment: slave tracks ST/OP/address/turnaround on the wire.
module mdio_readback_tb #(parameter LEGACY_REFERENCE=0);
    reg mdc=0,rst_n=0,if_read=0,start=0;
    always #50 mdc=~mdc;
    reg [4:0] phy_addr=0,reg_addr=0;
    reg [15:0] wrdata=0,reply=0;
    wire [15:0] rddata;
    wire read_valid,done;
    tri mdio;
    pullup pull(mdio);
    reg enable_reply=1,slave_drive=0,slave_bit=1;
    assign mdio=slave_drive ? slave_bit : 1'bz;
    wire master_oe;
    generate if(LEGACY_REFERENCE) begin: legacy
        assign read_valid=1'b1;
        mdio_bit_shift dut(.mdc(mdc),.rst_n(rst_n),.if_read(if_read),.start(start),.phy_addr(phy_addr),.reg_addr(reg_addr),
            .wrdata(wrdata),.rddata(rddata),.done(done),.mdio(mdio));
        assign master_oe=dut.mdio_oe;
    end else begin: repaired
        mdio_bit_shift dut(.*);
        assign master_oe=dut.mdio_oe;
    end endgenerate
    integer ones=0,index=0,reads=0,writes=0,i,seed=179;
    reg framing=0;
    reg [31:0] bits=0;
    reg [1:0] op=0;
    always @(posedge mdc or negedge rst_n) begin
        if(!rst_n) begin framing=0;ones=0;index=0;bits=0;op=0;end
        else if(!framing) begin
            if(mdio===1'b1) ones=ones+1;
            else if(mdio===1'b0 && ones>=32) begin framing=1;index=1;bits=0;ones=0;end
            else ones=0;
        end else begin
            bits={bits[30:0],mdio};
            if(index==1 && mdio!==1) $fatal(1,"FAIL: MDIO ST");
            if(index==3) op=bits[1:0];
            if(index==13 && bits[9:0]!=={phy_addr,reg_addr}) $fatal(1,"FAIL: MDIO addresses");
            if(index==31) begin
                if(op==1) begin
                    if(bits[17:0]!=={2'b10,wrdata}) $fatal(1,"FAIL: MDIO16bit write/TA got=%h",bits);
                    writes=writes+1;
                end else if(op==2) reads=reads+1;
                else $fatal(1,"FAIL: MDIO OP");
                framing=0;index=0;
            end else index=index+1;
        end
    end
    always @(negedge mdc or negedge rst_n) begin
        #2;slave_drive=0;slave_bit=1;
        if(rst_n && framing && op==2 && enable_reply) begin
            if(index==15) begin slave_drive=1;slave_bit=0;end
            if(index>=16 && index<=31) begin slave_drive=1;slave_bit=reply[31-index];end
        end
    end
    task automatic transaction;
        input integer reading;
        input [15:0] word;
        input integer valid_reply;
        begin
            @(posedge mdc);#3;
            if_read=reading;reply=word;wrdata=word;enable_reply=valid_reply;
            phy_addr=$random(seed);reg_addr=$random(seed);start=1;
            @(posedge mdc);#3;start=0;
            wait(done);#3;
            if(reading) begin
                if(read_valid!==1'(valid_reply) || rddata!==(valid_reply ? word : 16'hffff))
                    $fatal(1,"FAIL: MDIO read16/TA got=%h valid=%b expect=%h/%d",rddata,read_valid,word,valid_reply);
            end
            @(posedge mdc);@(posedge mdc);#3;
        end
    endtask
    initial begin
        #17;rst_n=1;
        transaction(1,16'h8001,1);transaction(1,16'h0001,1);transaction(1,16'h8000,1);
        transaction(1,16'hffff,1);transaction(1,16'h0000,1);
        for(i=0;i<32;i=i+1) begin transaction(1,16'($random(seed)),1);transaction(0,16'($random(seed)),1);end
        transaction(1,16'h1234,0);
        // Cancel in a read body, fresh transaction must not retain prefix.
        @(posedge mdc);#3;if_read=1;start=1;
        @(posedge mdc);#3;start=0;
        wait(framing && index==20);#1;rst_n=0;#3;
        if(done || master_oe || read_valid) $fatal(1,"FAIL: MDIO mid-read cancel");
        rst_n=1;transaction(1,16'h5aa5,1);
        $display("PASS: mdio_readback wire addresses/ST-OP/TA/16bit extremes+32random/read-write/noPHY/resetbody");$finish;
    end
    initial begin #1000000;$fatal(1,"FAIL: MDIO readback timeout");end
endmodule
