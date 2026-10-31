`timescale 1ns/1ps
// Two synchronous clients, one register master, one physical open-drain driver.
// Capture request before exposing it to master. Hold owner through response
// consumption, including error responses/backpressure. Alternate when both
// pending, including EEPROM ACK-poll requests. Fair by completed transaction,
// not wall time: a client must eventually consume its response.
// Common rst MUST also reset both clients AND i2c_register_master. No independent
// owner/client reset or timeout that abandons an already accepted bus request.
module i2c_transaction_arbiter(
    input wire clk,rst,
    input wire [1:0] s_req_valid,output wire [1:0] s_req_ready,
    input wire [13:0] s_device,input wire [3:0] s_addr_bytes,
    input wire [31:0] s_address,input wire [11:0] s_wr_count,s_rd_count,
    input wire [511:0] s_wr_data,
    output wire [1:0] s_rsp_valid,input wire [1:0] s_rsp_ready,
    output wire [3:0] s_error,output wire [511:0] s_rd_data,
    output wire m_req_valid,input wire m_req_ready,
    output reg [6:0] m_device,output reg [1:0] m_addr_bytes,
    output reg [15:0] m_address,output reg [5:0] m_wr_count,m_rd_count,
    output reg [255:0] m_wr_data,
    input wire m_rsp_valid,output wire m_rsp_ready,
    input wire [1:0] m_error,input wire [255:0] m_rd_data,
    output wire busy,output reg owner,output reg next_owner,
    output reg [63:0] grants,completed
);
    localparam IDLE=0,ISSUE=1,RESPONSE=2;
    reg [1:0] state;
    wire chosen=s_req_valid==2'b11 ? next_owner : s_req_valid[1];
    assign s_req_ready=(!rst && state==IDLE) ? (chosen?2'b10:2'b01) : 2'b00;
    assign m_req_valid=!rst && state==ISSUE;
    assign s_rsp_valid=(!rst && state==RESPONSE && m_rsp_valid) ? (owner?2'b10:2'b01) : 2'b00;
    assign m_rsp_ready=!rst && state==RESPONSE && s_rsp_ready[owner];
    assign s_error=owner ? {m_error,2'b00} : {2'b00,m_error};
    assign s_rd_data=owner ? {m_rd_data,256'd0} : {256'd0,m_rd_data};
    assign busy=state!=IDLE;
    function automatic [31:0] inc_sat(input [31:0] v);
        inc_sat=v==32'hffffffff ? v : v+1'b1;
    endfunction
    always @(posedge clk) begin
        if(rst) begin
            state<=IDLE;owner<=0;next_owner<=0;grants<=0;completed<=0;
            m_device<=0;m_addr_bytes<=0;m_address<=0;m_wr_count<=0;m_rd_count<=0;m_wr_data<=0;
        end else case(state)
            IDLE:if(|s_req_valid) begin
                owner<=chosen;state<=ISSUE;
                m_device<=s_device[chosen*7 +: 7];m_addr_bytes<=s_addr_bytes[chosen*2 +: 2];
                m_address<=s_address[chosen*16 +: 16];m_wr_count<=s_wr_count[chosen*6 +: 6];
                m_rd_count<=s_rd_count[chosen*6 +: 6];m_wr_data<=s_wr_data[chosen*256 +: 256];
                if(chosen) grants[63:32]<=inc_sat(grants[63:32]);
                else grants[31:0]<=inc_sat(grants[31:0]);
            end
            ISSUE:if(m_req_ready) state<=RESPONSE;
            RESPONSE:if(m_rsp_valid && m_rsp_ready) begin
                next_owner<=!owner;state<=IDLE;
                if(owner) completed[63:32]<=inc_sat(completed[63:32]);
                else completed[31:0]<=inc_sat(completed[31:0]);
            end
            default:state<=IDLE;
        endcase
    end
endmodule
