`timescale 1ns/1ps
// Setter -> actual register/byte master -> wire-only RTC slave.
// Simplified register retention/NACK model, not oscillator/battery physics.
module pcf8563_setter_wire_tb;
    reg clk=0,rst=1;
    always #10 clk=~clk;
    reg set_valid=0,maintenance=1,authorize=1,result_ready=0;
    reg [55:0] calendar_data=56'h26100321123456;
    wire set_ready,result_valid,write_attempted;
    wire [3:0] result_error;wire [1:0] recovery_error;wire [71:0] snapshot;
    wire bus_req_valid,bus_req_ready,bus_rsp_valid,bus_rsp_ready;
    wire [6:0] bus_device;wire [1:0] bus_addr_bytes,bus_error;
    wire [15:0] bus_address;wire [5:0] bus_wr_count,bus_rd_count;
    wire [255:0] bus_wr_data,bus_rd_data;
    tri1 scl,sda;
    reg slave_low=0;
    wire scl_low,sda_low;
    assign scl=scl_low?1'b0:1'bz;
    assign sda=(sda_low||slave_low)?1'b0:1'bz;
    pcf8563_setter setter(.*);
    i2c_register_master #(.QUARTER_CYCLES(4),.TIMEOUT_CYCLES(120)) master(
        .clk(clk),.rst(rst),.req_valid(bus_req_valid),.req_ready(bus_req_ready),
        .req_device(bus_device),.req_addr_bytes(bus_addr_bytes),.req_address(bus_address),
        .req_wr_count(bus_wr_count),.req_rd_count(bus_rd_count),.req_wr_data(bus_wr_data),
        .rsp_valid(bus_rsp_valid),.rsp_ready(bus_rsp_ready),.rsp_error(bus_error),.rsp_rd_data(bus_rd_data),
        .scl_i(scl),.sda_i(sda),.scl_low(scl_low),.sda_low(sda_low));
    reg [7:0] media[0:255],original[0:255];
    integer mode=0,bitno=0,stage=0,pointer=0,starts=0,stops=0,wr_bytes=0;
    integer nack_register=-1,nacks=0,transactions=0;
    reg [7:0] rx=0,tx=0;
    reg reading=0,ack_ok=0,ack_risen=0,master_ack_seen=0,ack_value=0;
    // This slave sees only pin edges; no DUT phase or transaction fields.
    always @(negedge sda) if(scl===1'b1 && !rst) begin
        starts=starts+1;mode=1;bitno=0;stage=0;rx=0;reading=0;slave_low=0;
    end
    always @(posedge sda) if(scl===1'b1 && !rst) begin
        stops=stops+1;mode=0;slave_low=0;
    end
    always @(posedge scl) if(!rst) case(mode)
        1:begin
            rx={rx[6:0],sda};
            if(bitno==7) begin
                ack_ok=1;
                if(stage==0) begin
                    if(rx[7:1]!=7'h51) $fatal(1,"FAIL: write/read device other than RTC");
                    reading=rx[0];
                end else if(stage==1) pointer=rx;
                else begin
                    if(pointer==nack_register) begin ack_ok=0;nacks=nacks+1;nack_register=-1;end
                    else begin
                        if(pointer!=0 && (pointer<2 || pointer>8)) $fatal(1,"FAIL: unrelated RTC register write");
                        media[pointer]=rx;pointer=pointer+1;wr_bytes=wr_bytes+1;
                    end
                end
                stage=stage+1;mode=2;ack_risen=0;bitno=0;
            end else bitno=bitno+1;
        end
        2:ack_risen=1;
        3:if(bitno==7) begin mode=4;master_ack_seen=0;end else bitno=bitno+1;
        4:begin ack_value=sda;master_ack_seen=1;end
    endcase
    always @(negedge scl) if(!rst) case(mode)
        2:if(!ack_risen) slave_low=ack_ok;
        else begin
            slave_low=0;
            if(!ack_ok) mode=5;
            else if(reading && stage==1) begin
                tx=media[pointer&255];pointer=pointer+1;mode=3;bitno=0;slave_low=!tx[7];
            end else begin mode=1;bitno=0;rx=0;end
        end
        3:slave_low=!tx[7-bitno];
        4:if(!master_ack_seen) slave_low=0;
        else if(ack_value) begin slave_low=0;mode=5;end
        else begin
            tx=media[pointer&255];pointer=pointer+1;mode=3;bitno=0;slave_low=!tx[7];
        end
    endcase
    always @(posedge clk) if(!rst && bus_req_valid && bus_req_ready) transactions=transactions+1;
    task automatic start(input [55:0] value);
        begin
            @(negedge clk);calendar_data=value;set_valid=1;
            @(posedge clk);while(!set_ready) @(posedge clk);
            @(negedge clk);set_valid=0;
        end
    endtask
    task automatic consume(input integer error_code);
        reg [71:0] held;integer i;
        begin
            wait(result_valid);#1;held=snapshot;
            repeat(10) begin
                @(negedge clk);
                if(result_error!=error_code || snapshot!==held || recovery_error!=0 || !write_attempted)
                    $fatal(1,"FAIL: RTC wire result %0d expected %0d",result_error,error_code);
            end
            for(i=1;i<256;i=i+1) if((i==1 || i>8) && media[i]!==original[i])
                $fatal(1,"FAIL: unrelated RTC media changed");
            if(scl!==1 || sda!==1 || scl_low || sda_low) $fatal(1,"FAIL: bus not released");
            result_ready=1;@(negedge clk);result_ready=0;
        end
    endtask
    integer k,before_transactions;
    initial begin
        for(k=0;k<256;k=k+1) begin media[k]=8'(k+19);original[k]=8'(k+19);end
        media[0]=0;media[2]=8'h80; // initially voltage-low/invalid
        repeat(4) @(negedge clk);rst=0;
        start(56'h26100321123456);consume(0);
        if(snapshot[71:16]!=56'h26100321123456 || snapshot[7:0]!=0 || transactions!=7)
            $fatal(1,"FAIL: wire normal readback");
        // NACK one date byte after earlier bytes were written; do not retry date.
        nack_register=4;before_transactions=transactions;
        start(56'h27110422134557);consume(3);
        if(media[0]!=0 || nacks!=1 || transactions-before_transactions!=4)
            $fatal(1,"FAIL: wire best-effort run not exactly once");
        start(56'h27110422134557);consume(0);
        if(snapshot[71:16]!=56'h27110422134557) $fatal(1,"FAIL: explicit retry failed");
        $display("PASS: pcf8563_setter_wire transactions=%0d START=%0d STOP=%0d writes=%0d NACK=%0d normal/partial-write/run-recovery/explicit-retry/media-preserved",transactions,starts,stops,wr_bytes,nacks);
        $finish;
    end
    initial begin #10000000;$fatal(1,"FAIL: RTC setter wire timeout");end
endmodule
