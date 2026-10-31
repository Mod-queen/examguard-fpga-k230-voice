`timescale 1ns/1ps
// Faults are sticky in their own domains until common reset reaches them.
// Independent control-domain latch keeps cancellation asserted after they clear.
// restart is an explicit CONTROL-domain pulse: caller first cancels all pending
// handles/results and advances epoch identity. No automatic retry with old IDs.
// dst_rst MUST also reset/quiesce AXI slave/arbiter, not just the history client.
module history_stream_epoch(
    input wire control_clk,src_clk,dst_clk,arst,restart,
    input wire src_halt,dst_halt,
    output wire control_rst,src_rst,dst_rst,
    output reg cancelled,
    output reg [31:0] cancellation_count
);
    (* ASYNC_REG="TRUE" *) reg [2:0] control_release;
    always @(posedge control_clk or posedge arst)
        if(arst) control_release<=3'b111;
        else control_release<={control_release[1:0],1'b0};
    assign control_rst=control_release[2];
    (* ASYNC_REG="TRUE" *) reg src_meta,src_sync,dst_meta,dst_sync;
    always @(posedge control_clk) begin
        if(control_rst) begin
            src_meta<=0;src_sync<=0;dst_meta<=0;dst_sync<=0;
            cancelled<=0;cancellation_count<=0;
        end else begin
            src_meta<=src_halt;src_sync<=src_meta;
            dst_meta<=dst_halt;dst_sync<=dst_meta;
            if(src_sync || dst_sync) begin
                cancelled<=1;
                if(!cancelled && cancellation_count!=32'hffffffff) cancellation_count<=cancellation_count+1'b1;
            end else if(restart) cancelled<=0;
        end
    end
    evidence_reset_barrier #(.DOMAINS(2)) barrier(.arst(arst || cancelled),
        .clocks({dst_clk,src_clk}),.resets({dst_rst,src_rst}));
endmodule
