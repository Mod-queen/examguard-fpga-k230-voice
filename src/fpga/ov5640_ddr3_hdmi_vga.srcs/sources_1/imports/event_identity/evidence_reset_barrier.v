`timescale 1ns/1ps
// N-clock common cancellation. Release depends on raw local release chains,
// NEVER on another domain's final reset output (which would deadlock). External
// arst must reset AXI slave/arbiter too. A stopped clock holds all domains reset.
module evidence_reset_barrier #(parameter integer DOMAINS=4)(
    input wire arst,
    input wire [DOMAINS-1:0] clocks,
    output wire [DOMAINS-1:0] resets
);
    wire [DOMAINS-1:0] local_busy;
    genvar d;
    generate for(d=0;d<DOMAINS;d=d+1) begin: domain
        (* ASYNC_REG="TRUE" *) reg [2:0] release_pipe;
        (* ASYNC_REG="TRUE" *) reg [DOMAINS-1:0] busy_meta,busy_sync;
        always @(posedge clocks[d] or posedge arst) begin
            if(arst) begin release_pipe<=3'b111;busy_meta<={DOMAINS{1'b1}};busy_sync<={DOMAINS{1'b1}};end
            else begin
                release_pipe<={release_pipe[1:0],1'b0};
                busy_meta<=local_busy;busy_sync<=busy_meta;
            end
        end
        assign local_busy[d]=release_pipe[2];
        // Assertion is already asynchronous through these FF presets. Do NOT
        // OR raw arst into the consumer's synchronous reset: that recreates
        // untimed cross-clock paths from every reset cause to ordinary FF D.
        assign resets[d]=release_pipe[2] || |busy_sync;
    end endgenerate
endmodule
