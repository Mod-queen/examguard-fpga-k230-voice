`timescale 1ns/1ps
// Independent primitive test: slave drives ACK/data only on SCL falling edges.
module i2c_byte_master_tb;
    reg clk=0,rst=1,cmd_valid=0,cmd_read_nack=1,rsp_ready=0;
    always #10 clk=~clk;
    reg [1:0] cmd_op=0;reg [7:0] cmd_data=0;
    wire cmd_ready,rsp_valid,rsp_ack,bus_active,scl_low,sda_low;
    wire [7:0] rsp_data;wire [1:0] rsp_error;
    tri1 scl_i,sda_i;
    reg slave_low=0,stretch=0,slave_ack=1,read_mode=0;
    reg [7:0] slave_byte=8'h81,captured=0;
    integer edge_count=0,commands=0;
    reg observe=0,master_ack=0;
    assign scl_i=scl_low || stretch ? 1'b0:1'bz;
    assign sda_i=sda_low || slave_low ? 1'b0:1'bz;
    i2c_byte_master #(.QUARTER_CYCLES(4),.TIMEOUT_CYCLES(80)) dut(.*);
    always @(posedge scl_i) if(observe) begin
        if(edge_count<8) captured={captured[6:0],sda_i};else master_ack=!sda_i;
        edge_count=edge_count+1;
    end
    always @(negedge scl_i) if(observe) begin
        if(edge_count<8) slave_low=read_mode && !slave_byte[7-edge_count];
        else slave_low=!read_mode && edge_count==8 && slave_ack;
    end
    task automatic command(input integer op,input [7:0] data,input integer nack,input integer err);
        begin
            @(negedge clk);cmd_op=op;cmd_data=data;cmd_read_nack=nack;cmd_valid=1;
            @(posedge clk);while(!cmd_ready) @(posedge clk);
            @(negedge clk);cmd_valid=0;
            wait(rsp_valid);#1;
            if(rsp_error!=err) $fatal(1,"FAIL: primitive error %0d expected%0d",rsp_error,err);
            repeat(3) @(negedge clk);rsp_ready=1;@(negedge clk);rsp_ready=0;
            commands=commands+1;
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst=0;
        command(1,8'hff,0,3); // no START => not an owned transfer
        command(0,0,0,0);
        if(!bus_active) $fatal(1,"FAIL: START not active");
        edge_count=0;captured=0;observe=1;
        command(1,8'ha2,0,0);observe=0;slave_low=0;
        if(!rsp_ack || captured!=8'ha2 || edge_count!=9) $fatal(1,"FAIL: primitive write/ACK");
        command(0,0,0,0); // repeated START
        edge_count=0;captured=0;read_mode=1;observe=1;slave_low=!slave_byte[7];
        command(2,0,1,0);observe=0;slave_low=0;
        if(rsp_data!=8'h81 || master_ack || edge_count!=9) $fatal(1,"FAIL: primitive read/NACK");
        command(3,0,0,0);
        if(bus_active || scl_low || sda_low) $fatal(1,"FAIL: STOP not idle");
        stretch=1;command(0,0,0,2);stretch=0;
        repeat(5) @(negedge clk);command(0,0,0,0);command(3,0,0,0);
        $display("PASS: i2c_byte_master commands=%0d owned-state/writeACK/readNACK/repeatedSTART/STOP/timeout",commands);$finish;
    end
    initial begin #100000;$fatal(1,"FAIL: primitive timeout");end
endmodule
