`timescale 1ns/1ps
// Actual manager + dualslot/page writer/CRC codec with retained byte bus model.
module persistent_config_manager_tb;
    reg clk=0,rst=1,request_valid=0,result_ready=0,save=0,maintenance=1,authorize=1;
    always #10 clk=~clk;
    reg [31:0] expected_device=1;
    reg [255:0] proposed_config={120'd0,8'h01,16'sd480,16'd600,32'd42,64'h0000200131504745};
    wire request_ready,result_valid,config_known;
    wire [3:0] result_error,store_error_detail;wire [255:0] active_config;wire [31:0] config_generation;
    wire store_cmd_valid,store_cmd_ready,store_result_valid,store_result_ready,store_loaded;
    wire [1:0] store_cmd;wire [31:0] store_device,store_device_id,store_generation,store_boot;
    wire [255:0] store_config,store_stored_config;wire [3:0] store_error;
    reg seed_valid=0,seed_ready=0;reg [1:0] seed_cmd=3;reg direct=1;
    persistent_config_manager manager(.*);
    wire bus_req_valid,bus_rsp_ready;
    reg bus_req_ready=0,bus_rsp_valid=0;
    wire [6:0] bus_device;wire [1:0] bus_addr_bytes;
    wire [15:0] bus_address;wire [5:0] bus_wr_count,bus_rd_count;wire [255:0] bus_wr_data;
    reg [1:0] bus_error=0;reg [255:0] bus_rd_data=0;
    wire ds_ready,ds_valid;
    assign store_cmd_ready=direct?0:ds_ready;
    assign store_result_valid=direct?0:ds_valid;
    eeprom_dualslot_store #(.MAX_POLLS(4)) store(.clk(clk),.rst(rst),
        .cmd_valid(direct?seed_valid:store_cmd_valid),.cmd_ready(ds_ready),.cmd(direct?seed_cmd:store_cmd),
        .expected_device(direct?32'd1:store_device),.config_data(direct?256'd0:store_config),
        .result_valid(ds_valid),.result_ready(direct?seed_ready:store_result_ready),.result_error(store_error),
        .loaded(store_loaded),.active_slot(),.device_id(store_device_id),.generation(store_generation),
        .boot_id(store_boot),.stored_config(store_stored_config),.bus_req_valid(bus_req_valid),
        .bus_req_ready(bus_req_ready),.bus_device(bus_device),.bus_addr_bytes(bus_addr_bytes),
        .bus_address(bus_address),.bus_wr_count(bus_wr_count),.bus_rd_count(bus_rd_count),.bus_wr_data(bus_wr_data),
        .bus_rsp_valid(bus_rsp_valid),.bus_rsp_ready(bus_rsp_ready),.bus_error(bus_error),.bus_rd_data(bus_rd_data));
    reg [7:0] media[0:8191],old_slot[0:127];
    reg response_taken=0;
    always @(posedge clk) response_taken<=!rst && bus_rsp_valid && bus_rsp_ready;
    integer phase=0,delay_count=0,busy_polls=0,write_calls=0,requests=0,results=0,injected_error=-1;
    reg [15:0] address;reg [5:0] wc,rc;reg [1:0] addrlen;reg [255:0] data;
    integer k;
    always @(negedge clk) begin
        if(rst) begin phase=0;bus_req_ready=0;bus_rsp_valid=0;busy_polls=0;end
        else case(phase)
            0:begin
                bus_req_ready=0;bus_rsp_valid=0;
                if(bus_req_valid) begin
                    if(bus_device!=7'h50 || (bus_addr_bytes!=0 && bus_addr_bytes!=2) ||
                       (bus_addr_bytes!=0 && (bus_address<'h1e00 || bus_address>='h1ee0)))
                        $fatal(1,"FAIL: profile store outside reserved EEPROM");
                    address=bus_address;wc=bus_wr_count;rc=bus_rd_count;addrlen=bus_addr_bytes;data=bus_wr_data;
                    bus_req_ready=1;phase=1;
                end
            end
            1:begin bus_req_ready=0;delay_count=3;phase=2;end
            2:if(delay_count) delay_count=delay_count-1;
            else begin
                bus_error=0;bus_rd_data=0;
                if(requests==injected_error) bus_error=2;
                else if(addrlen==0) begin
                    if(busy_polls>0) begin busy_polls=busy_polls-1;bus_error=1;end
                end else if(wc) begin
                    if(address[4:0]+wc>32) $fatal(1,"FAIL: crossed EEPROM page");
                    for(k=0;k<wc;k=k+1) media[address+k]=data[k*8+:8];
                    write_calls=write_calls+1;busy_polls=2;
                end else for(k=0;k<rc;k=k+1) bus_rd_data[k*8+:8]=media[address+k];
                requests=requests+1;bus_rsp_valid=1;phase=3;
            end
            3:if(response_taken) begin bus_rsp_valid=0;phase=0;end
        endcase
    end
    task automatic seed(input [1:0] operation);
        begin
            @(negedge clk);seed_cmd=operation;seed_valid=1;
            @(posedge clk);while(!ds_ready) @(posedge clk);
            @(negedge clk);seed_valid=0;
            wait(ds_valid);#1;if(store_error) $fatal(1,"FAIL: seed record");
            @(negedge clk);seed_ready=1;@(negedge clk);seed_ready=0;
        end
    endtask
    task automatic request(input integer writing);
        begin
            @(negedge clk);save=writing;request_valid=1;
            @(posedge clk);while(!request_ready) @(posedge clk);
            @(negedge clk);request_valid=0;
        end
    endtask
    task automatic consume(input integer error_code);
        reg [287:0] held;integer r;
        begin
            wait(result_valid);#1;held={config_generation,active_config};r=requests;
            repeat(8) begin
                @(negedge clk);
                if(!result_valid || request_ready || result_error!=error_code || requests!=r ||
                    {config_generation,active_config}!==held) $fatal(1,"FAIL: profile result %0d/%0d",result_error,error_code);
            end
            result_ready=1;@(negedge clk);result_ready=0;results=results+1;
        end
    endtask
    integer i,before_writes,before_requests;
    reg [255:0] wanted;
    initial begin
        for(i=0;i<8192;i=i+1) media[i]=8'hff;
        repeat(4) @(negedge clk);rst=0;
        seed(3);seed(1); // media boot2 generation2; only fixture formats blank model
        direct=0;request(0);consume(0);
        if(!config_known || active_config!=0 || config_generation!=2) $fatal(1,"FAIL: legacy load");
        for(i=0;i<128;i=i+1) old_slot[i]=media['h1e80+i];
        wanted=proposed_config;request(1);
        proposed_config=0; // accepted candidate must remain latched
        consume(0);
        if(active_config!==wanted || config_generation!=3 || store_boot!=2) $fatal(1,"FAIL: saved profile/boot");
        for(i=0;i<128;i=i+1) if(old_slot[i]!==media['h1e80+i]) $fatal(1,"FAIL: changed old slot");
        before_writes=write_calls;before_requests=requests;
        maintenance=0;request(1);consume(1);maintenance=1;
        proposed_config=~256'd0;request(1);consume(2);
        if(write_calls!=before_writes || requests!=before_requests || active_config!==wanted)
            $fatal(1,"FAIL: rejected profile touched media/runtime");
        // Error does not replace active profile or retry a possibly committed save.
        proposed_config=0;injected_error=requests;request(1);consume(3);injected_error=-1;
        if(active_config!==wanted || store_error_detail!=1) $fatal(1,"FAIL: failed save publication");
        request(0);consume(0);
        if(active_config!==wanted || config_generation!=3) $fatal(1,"FAIL: reload after failure");
        // Fail first write after manager SCAN + store SAVE_CONFIG's own rescan.
        before_writes=write_calls;injected_error=requests+12;
        request(1);consume(3);injected_error=-1;
        if(active_config!==wanted || store_error_detail!=9 || write_calls!=before_writes)
            $fatal(1,"FAIL: write failure changed active config/retried");
        request(0);consume(0);
        if(active_config!==wanted || store_boot!=2 || config_generation!=3)
            $fatal(1,"FAIL: scan after failed write lost prior config");
        // Common reset retains bytes; read-only load never allocates another boot.
        @(negedge clk);rst=1;repeat(4) @(negedge clk);rst=0;
        before_writes=write_calls;request(0);consume(0);
        if(active_config!==wanted || store_boot!=2 || write_calls!=before_writes) $fatal(1,"FAIL: reset read-only profile");
        for(i=0;i<'h1e00;i=i+1) if(media[i]!=8'hff) $fatal(1,"FAIL: nonreserved media changed");
        for(i='h1ee0;i<8192;i=i+1) if(media[i]!=8'hff) $fatal(1,"FAIL: unused slot tail changed");
        $display("PASS: persistent_config_manager results=%0d requests=%0d writes=%0d actual-dualslot/legacy/save/boot-preserve/oldslot/reject/error/reset",results,requests,write_calls);
        $finish;
    end
    initial begin #5000000;$fatal(1,"FAIL: config manager timeout manager=%0d store=%0d phase=%0d results=%0d direct=%0d ds_valid=%0d request=%0d ready=%0d",manager.state,store.state,phase,results,direct,ds_valid,request_valid,request_ready);end
endmodule
