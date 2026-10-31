`timescale 1ns/1ps
// Commands: 0 SCAN, 1 NEXT_BOOT, 2 SAVE_CONFIG, 3 FORMAT_BLANK.
// SCAN does not grant boot admission. Every mutation rescans media, including
// after uncertain completion. Common reset with page writer/master is required.
module eeprom_dualslot_store #(
    parameter [12:0] BASE0=13'h1e00,BASE1=13'h1e80,
    parameter integer MAX_POLLS=128
)(
    input wire clk,rst,cmd_valid,output wire cmd_ready,input wire [1:0] cmd,
    input wire [31:0] expected_device,input wire [255:0] config_data,
    output reg result_valid,input wire result_ready,output reg [3:0] result_error,
    output reg loaded,active_slot,
    output reg [31:0] device_id,generation,boot_id,output reg [255:0] stored_config,
    output wire bus_req_valid,input wire bus_req_ready,
    output wire [6:0] bus_device,output wire [1:0] bus_addr_bytes,
    output wire [15:0] bus_address,output wire [5:0] bus_wr_count,bus_rd_count,
    output wire [255:0] bus_wr_data,
    input wire bus_rsp_valid,output wire bus_rsp_ready,input wire [1:0] bus_error,input wire [255:0] bus_rd_data
);
    localparam IDLE=0,RQ=1,RW=2,CQ=3,CW=4,SELECT=5,ENCQ=6,ENCW=7,PQ=8,PW=9;
    reg [3:0] state;
    reg [1:0] operation,page,write_step;
    reg scan_slot,final_scan;
    reg [31:0] requested_device,new_generation,new_boot;
    reg [255:0] requested_config,new_config;
    reg [511:0] bodies[0:1];reg [255:0] commits[0:1];
    reg [1:0] valid_slots;
    reg target;
    reg [511:0] encoded_body;
    reg [255:0] encoded_commit;
    wire codec_ready,codec_valid,codec_ok;
    wire [511:0] codec_body;wire [255:0] codec_commit;
    eeprom_record_codec codec(.clk(clk),.rst(rst),.req_valid(state==CQ || state==ENCQ),.req_ready(codec_ready),
        .encode(state==ENCQ),.in_body(bodies[scan_slot]),.in_commit(commits[scan_slot]),
        .device(requested_device),.generation(new_generation),.boot(new_boot),.config_data(new_config),
        .result_valid(codec_valid),.result_ready(state==CW || state==ENCW),.record_ok(codec_ok),.body(codec_body),.commit_page(codec_commit));
    wire page_ready,page_valid;
    wire [2:0] page_error;
    wire p_req,p_rsp_ready;wire [6:0] p_device;wire [1:0] p_addr_bytes;
    wire [15:0] p_address;wire [5:0] p_wr_count,p_rd_count;wire [255:0] p_wr_data;
    wire page_mode=state==PQ || state==PW;
    wire [12:0] target_base=target?BASE1:BASE0;
    wire [12:0] write_address=target_base+(write_step==0 || write_step==3 ? 13'd64 : write_step==1?13'd0:13'd32);
    wire [255:0] write_payload=write_step==0?256'd0:write_step==1?encoded_body[255:0]:
        write_step==2?encoded_body[511:256]:encoded_commit;
    eeprom_page_writer #(.MAX_POLLS(MAX_POLLS)) pages(.clk(clk),.rst(rst),.write_valid(state==PQ),.write_ready(page_ready),
        .write_address(write_address),.write_count(6'd32),.write_data(write_payload),
        .result_valid(page_valid),.result_ready(state==PW),.result_error(page_error),
        .bus_req_valid(p_req),.bus_req_ready(bus_req_ready && page_mode),.bus_device(p_device),.bus_addr_bytes(p_addr_bytes),
        .bus_address(p_address),.bus_wr_count(p_wr_count),.bus_rd_count(p_rd_count),.bus_wr_data(p_wr_data),
        .bus_rsp_valid(bus_rsp_valid && page_mode),.bus_rsp_ready(p_rsp_ready),.bus_error(bus_error),.bus_rd_data(bus_rd_data));
    assign cmd_ready=!rst && state==IDLE && !result_valid;
    assign bus_req_valid=!rst && (page_mode?p_req:state==RQ);
    assign bus_rsp_ready=!rst && (page_mode?p_rsp_ready:state==RW);
    assign bus_device=7'h50;assign bus_addr_bytes=page_mode?p_addr_bytes:2'd2;
    assign bus_address=page_mode?p_address:{3'd0,(scan_slot?BASE1:BASE0)}+{9'd0,page,5'd0};
    assign bus_wr_count=page_mode?p_wr_count:6'd0;assign bus_rd_count=page_mode?p_rd_count:6'd32;
    assign bus_wr_data=page_mode?p_wr_data:256'd0;
    wire all_blank=(&bodies[0]) && (&commits[0]) && (&bodies[1]) && (&commits[1]);
    wire chosen=valid_slots==2'b11 ? bodies[1][127:96]>bodies[0][127:96] : valid_slots[1];
    wire [31:0] chosen_gen=bodies[chosen][127:96],chosen_boot=bodies[chosen][159:128];
    wire [31:0] chosen_dev=bodies[chosen][95:64];
    task finish(input [3:0] err);
        begin state<=IDLE;result_valid<=1;result_error<=err;if(err!=0) loaded<=0;end
    endtask
    task publish(input slot);
        begin
            loaded<=1;active_slot<=slot;device_id<=bodies[slot][95:64];generation<=bodies[slot][127:96];
            boot_id<=bodies[slot][159:128];stored_config<=bodies[slot][415:160];finish(0);
        end
    endtask
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;operation<=0;page<=0;write_step<=0;scan_slot<=0;final_scan<=0;
            requested_device<=0;requested_config<=0;new_generation<=0;new_boot<=0;new_config<=0;
            bodies[0]<=0;bodies[1]<=0;commits[0]<=0;commits[1]<=0;valid_slots<=0;target<=0;
            encoded_body<=0;encoded_commit<=0;result_valid<=0;result_error<=0;loaded<=0;active_slot<=0;
            device_id<=0;generation<=0;boot_id<=0;stored_config<=0;
        end else begin
            if(result_valid && result_ready) result_valid<=0;
            case(state)
                IDLE:if(cmd_valid && cmd_ready) begin
                    operation<=cmd;requested_device<=expected_device;requested_config<=config_data;
                    loaded<=0;valid_slots<=0;scan_slot<=0;page<=0;final_scan<=0;state<=RQ;
                end
                RQ:if(bus_req_ready) state<=RW;
                RW:if(bus_rsp_valid) begin
                    if(bus_error!=0) finish(1);
                    else begin
                        if(page==0) bodies[scan_slot][255:0]<=bus_rd_data;
                        else if(page==1) bodies[scan_slot][511:256]<=bus_rd_data;
                        else commits[scan_slot]<=bus_rd_data;
                        if(page==2) state<=CQ;else begin page<=page+1'b1;state<=RQ;end
                    end
                end
                CQ:if(codec_ready) state<=CW;
                CW:if(codec_valid) begin
                    valid_slots[scan_slot]<=codec_ok;
                    if(final_scan) begin
                        if(!codec_ok || codec_body!==encoded_body || codec_commit!==encoded_commit) finish(7);
                        else publish(scan_slot);
                    end else if(!scan_slot) begin scan_slot<=1;page<=0;state<=RQ;end
                    else state<=SELECT;
                end
                SELECT:begin
                    if(requested_device==0) finish(4);
                    else if(valid_slots==0) begin
                        if(operation==3 && all_blank) begin
                            target<=0;new_generation<=1;new_boot<=1;new_config<=requested_config;state<=ENCQ;
                        end else finish(all_blank?2:3);
                    end else if(valid_slots==3 && (bodies[0][95:64]!=bodies[1][95:64] || bodies[0][127:96]==bodies[1][127:96])) finish(5);
                    else if(chosen_dev!=requested_device) finish(4);
                    else if(operation==0) publish(chosen);
                    else if(operation==3) finish(8);
                    else if(chosen_gen==32'hffffffff || (operation==1 && chosen_boot==32'hffffffff)) finish(6);
                    else begin
                        target<=!chosen;new_generation<=chosen_gen+1'b1;
                        new_boot<=operation==1?chosen_boot+1'b1:chosen_boot;
                        new_config<=operation==2?requested_config:bodies[chosen][415:160];state<=ENCQ;
                    end
                end
                ENCQ:if(codec_ready) state<=ENCW;
                ENCW:if(codec_valid) begin
                    encoded_body<=codec_body;encoded_commit<=codec_commit;write_step<=0;state<=PQ;
                end
                PQ:if(page_ready) state<=PW;
                PW:if(page_valid) begin
                    if(page_error!=0) finish(9);
                    else if(write_step==3) begin scan_slot<=target;page<=0;final_scan<=1;state<=RQ;end
                    else begin write_step<=write_step+1'b1;state<=PQ;end
                end
                default:finish(15);
            endcase
        end
    end
    // synthesis translate_off
    initial if(BASE0[4:0]!=0 || BASE1[4:0]!=0 || BASE0>8096 || BASE1>8096 ||
        !((BASE0+96<=BASE1)||(BASE1+96<=BASE0))) $fatal(1,"FAIL: EEPROM slot geometry");
    // synthesis translate_on
endmodule
