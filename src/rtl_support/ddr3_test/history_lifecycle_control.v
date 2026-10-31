`timescale 1ns/1ps
// Control-domain release waits for independent AXI drain, never a client's reset
// acknowledgement. Ordinary AXI busy in RUN is NOT a reset cause. A local fault
// stays latched in history_stream_epoch until an external transport/system reset;
// no periodic retry and no reuse of an old event/descriptor epoch.
module history_lifecycle_control(
    input wire clk,transport_rst,axi_idle,local_cancelled,
    output wire client_transport_rst,source_epoch_rst
);
    (* ASYNC_REG="TRUE" *) reg idle_meta,idle_sync;
    reg draining;
    always @(posedge clk or posedge transport_rst) begin
        if(transport_rst) begin idle_meta<=0;idle_sync<=0;draining<=1;end
        else begin
            idle_meta<=axi_idle;idle_sync<=idle_meta;
            if(idle_sync) draining<=0;
        end
    end
    assign client_transport_rst=draining;
    assign source_epoch_rst=draining || local_cancelled;
endmodule
