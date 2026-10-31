`timescale 1ns/1ps
// Independent maintenance probe: never instantiate in the accepted main top.
// Blank media requires a new format_request pulse AFTER the initial SCAN.
// One allocation per common reset. After PB1 result, a separate read-only PS1
// inventory master runs once, for independent host CRC/field validation.
module persistent_boot_probe #(
    parameter integer QUARTER_CYCLES=125,TIMEOUT_CYCLES=500000,
    parameter integer STARTUP_CYCLES=2500000,UART_BAUD=115200,MAX_POLLS=128
)(
    input wire clk,rst,format_request,input wire scl_i,sda_i,
    output wire scl_low,sda_low,uart_txd,
    output wire waiting_format,admission,done
);
    localparam DELAY=0,SCANQ=1,SCANW=2,BLANK=3,START=4,ALLOCATE=5,
        CRC=6,TX=7,TXBUSY=8,TXDONE=9,INVENTORY=10;
    reg [3:0] state;
    reg [31:0] startup,crc;
    reg [5:0] index;
    reg [3:0] scan_error,result_error;
    reg [1:0] action;
    reg saved_loaded,saved_slot,saved_admission;
    reg [31:0] saved_device,saved_generation,saved_boot;
    reg [255:0] saved_config;
    wire store_ready,store_valid,store_loaded,store_slot;
    wire [3:0] store_error;
    wire [31:0] store_device,store_generation,store_boot;
    wire [255:0] store_config;
    wire gate_cmd_valid,gate_cmd_ready,gate_rsp_ready,gate_done,gate_admission;
    wire [1:0] gate_cmd;
    wire [31:0] gate_device,gate_boot;
    wire [255:0] gate_config;
    wire [3:0] gate_error;
    wire store_req,store_rsp_ready,master_ready,master_valid;
    wire [6:0] bus_device;wire [1:0] bus_addr_bytes,master_error;
    wire [15:0] bus_address;wire [5:0] bus_wr_count,bus_rd_count;
    wire [255:0] bus_wr_data,master_data;
    wire alloc_mode=state==START || state==ALLOCATE;
    assign gate_cmd_ready=store_ready && alloc_mode;
    persistent_boot_gate gate(.clk(clk),.rst(rst),.start(state==START),.format_blank(action==3),
        .device(32'd1),.initial_config(256'd0),
        .store_cmd_valid(gate_cmd_valid),.store_cmd_ready(gate_cmd_ready),.store_cmd(gate_cmd),
        .store_device(gate_device),.store_config(gate_config),
        .store_result_valid(store_valid && alloc_mode),.store_result_ready(gate_rsp_ready),
        .store_error(store_error),.store_loaded(store_loaded),.store_boot(store_boot),
        .admission(gate_admission),.done(gate_done),.error(gate_error),.boot_id(gate_boot));
    eeprom_dualslot_store #(.MAX_POLLS(MAX_POLLS)) store(.clk(clk),.rst(rst),
        .cmd_valid(state==SCANQ || (alloc_mode && gate_cmd_valid)),.cmd_ready(store_ready),
        .cmd(alloc_mode?gate_cmd:2'd0),.expected_device(alloc_mode?gate_device:32'd1),
        .config_data(alloc_mode?gate_config:256'd0),
        .result_valid(store_valid),.result_ready(state==SCANW || (alloc_mode && gate_rsp_ready)),
        .result_error(store_error),.loaded(store_loaded),.active_slot(store_slot),
        .device_id(store_device),.generation(store_generation),.boot_id(store_boot),.stored_config(store_config),
        .bus_req_valid(store_req),.bus_req_ready(master_ready),.bus_device(bus_device),.bus_addr_bytes(bus_addr_bytes),
        .bus_address(bus_address),.bus_wr_count(bus_wr_count),.bus_rd_count(bus_rd_count),.bus_wr_data(bus_wr_data),
        .bus_rsp_valid(master_valid),.bus_rsp_ready(store_rsp_ready),.bus_error(master_error),.bus_rd_data(master_data));
    wire boot_scl_low,boot_sda_low,boot_uart;
    i2c_register_master #(.QUARTER_CYCLES(QUARTER_CYCLES),.TIMEOUT_CYCLES(TIMEOUT_CYCLES)) master(
        .clk(clk),.rst(rst),.req_valid(store_req),.req_ready(master_ready),
        .req_device(bus_device),.req_addr_bytes(bus_addr_bytes),.req_address(bus_address),
        .req_wr_count(bus_wr_count),.req_rd_count(bus_rd_count),.req_wr_data(bus_wr_data),
        .rsp_valid(master_valid),.rsp_ready(store_rsp_ready),.rsp_error(master_error),.rsp_rd_data(master_data),
        .scl_i(scl_i),.sda_i(sda_i),.scl_low(boot_scl_low),.sda_low(boot_sda_low));
    wire inventory_mode=state==INVENTORY;
    wire inventory_scl_low,inventory_sda_low,inventory_uart;
    persistence_inventory_probe #(.QUARTER_CYCLES(QUARTER_CYCLES),.TIMEOUT_CYCLES(TIMEOUT_CYCLES),
        .STARTUP_CYCLES(1),.UART_BAUD(UART_BAUD)) inventory(
        .clk(clk),.rst(rst || !inventory_mode),.scl_i(scl_i),.sda_i(sda_i),
        .scl_low(inventory_scl_low),.sda_low(inventory_sda_low),.uart_txd(inventory_uart),.done(done));
    assign scl_low=inventory_mode?inventory_scl_low:boot_scl_low;
    assign sda_low=inventory_mode?inventory_sda_low:boot_sda_low;
    assign uart_txd=inventory_mode?inventory_uart:boot_uart;
    assign waiting_format=!rst && state==BLANK;
    assign admission=!rst && saved_admission;
    reg [7:0] report_byte;
    always @* begin
        report_byte=0;
        case(index)
            0:report_byte=8'h50;1:report_byte=8'h42;2:report_byte=1;3:report_byte=1;
            4:report_byte=0;5:report_byte=64;
            6:report_byte={4'd0,scan_error};7:report_byte={6'd0,action};
            8:report_byte={4'd0,result_error};
            9:report_byte={5'd0,saved_slot,saved_loaded,saved_admission};
            60:report_byte=~crc[31:24];61:report_byte=~crc[23:16];
            62:report_byte=~crc[15:8];63:report_byte=~crc[7:0];
            default:begin
                if(index>=12 && index<16) report_byte=saved_device[(index-12)*8 +: 8];
                else if(index>=16 && index<20) report_byte=saved_generation[(index-16)*8 +: 8];
                else if(index>=20 && index<24) report_byte=saved_boot[(index-20)*8 +: 8];
                else if(index>=24 && index<56) report_byte=saved_config[(index-24)*8 +: 8];
            end
        endcase
    end
    function automatic [31:0] step(input [31:0] old,input [7:0] b);
        reg [31:0] c;integer k;
        begin c=old^{24'd0,b};for(k=0;k<8;k=k+1) c=c[0]?(c>>1)^32'hedb88320:c>>1;step=c;end
    endfunction
    wire uart_busy;
    uart_tx #(.CLK_FREQ_HZ(50000000),.BAUD_RATE(UART_BAUD)) uart(
        .clk(clk),.rst(rst),.tx_start(state==TX),.tx_data(report_byte),.tx(boot_uart),.busy(uart_busy));
    always @(posedge clk) begin
        if(rst) begin
            state<=DELAY;startup<=0;crc<=32'hffffffff;index<=0;scan_error<=0;result_error<=0;action<=0;
            saved_loaded<=0;saved_slot<=0;saved_admission<=0;
            saved_device<=0;saved_generation<=0;saved_boot<=0;saved_config<=0;
        end else case(state)
            DELAY:if(startup==STARTUP_CYCLES-1) state<=SCANQ;else startup<=startup+1'b1;
            SCANQ:if(store_ready) state<=SCANW;
            SCANW:if(store_valid) begin
                scan_error<=store_error;
                if(store_error==0 && store_loaded) begin action<=1;state<=START;end
                else if(store_error==2) state<=BLANK;
                else begin result_error<=store_error==0?4'd7:store_error;state<=CRC;end
            end
            BLANK:if(format_request) begin action<=3;state<=START;end
            START:state<=ALLOCATE;
            ALLOCATE:if(gate_done) begin
                result_error<=gate_error;saved_admission<=gate_admission;saved_loaded<=store_loaded;saved_slot<=store_slot;
                saved_device<=store_device;saved_generation<=store_generation;saved_boot<=gate_boot;saved_config<=store_config;
                state<=CRC;
            end
            CRC:begin
                crc<=step(crc,report_byte);
                if(index==59) begin index<=0;state<=TX;end else index<=index+1'b1;
            end
            TX:state<=TXBUSY;
            TXBUSY:if(uart_busy) state<=TXDONE;
            TXDONE:if(!uart_busy) begin
                if(index==63) state<=INVENTORY;
                else begin index<=index+1'b1;state<=TX;end
            end
            INVENTORY:state<=INVENTORY;
            default:state<=DELAY;
        endcase
    end
endmodule
