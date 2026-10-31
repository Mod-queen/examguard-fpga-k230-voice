`timescale 1ns/1ps
// Maintenance profile load/save frontend. Shares ONE existing dualslot store
// through a caller-owned command arbiter; cannot allocate boot or format media.
// Caller holds maintenance lock and store ownership through consumed result.
// Error 0 success, 1 unauthorized, 2 invalid proposed profile, 3 store failure,
// 4 loaded record invalid/unexpected config or changed boot during SAVE.
module persistent_config_manager(
    input wire clk,rst,request_valid,output wire request_ready,
    input wire save,maintenance,authorize,
    input wire [31:0] expected_device,input wire [255:0] proposed_config,
    output reg result_valid,input wire result_ready,
    output reg [3:0] result_error,store_error_detail,
    output reg config_known,output reg [255:0] active_config,
    output reg [31:0] config_generation,
    output wire store_cmd_valid,input wire store_cmd_ready,
    output wire [1:0] store_cmd,output wire [31:0] store_device,
    output wire [255:0] store_config,
    input wire store_result_valid,output wire store_result_ready,
    input wire [3:0] store_error,input wire store_loaded,
    input wire [31:0] store_device_id,store_generation,store_boot,
    input wire [255:0] store_stored_config
);
    localparam IDLE=0,ISSUE_SCAN=1,WAIT_SCAN=2,ISSUE_SAVE=3,WAIT_SAVE=4;
    reg [2:0] state;
    reg operation_save;
    reg [31:0] device,prior_boot;
    reg [255:0] candidate;
    wire proposal_valid,loaded_valid;
    persistent_config_decode proposed(.config_data(proposed_config),.valid(proposal_valid),.legacy_defaults(),
        .seat_id(),.exam_duration_s(),.rtc_offset_known(),.rtc_offset_minutes(),.mute());
    persistent_config_decode loaded(.config_data(store_stored_config),.valid(loaded_valid),.legacy_defaults(),
        .seat_id(),.exam_duration_s(),.rtc_offset_known(),.rtc_offset_minutes(),.mute());
    assign request_ready=!rst && state==IDLE && !result_valid;
    assign store_cmd_valid=!rst && (state==ISSUE_SCAN || state==ISSUE_SAVE);
    assign store_result_ready=!rst && (state==WAIT_SCAN || state==WAIT_SAVE);
    assign store_cmd=state==ISSUE_SAVE ? 2'd2 : 2'd0;
    assign store_device=device;
    assign store_config=candidate;
    task finish(input [3:0] error_code);
        begin state<=IDLE;result_valid<=1;result_error<=error_code;end
    endtask
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;operation_save<=0;device<=0;prior_boot<=0;candidate<=0;
            result_valid<=0;result_error<=0;store_error_detail<=0;
            config_known<=0;active_config<=0;config_generation<=0;
        end else begin
            if(result_valid && result_ready) result_valid<=0;
            case(state)
                IDLE:if(request_valid && request_ready) begin
                    store_error_detail<=0;
                    if(!maintenance || !authorize || expected_device==0) finish(1);
                    else if(save && !proposal_valid) finish(2);
                    else begin
                        operation_save<=save;device<=expected_device;candidate<=proposed_config;state<=ISSUE_SCAN;
                    end
                end
                ISSUE_SCAN:if(store_cmd_ready) state<=WAIT_SCAN;
                ISSUE_SAVE:if(store_cmd_ready) state<=WAIT_SAVE;
                WAIT_SCAN,WAIT_SAVE:if(store_result_valid) begin
                    store_error_detail<=store_error;
                    if(store_error!=0) finish(3);
                    else if(!store_loaded || store_device_id!=device || store_generation==0 || store_boot==0)
                        finish(4);
                    else if(state==WAIT_SCAN && operation_save) begin
                        // A valid proposed profile may replace an unsupported old
                        // config, but only inside a structurally valid device record.
                        prior_boot<=store_boot;state<=ISSUE_SAVE;
                    end else if(!loaded_valid || (state==WAIT_SAVE &&
                        (store_boot!=prior_boot || store_stored_config!=candidate))) finish(4);
                    else begin
                        active_config<=store_stored_config;config_generation<=store_generation;config_known<=1;finish(0);
                    end
                end
                default:begin config_known<=0;finish(4);end
            endcase
        end
    end
endmodule
