`timescale 1ns/1ps
// Actual controller + ROM + SCCB serial engines. Slave uses only bus edges.
module camera_init_contract_tb;
    reg clk=0,rst_n=0;
    always #10 clk=~clk;
    wire done,scl;
    tri1 sda;
    reg slave_low=0;
    assign sda=slave_low?1'b0:1'bz;
    camera_init #(.IMAGE_WIDTH(1280),.IMAGE_HEIGHT(720)) dut(
        .Clk(clk),.Rst_n(rst_n),.Init_Done(done),.camera_rst_n(),
        .camera_pwdn(),.i2c_sclk(scl),.i2c_sdat(sda));
    reg active=0,nack_this;
    reg [7:0] shift;
    reg [31:0] packet;
    integer phase=0,bytes_seen=0,accepted=0,attempts=0,nacks=0;
    integer target=-1,nack_byte=3,budget=0;
    integer starts=0,stops=0;
    reg [23:0] expected [0:266];
    reg [8:0] ref_addr=0;
    wire [23:0] ref_word;
    ov5640_init_table_rgb #(.IMAGE_WIDTH(1280),.IMAGE_HEIGHT(720)) ref_rom(
        .clk(clk),.addr(ref_addr),.q(ref_word));

    always @(negedge sda) if (rst_n && scl===1'b1) begin
        if(active) $fatal(1,"FAIL: unexpected repeated START");
        active=1;phase=0;bytes_seen=0;packet=0;shift=0;
        nack_this=(accepted==target && budget!=0);
        starts=starts+1;
    end
    always @(posedge scl) if(rst_n && active) begin
        if(bytes_seen<4) begin
            if(phase<8) begin
                if(sda!==1'b0 && sda!==1'b1) $fatal(1,"FAIL: undefined SDA");
                shift={shift[6:0],sda};phase=phase+1;
                if(phase==8) packet={packet[23:0],shift};
            end else begin
                if(sda !== ((nack_this && bytes_seen==nack_byte)?1'b1:1'b0))
                    $fatal(1,"FAIL: ACK wire mismatch");
                phase=9;
            end
        end
    end
    always @(negedge scl) if(rst_n && active) begin
        if(phase==8) slave_low=!(nack_this && bytes_seen==nack_byte);
        else if(phase==9) begin slave_low=0;phase=0;bytes_seen=bytes_seen+1;end
    end
    always @(posedge sda) if(rst_n && scl===1'b1 && active) begin
        if(bytes_seen!=4) $fatal(1,"FAIL: incomplete STOP bytes=%0d",bytes_seen);
        if(accepted>266 || packet!=={8'h78,expected[accepted]})
            $fatal(1,"FAIL: transaction index=%0d got=%08h expected=%06h",accepted,packet,expected[accepted]);
        attempts=attempts+1;stops=stops+1;
        if(nack_this) begin
            nacks=nacks+1;
            if(budget>0) budget=budget-1;
        end else accepted=accepted+1;
        active=0;
    end
    always @(posedge clk) if(rst_n && done && accepted!=267)
        $fatal(1,"FAIL: Init_Done before final successful transaction accepted=%0d",accepted);

    task automatic restart;
        begin
            @(negedge clk);rst_n=0;active=0;slave_low=0;
            repeat(4) @(negedge clk);
            if(done!==0 || dut.RW_Done!==0 || scl!==1 || sda!==1)
                $fatal(1,"FAIL: reset idle done=%b RW_Done=%b SCL=%b SDA=%b",done,dut.RW_Done,scl,sda);
            accepted=0;attempts=0;nacks=0;starts=0;stops=0;phase=0;bytes_seen=0;
            rst_n=1;
            // Skip startup wall time only; SCCB and 5ms reset-write delay are real.
            force dut.delay_cnt=21'h1007ff;
            @(negedge clk);release dut.delay_cnt;
        end
    endtask
    task automatic finish_run(input integer expected_nacks);
        integer before_count;
        begin
            wait(done);repeat(20) @(negedge clk);
            if(accepted!=267 || nacks!=expected_nacks || attempts!=267+expected_nacks || starts!=stops)
                $fatal(1,"FAIL: completion totals %0d %0d %0d",accepted,nacks,attempts);
            before_count=starts;
            repeat(1000) @(negedge clk);
            if(starts!=before_count || !done) $fatal(1,"FAIL: completed run replayed");
        end
    endtask
    integer i;
    initial begin
        // Independent ROM readout, bus packets never consult DUT state/count.
        for(i=0;i<267;i=i+1) begin
            @(negedge clk);ref_addr=i;
            @(negedge clk);expected[i]=ref_word;
        end
        target=-1;budget=0;restart();finish_run(0);
        $display("PASS: camera init wire all267 including474020");
        // NACK each byte position, retry same word. Final NACK must not set done.
        for(i=0;i<4;i=i+1) begin
            target=266;nack_byte=i;budget=1;restart();finish_run(1);
        end
        target=208;nack_byte=2;budget=2;restart();finish_run(2);
        // Persistent final NACK cannot complete. Reset during the retry body.
        target=266;nack_byte=3;budget=-1;restart();
        wait(nacks>=3);if(done) $fatal(1,"FAIL: persistent NACK completion");
        wait(active && bytes_seen==2);
        target=-1;budget=0;restart();finish_run(0);
        // Restart during an earlier transaction, not just after completion.
        restart();wait(accepted==8 && active && phase==4);
        restart();finish_run(0);
        $display("PASS: camera_init_contract ACK all bytes/NACK retry/permanent NACK/reset body/restart/no replay");
        $finish;
    end
    initial begin #400000000; $fatal(1,"FAIL: camera init contract timeout");end
endmodule
