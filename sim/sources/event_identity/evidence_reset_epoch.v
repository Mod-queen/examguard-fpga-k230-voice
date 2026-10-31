`timescale 1ns/1ps
// Common cancellation for control/display/UI evidence domains. Global reset
// must ALSO reset the shared AXI arbiter/slave. No video SOF/clear input here.
// Asynchronous assertion survives stopped clocks; each release takes 3 local
// rising edges. Cross-domain release barriers keep ALL consumers reset until
// every clock has run those edges (important for synchronous event-toggle reset
// when one clock was stopped). No domain can read a pre-reset toggle meanwhile.
module evidence_reset_epoch(
    input wire arst,
    input wire control_clk,cap_clk,ui_clk,
    output wire control_rst,cap_rst,ui_rst
);
    (* ASYNC_REG="TRUE" *) reg [2:0] control_release,cap_release,ui_release;
    (* ASYNC_REG="TRUE" *) reg [1:0] control_cap,control_ui,cap_control,cap_ui,ui_control,ui_cap;
    always @(posedge control_clk or posedge arst)
        if(arst) control_release<=3'b111;else control_release<={control_release[1:0],1'b0};
    always @(posedge cap_clk or posedge arst)
        if(arst) cap_release<=3'b111;else cap_release<={cap_release[1:0],1'b0};
    always @(posedge ui_clk or posedge arst)
        if(arst) ui_release<=3'b111;else ui_release<={ui_release[1:0],1'b0};
    always @(posedge control_clk or posedge arst)
        if(arst) begin control_cap<=2'b11;control_ui<=2'b11;end
        else begin control_cap<={control_cap[0],cap_release[2]};control_ui<={control_ui[0],ui_release[2]};end
    always @(posedge cap_clk or posedge arst)
        if(arst) begin cap_control<=2'b11;cap_ui<=2'b11;end
        else begin cap_control<={cap_control[0],control_release[2]};cap_ui<={cap_ui[0],ui_release[2]};end
    always @(posedge ui_clk or posedge arst)
        if(arst) begin ui_control<=2'b11;ui_cap<=2'b11;end
        else begin ui_control<={ui_control[0],control_release[2]};ui_cap<={ui_cap[0],cap_release[2]};end
    assign control_rst=arst || control_release[2] || control_cap[1] || control_ui[1];
    assign cap_rst=arst || cap_release[2] || cap_control[1] || cap_ui[1];
    assign ui_rst=arst || ui_release[2] || ui_control[1] || ui_cap[1];
endmodule
