module ready_source_extracted(input evidence_ui_clk,reset_n,evidence_mig_raw_rst,ddr3_init_done, output ready);
     // QUALITY_READY_SOURCE_BEGIN
     // Register the combined readiness in its source UI domain. Only status
     // consumers use this level; the video/AXI reset and data path are unchanged.
     reg ddr3_ready_source;
     always @(posedge evidence_ui_clk or negedge reset_n) begin
       if (!reset_n)
         ddr3_ready_source <= 1'b0;
       else if (evidence_mig_raw_rst)
         ddr3_ready_source <= 1'b0;
       else
         ddr3_ready_source <= ddr3_init_done;
     end
     // QUALITY_READY_SOURCE_END

assign ready=ddr3_ready_source;
endmodule
