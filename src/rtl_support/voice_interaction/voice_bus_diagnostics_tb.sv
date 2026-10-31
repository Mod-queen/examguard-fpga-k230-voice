`timescale 1ns/1ps
module voice_bus_diagnostics_tb;
    reg clk=0;always #10 clk=~clk;
    reg rst=1,tick_1s=0,boot_ready=1;
    reg [31:0] device_id=1,boot_id=80;
    reg [63:0] monotonic_ms=100;
    reg [2:0] exam_stage=1;
    tri1 scl_i,sda_i;
    wire scl_low,sda_low,slave_low,link_fresh;
    reg enabled=1,stuck=0;
    assign scl_i=(scl_low || stuck)?1'b0:1'bz;
    assign sda_i=(sda_low || slave_low)?1'b0:1'bz;
    reg [2:0] req_valid=0;
    wire [2:0] req_ready;
    wire done_valid,issue,response,write_op;
    wire [1:0] done_error,error_code;
    wire [7:0] clip_id,read_data,failure_byte;
    wire [3:0] failure_stage;
    voice_interaction_bus #(.QUARTER_CYCLES(4),.TIMEOUT_CYCLES(120),
        .POLL_CYCLES(3000),.STALE_CYCLES(10000)) bus(
        .clk(clk),.rst(rst),.round_id(32'd1),.info_tag(64'd1),.poll_eligible(1'b1),
        .req_valid(req_valid),.req_ready(req_ready),.req_type(24'hffffff),.req_id(24'h210000),
        .req_cookie(96'd1),.req_round({32'd1,32'd1,32'd1}),.req_tag({64'd1,64'd1,64'd1}),
        .done_valid(done_valid),.done_ready(1'b1),.done_error(done_error),
        .link_fresh(link_fresh),.scl_i(scl_i),.sda_i(sda_i),.scl_low(scl_low),.sda_low(sda_low),
        .debug_issue(issue),.debug_response(response),.debug_write(write_op),.debug_error(error_code),
        .debug_id(clip_id),.debug_data(read_data),.debug_failure_stage(failure_stage),.debug_failure_byte(failure_byte));
    wire [7:0] last_clip;wire [31:0] writes,reads;
    wonderecho_wire_model slave(.rst(rst),.scl(scl_i),.sda(sda_i),.enabled(enabled),.word_id(8'h07),
        .slave_low(slave_low),.last_clip(last_clip),.writes(writes),.reads(reads));
    wire byte_valid,byte_last;wire [7:0] byte_data;
    reg byte_ready=1;
    voice_bus_diagnostics dut(.*);
    integer trace,count=0,records=0;
    reg [7:0] held_byte;reg held_last,was_stalled=0;
    always @(posedge clk) if(!rst) begin
        if(was_stalled && (!byte_valid || byte_data!==held_byte || byte_last!==held_last)) $fatal(1,"stalled diagnostic changed");
        was_stalled=byte_valid && !byte_ready;held_byte=byte_data;held_last=byte_last;
        if(byte_valid && byte_ready) begin
            $fwrite(trace,"%c",byte_data);count=count+1;
            if(byte_last) begin if(count!=196)$fatal(1,"record length");count=0;records=records+1;end
        end
    end
    task step;begin @(posedge clk);#1;end endtask
    task snapshot;
        begin @(negedge clk);tick_1s=1;monotonic_ms=monotonic_ms+1000;step;
            @(negedge clk);tick_1s=0;wait(byte_valid);@(negedge clk);byte_ready=0;
            repeat(17)step;@(negedge clk);byte_ready=1;wait(byte_valid && byte_last);step;repeat(3)step;
        end
    endtask
    task startup;
        input [1:0] expected;
        begin @(negedge clk);req_valid=4;
            @(posedge clk);while(!req_ready[2]) @(posedge clk);
            @(negedge clk);req_valid=0;wait(done_valid);#1;
            if(done_error!=expected)$fatal(1,"unexpected write result");step;step;
        end
    endtask
    initial begin
        trace=$fopen("voice_diagnostic_trace.txt","w");
        repeat(5)step;@(negedge clk);rst=0;
        wait(dut.sequence_id==1);wait(byte_valid && byte_last);step;
        startup(0);wait(dut.poll_ok>=1);snapshot;
        if(last_clip!=8'h21 || dut.startup_error!=0 || dut.startup_requests!=1 || dut.startup_responses!=1)$fatal(1,"FF21 success not observed");
        enabled=0;startup(1);snapshot;
        if(dut.startup_stage!=1 || dut.startup_byte!=8'h68 || dut.nacks==0)$fatal(1,"address NACK not distinguished");
        stuck=1;startup(2);snapshot;
        if(dut.startup_stage!=0 || dut.timeouts==0)$fatal(1,"START line timeout not distinguished");
        stuck=0;enabled=1;wait(dut.poll_ok>=2);snapshot;
        if(!link_fresh || dut.last_poll_error!=0)$fatal(1,"poll recovery absent");
        $fclose(trace);
        $display("PASS: voice_bus_diagnostics wire_success_address_nack_line_timeout_recovery records=%0d",records);$finish;
    end
    initial begin #10000000;$fatal(1,"test timeout");end
endmodule
