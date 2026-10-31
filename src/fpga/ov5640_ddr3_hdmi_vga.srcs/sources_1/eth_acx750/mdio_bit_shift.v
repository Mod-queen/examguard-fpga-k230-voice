`timescale 1ns/1ns
module mdio_bit_shift(
	mdc,
	rst_n,

	if_read,
	start,
	phy_addr,
	reg_addr,
	wrdata,
	rddata,
	read_valid,
	done,
	mdio
);
	input mdc;
	input rst_n;

	input if_read; //1:read,0:write
	input start;
	input [4:0] phy_addr;//phy��ַ
	input [4:0] reg_addr;//reg��ַ
	input [15:0] wrdata;
	output reg [15:0] rddata;
	output reg read_valid;
	output reg done;
	inout mdio;

	reg mdio_o;
	reg mdio_oe;
    
	assign mdio = mdio_oe ? mdio_o : 1'bz;

	localparam 
		IDLE  = 8'h01,
		PRE   = 8'h02,
		ST    = 8'h04,
		OP    = 8'h08,
		PHYAD = 8'h10,
		REGAD = 8'h20,
		TA    = 8'h40,
		DATA  = 8'h80;

	//--------------------
	reg [7:0] state;
	reg [7:0] cnt;
	// Clause22 read data is sampled on rising MDC; control/output changes on
	// falling MDC. Latch all16 bits, including bit0, before done on next fall.
	reg [15:0] read_shift;
	reg turnaround_ok;
	always @(posedge mdc or negedge rst_n)
	if (!rst_n) begin read_shift <= 16'd0;turnaround_ok<=1'b0;end
	else begin
	    if (state == DATA && if_read) read_shift <= {read_shift[14:0],mdio};
	    if (state == TA && cnt==1 && if_read) turnaround_ok <= (mdio==1'b0);
	    if (state == IDLE) begin read_shift<=16'd0;turnaround_ok<=1'b0;end
	end
	always @ (negedge mdc or negedge rst_n)
	if (!rst_n) begin
		rddata <= 'd0;
		read_valid <= 1'b0;
		mdio_oe <= 1'b0;
		mdio_o <= 1'b1;
		cnt <= 'd0;
		done <= 1'b0;
		state <= IDLE;
	end else begin
    case (state)
        IDLE:
            begin
                mdio_o <= 1'b1;
                mdio_oe <= 1'b0;
                done <= 1'b0;
                rddata <= 'd0;
                read_valid <= 1'b0;
                if (start)
                begin
                    cnt <= 'd0;
                    state <= PRE;
                end
            end
        PRE://PRE 32'hffff_ffff  32bit
            begin
                mdio_oe <= 1'b1;    
                mdio_o <= 1'b1;
                cnt <= cnt + 1'b1;
                if (cnt > 'd30)
                begin
                    cnt <= 'd0;
                    state <= ST;
                    mdio_o <= 1'b0;
                end
            end
        ST: //ST 01  2bit
            begin
                mdio_o <= 1'b1;
                cnt <= cnt + 1'b1;
                if (cnt >= 'd1)
                begin
                    cnt <= 'd0;
                    state <= OP;
                    mdio_o <= if_read;
                end
            end
        OP: //OP 01:write,10:read  2bit
            begin                
                mdio_o <= !if_read;
                cnt <= cnt + 1'b1;
                if (cnt >= 'd1)
                begin
                    cnt <= 'd0;
                    state <= PHYAD;
                    mdio_o <= phy_addr[4];
                end
            end
        PHYAD:  //PHYAD  5bit
            begin
                    cnt <= cnt + 1'b1;
             
                if (cnt >= 'd4)
                begin
                    cnt <= 'd0;
                    state <= REGAD;
                    mdio_o <= reg_addr[4];
                end
                else
                    mdio_o <= phy_addr[4 - cnt[2:0]-1];
            end
        REGAD:  //REGAD  5bit
            begin
                cnt <= cnt + 1'b1;
                if (cnt >= 'd4)
                begin
                    cnt <= 'd0;
                    state <= TA;
                    mdio_o <= !if_read;
                    mdio_oe <= !if_read;
                end
                else
                     mdio_o <= reg_addr[4 - cnt[2:0]-1];               
            end
        TA:     //TA     2bit
            begin                
                mdio_o <= 1'b0;
                cnt <= cnt + 1'b1;                
                if (cnt >= 'd1)
                begin
                    cnt <= 'd0;
                    state <= DATA;
                    mdio_o <= wrdata[15];
                end

            end
        DATA:   //DATA   16bit
            begin
                cnt <= cnt + 1'b1;
                if(cnt < 'd15)begin
                    if (!if_read)
                        mdio_o <= wrdata[15 - cnt[3:0]-1];
                end
                else begin
					if (if_read) begin rddata <= read_shift;read_valid<=turnaround_ok;end
                    cnt <= 'd0;
                    state <= IDLE;
                    mdio_o <= 1'b1;
                    mdio_oe <= 1'b0;
                    done <= 1'b1;
                end
            end
        endcase
	end
endmodule
