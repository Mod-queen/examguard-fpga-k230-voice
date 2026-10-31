`timescale 1ns/1ps
// Write spacing, NOT playback-complete detection. req_guard_ms is supplied from
// the selected vocabulary/audio timing configuration, including a quiet margin.
// Bus polls must continue outside this gate. A zero guard means no spacing.
module voice_audio_gate (
    input wire clk,rst,tick_1ms,
    input wire [2:0] req_valid,
    output reg [2:0] req_ready,
    input wire [23:0] req_type,req_id,
    input wire [95:0] req_cookie,req_round,
    input wire [191:0] req_tag,
    input wire [47:0] req_guard_ms,
    output reg [2:0] bus_req_valid,
    input wire [2:0] bus_req_ready,
    output wire [23:0] bus_req_type,bus_req_id,
    output wire [95:0] bus_req_cookie,bus_req_round,
    output wire [191:0] bus_req_tag,
    // Observe the *consumed* completion from voice_interaction_bus. Actual
    // owner completion still routes directly, unchanged, to its controller.
    input wire done_valid,done_ready,
    input wire [1:0] done_owner,
    input wire [31:0] done_cookie,done_round,
    input wire [63:0] done_tag,
    output wire audio_reserved,
    output wire samples_allowed
);
    reg inflight;
    reg [15:0] remaining_ms,held_guard_ms;
    reg [1:0] owner,selected;
    reg [31:0] cookie,round;
    reg [63:0] tag;
    wire completion_matches=done_valid && done_ready && inflight &&
        done_owner==owner && done_cookie==cookie && done_round==round && done_tag==tag;
    assign audio_reserved=!rst && (inflight || remaining_ms!=0);
    // Discard polls delivered while a clip may be playing. The controllers
    // still require a new successful zero poll after this window, then a reply.
    assign samples_allowed=!rst && !audio_reserved && !(|(bus_req_valid & bus_req_ready));
    assign bus_req_type=req_type;
    assign bus_req_id=req_id;
    assign bus_req_cookie=req_cookie;
    assign bus_req_round=req_round;
    assign bus_req_tag=req_tag;
    always @* begin
        // Information / preparation feedback precedes optional notices. Each
        // controller has at most one held request, not an unbounded pulse FIFO.
        selected=req_valid[0] ? 0 : req_valid[1] ? 1 : 2;
        bus_req_valid=0;req_ready=0;
        if(!rst && !audio_reserved && |req_valid) begin
            bus_req_valid[selected]=1;
            req_ready[selected]=bus_req_ready[selected];
        end
    end
    always @(posedge clk) begin
        if(rst) begin
            inflight<=0;remaining_ms<=0;held_guard_ms<=0;
            owner<=0;cookie<=0;round<=0;tag<=0;
        end else begin
            if(tick_1ms && remaining_ms!=0) remaining_ms<=remaining_ms-1'b1;
            if(completion_matches) begin
                inflight<=0;remaining_ms<=held_guard_ms;
            end
            if(|(bus_req_valid & bus_req_ready)) begin
                inflight<=1;owner<=selected;
                cookie<=req_cookie[selected*32 +:32];
                round<=req_round[selected*32 +:32];tag<=req_tag[selected*64 +:64];
                held_guard_ms<=req_guard_ms[selected*16 +:16];
            end
        end
    end
endmodule
