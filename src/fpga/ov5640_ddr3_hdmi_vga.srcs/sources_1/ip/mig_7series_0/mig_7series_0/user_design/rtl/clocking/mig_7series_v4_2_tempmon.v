//*****************************************************************************
// (c) Copyright 2008 - 2013 Xilinx, Inc. All rights reserved.
//
// This file contains confidential and proprietary information
// of Xilinx, Inc. and is protected under U.S. and
// international copyright and other intellectual property
// laws.
//
// DISCLAIMER
// This disclaimer is not a license and does not grant any
// rights to the materials distributed herewith. Except as
// otherwise provided in a valid license issued to you by
// Xilinx, and to the maximum extent permitted by applicable
// law: (1) THESE MATERIALS ARE MADE AVAILABLE "AS IS" AND
// WITH ALL FAULTS, AND XILINX HEREBY DISCLAIMS ALL WARRANTIES
// AND CONDITIONS, EXPRESS, IMPLIED, OR STATUTORY, INCLUDING
// BUT NOT LIMITED TO WARRANTIES OF MERCHANTABILITY, NON-
// INFRINGEMENT, OR FITNESS FOR ANY PARTICULAR PURPOSE; and
// (2) Xilinx shall not be liable (whether in contract or tort,
// including negligence, or under any other theory of
// liability) for any loss or damage of any kind or nature
// related to, arising under or in connection with these
// materials, including for any direct, or any indirect,
// special, incidental, or consequential loss or damage
// (including loss of data, profits, goodwill, or any type of
// loss or damage suffered as a result of any action brought
// by a third party) even if such damage or loss was
// reasonably foreseeable or Xilinx had been advised of the
// possibility of the same.
//
// CRITICAL APPLICATIONS
// Xilinx products are not designed or intended to be fail-
// safe, or for use in any application requiring fail-safe
// performance, such as life-support or safety devices or
// systems, Class III medical devices, nuclear facilities,
// applications related to the deployment of airbags, or any
// other applications that could lead to death, personal
// injury, or severe property or environmental damage
// (individually and collectively, "Critical
// Applications"). Customer assumes the sole risk and
// liability of any use of Xilinx products in Critical
// Applications, subject only to applicable laws and
// regulations governing limitations on product liability.
//
// THIS COPYRIGHT NOTICE AND DISCLAIMER MUST BE RETAINED AS
// PART OF THIS FILE AT ALL TIMES.
//
//*****************************************************************************
//   ____  ____
//  /   /\/   /
// /___/  \  /    Vendor                : Xilinx
// \   \   \/     Version               : %version
//  \   \         Application           : MIG
//  /   /         Filename              : mig_7series_v4_2_tempmon.v
// /___/   /\     Date Last Modified    : $date$
// \   \  /  \    Date Created          : Jul 25 2012
//  \___\/\___\
//
//Device            : 7 Series
//Design Name       : DDR3 SDRAM
//Purpose           : Monitors chip temperature via the XADC and adjusts the
//                    stage 2 tap values as appropriate.
//Reference         :
//Revision History  :
//*****************************************************************************

`timescale 1 ps / 1 ps

module mig_7series_v4_2_tempmon #
(
  parameter TCQ                 = 100,        // Register delay (sim only)
  parameter TEMP_MON_CONTROL    = "INTERNAL", // XADC or user temperature source
  parameter XADC_CLK_PERIOD     = 5000,       // pS (default to 200 MHz refclk)
  parameter tTEMPSAMPLE         = 10000000    // ps (10 us)
)
(
  input           clk,                      // Fabric clock
  input           xadc_clk,
  input           rst,                      // System reset
  input   [11:0]  device_temp_i,            // User device temperature
  output wire [96:0] board_monitor,
  output  [11:0]  device_temp               // Sampled temperature
);

  //***************************************************************************
  // Function cdiv
  //  Description:
  //    This function performs ceiling division (divide and round-up)
  //  Inputs:
  //    num: integer to be divided
  //    div: divisor
  // Outputs:
  //    cdiv: result of ceiling division (num/div, rounded up)
  //***************************************************************************

  function integer cdiv (input integer num, input integer div);
    begin
      // perform division, then add 1 if and only if remainder is non-zero
      cdiv = (num/div) + (((num%div)>0) ? 1 : 0);
    end
  endfunction // cdiv

  //***************************************************************************
  // Function clogb2
  //  Description:
  //    This function performs binary logarithm and rounds up
  //  Inputs:
  //    size: integer to perform binary log upon
  // Outputs:
  //    clogb2: result of binary logarithm, rounded up
  //***************************************************************************

  function integer clogb2 (input integer size);
    begin

      size = size - 1;

      // increment clogb2 from 1 for each bit in size
      for (clogb2 = 1; size > 1; clogb2 = clogb2 + 1)
      size = size >> 1;

    end

  endfunction // clogb2

  // Synchronization registers
  (* ASYNC_REG = "TRUE" *)  reg   [11:0]  device_temp_sync_r1;
  (* ASYNC_REG = "TRUE" *)  reg   [11:0]  device_temp_sync_r2;
  (* ASYNC_REG = "TRUE" *)  reg   [11:0]  device_temp_sync_r3 /* synthesis syn_srlstyle="registers" */;
  (* ASYNC_REG = "TRUE" *)  reg   [11:0]  device_temp_sync_r4;
  (* ASYNC_REG = "TRUE" *)  reg   [11:0]  device_temp_sync_r5;

  // Output register
  (* ASYNC_REG = "TRUE" *)  reg   [11:0]  device_temp_r;

  wire                            [11:0]  device_temp_lcl;
  reg                             [3:0]   sync_cntr = 4'b0000;
  reg                                     device_temp_sync_r4_neq_r3;

 // (* ASYNC_REG = "TRUE" *)  reg rst_r1;
 // (* ASYNC_REG = "TRUE" *)  reg rst_r2;

 // // Synchronization rst to XADC clock domain
 // always @(posedge xadc_clk) begin
 //   rst_r1 <= rst;
 //   rst_r2 <= rst_r1;
 // end

  // Synchronization counter
  always @(posedge clk) begin

    device_temp_sync_r1 <= #TCQ device_temp_lcl;
    device_temp_sync_r2 <= #TCQ device_temp_sync_r1;
    device_temp_sync_r3 <= #TCQ device_temp_sync_r2;
    device_temp_sync_r4 <= #TCQ device_temp_sync_r3;
    device_temp_sync_r5 <= #TCQ device_temp_sync_r4;

    device_temp_sync_r4_neq_r3 <= #TCQ (device_temp_sync_r4 != device_temp_sync_r3) ? 1'b1 : 1'b0;

  end

  always @(posedge clk)
    if(rst || (device_temp_sync_r4_neq_r3))
      sync_cntr <= #TCQ 4'b0000;
    else if(~&sync_cntr)
      sync_cntr <= #TCQ sync_cntr + 4'b0001;

  always @(posedge clk)
    if(&sync_cntr)
      device_temp_r <= #TCQ device_temp_sync_r5;

  assign device_temp = device_temp_r;

  generate

    if(TEMP_MON_CONTROL == "EXTERNAL") begin : user_supplied_temperature

      assign device_temp_lcl = device_temp_i;
      assign board_monitor = 97'd0;

    end else begin : xadc_supplied_temperature

      // ExamGuard monitor fork: one XADC supplies original MIG temperature
      // and four on-chip telemetry channels; vendor synchronization above retained.
      (* ASYNC_REG="TRUE" *) reg [2:0] monitor_release;
      always @(posedge xadc_clk or posedge rst)
          if(rst) monitor_release<=3'b111;
          else monitor_release<={monitor_release[1:0],1'b0};
      shared_xadc_monitor shared_monitor(.clk(xadc_clk),.rst(monitor_release[2]),
          .temperature(device_temp_lcl),.monitor(board_monitor));


    end

  endgenerate

endmodule

