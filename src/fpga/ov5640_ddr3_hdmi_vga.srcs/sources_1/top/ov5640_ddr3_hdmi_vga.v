/////////////////////////////////////////////////////////////////////////////////
// Company       : ???????????????????
//                 http://xiaomeige.taobao.com
// Web           : http://www.corecourse.cn
// 
// Create Date   : 2019/05/01 00:00:00
// Module Name   : ov5640_ddr3_hdmi
// Description   : ??????????????????DDR3??????HDMI?????????
// 
// Dependencies  : 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
/////////////////////////////////////////////////////////////////////////////////

module ov5640_ddr3_hdmi_vga #(
    parameter COVER_DIAGNOSTICS = 0,
    // Temporary bring-up aid: when 1 the 7-seg shows live gaze counters
    // (digits 7-6 = 07 frames, 5-4 = away frames) instead of event info.
    parameter GAZE_DIAGNOSTICS  = 0
)(
  //System clock reset
  input           clk50m        , //????????????50MHz
  input           reset_n       , //??????????????
   //user keys, active low (S[0] is the existing reset button)
   input  [3:0]    key           ,
   input  [7:0]    switches      ,

   // Hiwonder WonderEcho voice assistant on the GPIO0 expansion header (P11).
   inout           voice_scl     ,
   inout           voice_sda     ,
   inout           persist_scl   ,
   inout           persist_sda   ,

   //LED
   output [2:0]    led           ,

   //board side status outputs
    output          uart_txd      ,
    input           uart_rxd      ,
    output          beep          ,
    // ACX750 RTL8211F Ethernet: RGMII TX and PHY management.
    output          eth_gtx_clk   ,
    output [3:0]    eth_txd       ,
    output          eth_txen      ,
    output          eth_rst_n     ,
    output          eth_mdc       ,
    // PHY management is now bidirectional: the FPGA restarts auto-negotiation
    // and reads BMSR / MII_STAT1000 back to confirm a gigabit link before the
    // fixed-125 MHz RGMII transmitter is released.
    inout           eth_mdio      ,

    // ExamGuard: K230 vision module ASCII UART on the GPIO0 expansion header.
    output          ai_uart_tx    ,
    input           ai_uart_rx    ,



   //8-digit seven-segment display, 74HC595 three-wire interface
   output          seg7_dio      ,
   output          seg7_rclk     ,
   output          seg7_sclk     ,

  //camera interface
  output          camera_sclk   ,
  inout           camera_sdat   ,
  input           camera_vsync  ,
  input           camera_href   ,
  input           camera_pclk   ,
  output          camera_xclk   ,
  input  [7:0]    camera_data   ,

  //hdmi interface
  output          hdmi_clk_p   ,
  output          hdmi_clk_n   ,
  output [2:0]    hdmi_dat_p   ,
  output [2:0]    hdmi_dat_n   ,
  output          hdmi_oe      ,
  //DDR3 Interface
  // Inouts
  inout  [31:0]   ddr3_dq       ,
  inout  [3:0]    ddr3_dqs_n    ,
  inout  [3:0]    ddr3_dqs_p    ,
  // Outputs      
  output [14:0]   ddr3_addr     ,
  output [2:0]    ddr3_ba       ,
  output          ddr3_ras_n    ,
  output          ddr3_cas_n    ,
  output          ddr3_we_n     ,
  output          ddr3_reset_n  ,
  output [0:0]    ddr3_ck_p     ,
  output [0:0]    ddr3_ck_n     ,
  output [0:0]    ddr3_cke      ,
  output [0:0]    ddr3_cs_n     ,
  output [3:0]    ddr3_dm       ,
  output [0:0]    ddr3_odt      ,   

  //vga output
  output  [23:0]  disp_rgb,  //vga???????????
  output          disp_hs,   //vga???????????
  output          disp_vs,   //vga???????????
  output          disp_clk,  //vga??????????
  output          disp_de   //vga??????????

);
//Resolution_1280x720  ???????????74.25MHz
parameter DISP_WIDTH  = 1280;
parameter DISP_HEIGHT = 720;
parameter PICKUP_X0 = 12'd0;
parameter PICKUP_X1 = 12'd1280;
parameter PICKUP_Y0 = 12'd0;
parameter PICKUP_Y1 = 12'd240;
parameter OPERATION_X0 = 12'd0;
parameter OPERATION_X1 = 12'd1280;
parameter OPERATION_Y0 = 12'd240;
parameter OPERATION_Y1 = 12'd480;
parameter FORBIDDEN_X0 = 12'd0;
parameter FORBIDDEN_X1 = 12'd1280;
parameter FORBIDDEN_Y0 = 12'd480;
parameter FORBIDDEN_Y1 = 12'd720;

//*********************************
//Internal connect
//*********************************
  //clock
  wire          pll_locked;
  wire          loc_clk50m;
  wire          loc_clk100m;
  wire          loc_clk24m;
  wire          loc_clk200m;
   wire          dvi_pll_locked;
    wire          pixelclk;
     wire          pixelclk5x;
    // Ethernet (RGMII TX / MDIO) clocks and resets
    wire          eth_clk125;
    wire          eth_mmcm_locked;
    wire          eth_phy_init_done;
    wire          eth_phy_tx_qualified;
    wire          phy_status_valid,phy_full_duplex;
    wire [31:0]   phy_id_raw,phy_summary;
    wire [15:0]   phy_tx_delay_raw,phy_rx_delay_raw;
    wire          eth_mac_rst_n;
    wire          eth_tx_reset_p;
    wire [15:0]   eth_phy_rddata;
   wire          eth_phy_link_up;
   wire [1:0]    eth_phy_link_speed;
   //reset
  wire          g_rst_p;
  //camera interface
  wire          camera_init_done;
  wire          pclk_bufg_o;
  wire [15:0]   image_data;
  wire          image_data_valid;
  wire          image_data_hs;
  wire          image_data_vs;
  //wr_fifo Interface
  wire          wrfifo_clr;
  wire          wrfifo_wren;
  wire [15:0]   wrfifo_din;
  //rd_fifo Interface
  wire          rdfifo_clr;
  wire          rdfifo_rden;
  wire [15 :0]  rdfifo_dout;
  //mig Interface 
  wire          ddr3_rst_n;
  wire          ddr3_init_done;
  //tft
  wire          frame_begin;

  wire [11:0]   disp_h_addr;
  wire [11:0]   disp_v_addr;
   wire          disp_data_req;
   wire [23:0]   disp_data;
   wire [23:0]   overlay_data;
  wire [7:0]    disp_red;
  wire [7:0]    disp_green;
   wire [7:0]    disp_blue;
   wire          disp_pclk;
   wire [7:0]    motion_pickup;
   wire [7:0]    motion_operation;
   wire [7:0]    motion_forbidden;
    wire [7:0]    motion_global;

    // Board communication/status clock domain signals.
     reg  [31:0]   status_frame_id;
     wire          status_src_valid;
     wire          status_fault_pixel;
     wire          status_fault_50m;
     wire          status_rst_pixel;
     wire          status_rst_50m;
     reg  [1:0]    status_reset_pixel_ff;
     reg  [1:0]    status_reset_50m_ff;
    wire          status_dst_valid;
    wire [31:0]   status_frame_id_50m;
    wire [3:0]    status_stage_id_50m;
    wire [3:0]    status_risk_level_50m;
    wire [3:0]    status_zone_id_50m;
    wire [31:0]   status_timestamp_50m;
    wire [7:0]    status_event_code_50m;
    wire [7:0]    status_motion_pickup_50m;
    wire [7:0]    status_motion_operation_50m;
    wire [7:0]    status_motion_forbidden_50m;
    wire          uart_busy;

    // Phase 1 status reservation. Later host_link logic will drive these fields.
     wire [3:0] status_stage_id;
    wire [3:0] status_risk_level;
    wire [3:0] status_zone_id;
   wire [7:0] status_event_code;
   wire       alarm_active;
   wire       warning_active;

   // User key control and its clock-domain crossings.
   wire        alarm_ack_50m;
   wire        manual_event_50m;
   wire        buzzer_mute;
   wire        workflow_reset_pixel;
   wire        manual_event_pixel;
   wire [3:0]  key_pressed;
   wire [3:0]  key_press_pulse;
   // Voice assistant (I2C master, 50 MHz domain). Its recognised words are
   // translated into the same operator pulses as S1..S3, then merged with the
   // key pulses before the existing clock-domain crossings.
   wire        voice_word_valid;
   wire [7:0]  voice_word_id;
   wire        voice_busy;
   wire        voice_nack;
   wire        voice_ack_pulse;
   wire        voice_mute_pulse;
   wire        voice_manual_pulse;
   wire [7:0]  voice_last_id;
   wire        voice_tts_req;
   wire [7:0]  voice_tts_type;
   wire [7:0]  voice_tts_id;
   wire        alarm_ack_src    = alarm_ack_50m    | voice_ack_pulse;
   wire        manual_event_src = manual_event_50m | voice_manual_pulse;
   reg  [7:0]  status_event_seq;
   wire        event_trigger_pixel;
   // Image evidence window trigger: armed by a genuinely new event or a manual
   // key press, and disarmed as soon as a window starts, so one incident does
   // not spawn a burst of identical windows.
   wire        image_event_trigger;
   wire        image_window_busy;
   wire        image_window_available;
   reg         image_trigger_armed;
   wire        event_ring_busy;
   wire        event_ring_done;
   wire        event_ring_available;
   wire        event_ring_overrun;
   wire [7:0]  event_ring_seq;
   wire [131:0] event_ring_data;
   wire        event_ring_read_valid;

   // Evidence readout and the shared UART pin.
   wire        status_uart_txd;
   wire        evidence_uart_txd;
   wire        evidence_busy;
   wire        ring_read_req;
   wire [6:0]  ring_read_index;

   // FPGA time base and the seven-segment status display.
   wire [31:0] status_timestamp_ms;
   wire [7:0]  status_event_seq_50m;
   reg  [7:0]  last_event_code_50m;
   reg  [31:0] uptime_div;
   reg  [7:0]  uptime_seconds;
   wire [31:0] seg_data;
   wire [7:0]  seg_sel;
   wire [6:0]  seg_seg;

   // Host downlink: parsed configuration and its acknowledgement.
   wire [7:0]  cfg_byte;
   wire        cfg_byte_valid;
   wire        cfg_we;
   wire [1:0]  cfg_region;
   wire [11:0] cfg_x0, cfg_y0, cfg_x1, cfg_y1;
   wire [7:0]  cfg_thr;
   wire [7:0]  cfg_version;
   wire [2:0]  cfg_status;
   wire        cfg_dst_valid;
   wire [7:0]  cfg_dst_version;
   wire [1:0]  cfg_dst_region;
   wire [11:0] cfg_dst_x0, cfg_dst_y0, cfg_dst_x1, cfg_dst_y1;
   wire [7:0]  cfg_dst_thr;
   wire        cfg_applied_50m;
   reg         cfg_applied_pulse;
   wire        cfg_ack_busy;
   wire        cfg_ack_txd;

   // Active runtime regions, initialised from the build-time defaults.
   reg  [11:0] act_pickup_x0, act_pickup_y0, act_pickup_x1, act_pickup_y1;
   reg  [11:0] act_operation_x0, act_operation_y0, act_operation_x1, act_operation_y1;
   reg  [11:0] act_forbidden_x0, act_forbidden_y0, act_forbidden_x1, act_forbidden_y1;
   reg  [7:0]  act_thr_pickup, act_thr_operation, act_thr_forbidden;
   reg  [7:0]  config_version_active;

   // Pending a validated request until the next frame boundary.
   reg         cfg_pending;
   reg  [7:0]  pend_version;
   reg  [1:0]  pend_region;
   reg  [11:0] pend_x0, pend_y0, pend_x1, pend_y1;
   reg  [7:0]  pend_thr;

   // Acknowledgement scheduling in the 50 MHz domain.
   reg         ack_waiting;
   reg         ack_trigger;
   reg         ack_pending;
   reg  [7:0]  ack_version_hold;
   reg  [2:0]  ack_status_hold;
   (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] evidence_busy_sync;
    wire        evidence_busy_50m = evidence_busy_sync[1];


   assign ddr3_rst_n = pll_locked && reset_n;
   assign g_rst_p = (~ddr3_init_done)| (~dvi_pll_locked);
    // Monitor candidate LEDs: AI alive / qualified network / fault heartbeat.
     assign status_src_valid = frame_begin;
     // status_fault_pixel / status_fault_50m are built from levels that have
     // already been synchronized into the matching clock domain (see the
     // synchronizers below), so no reset pin is driven by a combinational path
     // that starts in another domain.
     assign status_rst_pixel = status_reset_pixel_ff[1];
     assign status_rst_50m = status_reset_50m_ff[1];

     // Reset assertion follows the lock signals; release is synchronous in
     // each consumer clock domain so no combinational reset drives user flops.
     always @(posedge pixelclk or negedge reset_n) begin
       if (!reset_n)
         status_reset_pixel_ff <= 2'b11;
       else if (status_fault_pixel)
         status_reset_pixel_ff <= 2'b11;
       else
         status_reset_pixel_ff <= {status_reset_pixel_ff[0], 1'b0};
     end

     always @(posedge loc_clk50m or negedge reset_n) begin
       if (!reset_n)
         status_reset_50m_ff <= 2'b11;
       else if (status_fault_50m)
         status_reset_50m_ff <= 2'b11;
       else
         status_reset_50m_ff <= {status_reset_50m_ff[0], 1'b0};
     end

     // -----------------------------------------------------------------------
     // Reset-level synchronizers.
     //
     // ddr3_init_done is produced by the MIG in clk_pll_i; dvi_pll_locked is an
     // asynchronous MMCM output. Both used to feed the pixel/50 MHz resets
     // combinationally, which created thousands of (false) cross-domain setup
     // paths. Each bit now crosses through a two-flop synchronizer, and the
     // per-domain fault level is built only from synchronized sources.
     // -----------------------------------------------------------------------
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

     (* ASYNC_REG = "TRUE" *) reg [1:0] ddr3_ready_pixel_ff;
     (* ASYNC_REG = "TRUE" *) reg [1:0] ddr3_ready_50m_ff;
     (* ASYNC_REG = "TRUE" *) reg [1:0] dvi_locked_pixel_ff;
     (* ASYNC_REG = "TRUE" *) reg [1:0] dvi_locked_50m_ff;

     always @(posedge pixelclk or negedge reset_n) begin
       if (!reset_n) begin
         ddr3_ready_pixel_ff <= 2'b00;
         dvi_locked_pixel_ff <= 2'b00;
       end else begin
         ddr3_ready_pixel_ff <= {ddr3_ready_pixel_ff[0], ddr3_ready_source};
         dvi_locked_pixel_ff <= {dvi_locked_pixel_ff[0], dvi_pll_locked};
       end
     end

     always @(posedge loc_clk50m or negedge reset_n) begin
       if (!reset_n) begin
         ddr3_ready_50m_ff <= 2'b00;
         dvi_locked_50m_ff <= 2'b00;
       end else begin
         ddr3_ready_50m_ff <= {ddr3_ready_50m_ff[0], ddr3_ready_source};
         dvi_locked_50m_ff <= {dvi_locked_50m_ff[0], dvi_pll_locked};
       end
     end

     assign status_fault_pixel = (~pll_locked) | (~ddr3_ready_pixel_ff[1]) |
                                  (~dvi_locked_pixel_ff[1]);
     assign status_fault_50m   = (~pll_locked) | (~ddr3_ready_50m_ff[1]) |
                                  (~dvi_locked_50m_ff[1]);

     always @(posedge pixelclk) begin
       if (status_rst_pixel)
         status_frame_id <= 32'd0;
       else if (frame_begin)
         status_frame_id <= status_frame_id + 32'd1;
     end

     // A new incident is a change of the event code to a different non-zero
     // value. Detecting the change directly (rather than an episode timer) means
     // an event that occurs while a previous one is still held is not missed --
     // this was why a covered camera (0x64) could be shown on the panel but not
     // arm an evidence window.
     reg [7:0] last_event_code_px;
     wire new_event_code = (status_event_code != 8'd0) &&
                           (status_event_code != last_event_code_px);

     always @(posedge pixelclk) begin
       if (status_rst_pixel)
         last_event_code_px <= 8'd0;
       else if (status_event_code != last_event_code_px)
         last_event_code_px <= status_event_code;
     end

     // Hold the new-event flag until a frame boundary so the frame-sampled
     // evidence consumers cannot miss the one-clock change pulse.
     reg new_event_pending;
     always @(posedge pixelclk) begin
       if (status_rst_pixel)
         new_event_pending <= 1'b0;
       else if (new_event_code)
         new_event_pending <= 1'b1;
       else if (frame_begin)
         new_event_pending <= 1'b0;
     end

     always @(posedge pixelclk) begin
       if (status_rst_pixel)
         status_event_seq <= 8'd0;
       else if (new_event_code)
         status_event_seq <= status_event_seq + 8'd1;
     end

     // Monotonic millisecond time base in the pixel domain. It feeds both the
     // evidence ring and, through the status mailbox, the UART packets.
     timestamp_ms #(
       .CLK_HZ (74250000)
     ) timestamp_ms_inst (
       .clk          (pixelclk),
       .rst          (status_rst_pixel),
       .timestamp_ms (status_timestamp_ms)
     );

  pll pll
  (
    // Clock out ports
    .clk_out1 (loc_clk50m   ), // output clk_out1
    .clk_out2 (loc_clk200m  ), // output clk_out2
    .clk_out3 (loc_clk100m  ), // output clk_out3
    .clk_out4 (loc_clk24m   ), // output clk_out3
    // Status and control signals
    .resetn   (reset_n      ), // input reset
    .locked   (pll_locked   ), // output locked
    // Clock in ports
    .clk_in1  (clk50m       )  // input clk_in1
  );

   dvi_pll dvi_pll
  (
    // Clock out ports
    .clk_out1(pixelclk       ),// output clk_out1
    .clk_out2(pixelclk5x     ),// output clk_out2
    // Status and control signals
    .resetn  (reset_n        ),// input reset
    .locked  (dvi_pll_locked ),// output locked
    // Clock in ports
    .clk_in1 (loc_clk100m    ) // input clk_in1
   );

   // ------------------------------------------------------------------------
   // ACX750 RTL8211F Ethernet: 125 MHz TX clock, PHY management and the image
   // evidence path. Low-resolution evidence frames are captured in the pixel
   // domain (BRAM ring), serialised through a one-byte CDC, then driven into
   // the ACX750 UDP transmitter in the 125 MHz domain.
   // ------------------------------------------------------------------------
   wire eth_mmcm_fb;
   wire eth_clk125_unbuf;
   MMCME2_BASE #(
     .BANDWIDTH("OPTIMIZED"),
     .CLKFBOUT_MULT_F(20.0),
     .CLKIN1_PERIOD(20.0),
     .CLKOUT0_DIVIDE_F(8.0),
     .DIVCLK_DIVIDE(1),
     .STARTUP_WAIT("FALSE")
   ) eth_mmcm (
     .CLKIN1  (loc_clk50m),
     .CLKFBIN (eth_mmcm_fb),
     .RST     (~reset_n | ~pll_locked),
     .PWRDWN  (1'b0),
     .CLKOUT0 (eth_clk125_unbuf),
     .CLKFBOUT(eth_mmcm_fb),
     .LOCKED  (eth_mmcm_locked)
   );
   BUFG eth_clk125_bufg (.I(eth_clk125_unbuf), .O(eth_clk125));

   phy_reg_config #(
     .speed    (2'b10),
     .SYS_CLOCK(50000000),
     .MDC_CLOCK(2000),
     .MAX_CNT  (2)
    ) eth_phy_reg_config_inst (
      .clk          (loc_clk50m),
      .rst_n        (reset_n && pll_locked),
     .phy_rst_n    (eth_rst_n),
     .rddata       (eth_phy_rddata),
      .phy_init_done(eth_phy_init_done),
      .tx_qualified (eth_phy_tx_qualified),
      .status_valid(phy_status_valid),.phy_id(phy_id_raw),.full_duplex(phy_full_duplex),
      .tx_delay_raw(phy_tx_delay_raw),.rx_delay_raw(phy_rx_delay_raw),
     .link_up      (eth_phy_link_up),
     .link_speed   (eth_phy_link_speed),
     .mdc          (eth_mdc),
     .mdio         (eth_mdio)
   );

    phy_health_snapshot phy_health_inst(.clk(loc_clk50m),.mdc(eth_mdc),.arst(!reset_n || !pll_locked),
        .status_valid(phy_status_valid),.link_up(eth_phy_link_up),.full_duplex(phy_full_duplex),.link_speed(eth_phy_link_speed),
        .phy_id(phy_id_raw),.tx_delay_raw(phy_tx_delay_raw),.rx_delay_raw(phy_rx_delay_raw),.summary(phy_summary));

    assign eth_tx_reset_p = (~reset_n) | (~pll_locked) |
                            (~eth_mmcm_locked) | (~eth_phy_init_done);

   // --- Byte CDC pixel -> 125 MHz for the serialised evidence window ---
   wire        evt_byte_valid;
   wire [7:0]  evt_byte_data;
   wire        evt_byte_ack;
   wire        cap_out_valid;
   wire [7:0]  cap_out_data;
   wire        cap_out_ready;

   generate if (0) begin: legacy_image_udp
   cdc_byte_channel image_evidence_byte_cdc (
     .src_clk  (pixelclk),
     .src_rst  (status_rst_pixel),
     .src_valid(cap_out_valid),
     .src_data (cap_out_data),
     .src_ready(cap_out_ready),
     .dst_clk  (eth_clk125),
     .dst_rst  (eth_tx_reset_p),
     .dst_valid(evt_byte_valid),
     .dst_data (evt_byte_data),
     .dst_ack  (evt_byte_ack)
   );

   // --- 125 MHz header parser / per-frame driver for the UDP bridge ---
   wire        eth_start_frame;
   wire [7:0]  eth_event_seq;
   wire [7:0]  eth_frame_index;
   wire [15:0] eth_frame_count;
   wire [31:0] eth_frame_id;
   wire [31:0] eth_timestamp_ms;
   wire [7:0]  eth_config_version;
   wire [15:0] eth_frame_width;
   wire [15:0] eth_frame_height;
   wire [31:0] eth_frame_length;
   wire        eth_start_ready;
   wire        eth_frame_byte_valid;
   wire [7:0]  eth_frame_byte;
   wire        eth_frame_byte_ready;

   image_evidence_udp_source #(
     .FRAME_WIDTH  (160),
     .FRAME_HEIGHT (90),
     .WINDOW_LENGTH(17)
   ) image_evidence_udp_source_inst (
     .clk125m         (eth_clk125),
     .reset_p         (eth_tx_reset_p),
     .byte_valid      (evt_byte_valid),
     .byte_data       (evt_byte_data),
     .byte_ack        (evt_byte_ack),
     .start_frame     (eth_start_frame),
     .event_seq       (eth_event_seq),
     .frame_index     (eth_frame_index),
     .frame_count     (eth_frame_count),
     .frame_id        (eth_frame_id),
     .timestamp_ms    (eth_timestamp_ms),
     .config_version  (eth_config_version),
     .frame_width     (eth_frame_width),
     .frame_height    (eth_frame_height),
     .frame_length    (eth_frame_length),
     .start_ready     (eth_start_ready),
     .frame_byte_valid(eth_frame_byte_valid),
     .frame_byte      (eth_frame_byte),
     .frame_byte_ready(eth_frame_byte_ready),
     .busy            ()
   );

   image_evidence_udp_acx750_tx #(
     .DST_MAC          (48'hff_ff_ff_ff_ff_ff),
     .SRC_MAC          (48'h02_00_00_00_00_02),
     .DST_IP           (32'hc0_a8_00_03),
     .SRC_IP           (32'hc0_a8_00_02),
     .DST_PORT         (16'd6102),
     .SRC_PORT         (16'd5000),
     .MAX_PAYLOAD_BYTES(1024),
     .MAX_PACKET_BYTES (1060)
   ) image_evidence_udp_acx750_tx_inst (
     .clk125m         (eth_clk125),
     .reset_p         (eth_tx_reset_p),
     .start_frame     (eth_start_frame),
     .event_seq       (eth_event_seq),
     .frame_index     (eth_frame_index),
     .frame_count     (eth_frame_count),
     .frame_id        (eth_frame_id),
     .timestamp_ms    (eth_timestamp_ms),
     .config_version  (eth_config_version),
     .frame_width     (eth_frame_width),
     .frame_height    (eth_frame_height),
     .frame_length    (eth_frame_length),
     .start_ready     (eth_start_ready),
     .frame_byte_valid(eth_frame_byte_valid),
     .frame_byte      (eth_frame_byte),
     .frame_byte_ready(eth_frame_byte_ready),
     .frame_done      (),
     .eth_rst_n       (eth_mac_rst_n),
     .rgmii_gtxc      (eth_gtx_clk),
     .rgmii_txd       (eth_txd),
     .rgmii_txen      (eth_txen)
   );


   end endgenerate
   assign cap_out_ready = 1'b1;
   assign camera_xclk = loc_clk24m;

    camera_init
  #(
    .CAMERA_TYPE    ( "ov5640"     ),//"ov5640" or "ov7725"
    .IMAGE_TYPE     ( 0            ),// 0: RGB; 1: JPEG
    .IMAGE_WIDTH    ( DISP_WIDTH  ),// ????????
    .IMAGE_HEIGHT   ( DISP_HEIGHT ),// ??????
    .IMAGE_FLIP_EN  ( 0            ),// 0: ??????????1: ????????
    .IMAGE_MIRROR_EN( 0            ) // 0: ?????????1: ??????????
  )camera_init
  (
    .Clk         (loc_clk50m        ),
    .Rst_n       (~status_rst_50m   ),
    .Init_Done   (camera_init_done  ),
    .camera_rst_n(                  ),
    .camera_pwdn (                  ),
    .i2c_sclk    (camera_sclk       ),
    .i2c_sdat    (camera_sdat       )
  );

  BUFG BUFG_inst (
    .O(pclk_bufg_o ), // 1-bit output: Clock output
    .I(camera_pclk )  // 1-bit input: Clock input
  );

   // Hold capture reset while PCLK is stopped, catch short raw faults, and
   // release only after three clean PCLK edges. This is independent of SOF
   // and does not feed back into the common MIG/transport reset barrier.
   wire camera_capture_rst;
   video_epoch_clear camera_capture_reset_inst(
     .ui_clk(pclk_bufg_o),.ui_rst(1'b0),
     .source_clear(g_rst_p || !reset_n),.fifo_ui_rst_busy(1'b0),
     .client_clear(camera_capture_rst));
   DVP_Capture DVP_Capture(
     .Rst_p      (camera_capture_rst),//input
    .PCLK       (pclk_bufg_o      ),//input
    .Vsync      (camera_vsync     ),//input
    .Href       (camera_href      ),//input
    .Data       (camera_data      ),//input     [7:0]

    .ImageState (                 ),//output reg
    .DataValid  (image_data_valid ),//output
    .DataPixel  (image_data       ),//output    [15:0]
    .DataHs     (image_data_hs    ),//output
    .DataVs     (image_data_vs    ),//output
    .Xaddr      (                 ),//output    [11:0]
    .Yaddr      (                 ) //output    [11:0]
  );

//---------------------------------------------
//??????????????????????????????????????sim_dat_gen???????????????
//????????????????????sim_dat_gen???????DVP_Capture??????????
//---------------------------------------------
//  sim_dat_gen #(
//    .DISP_WIDTH  (DISP_WIDTH   ),
//    .DISP_HEIGHT (DISP_HEIGHT  ),
//    .DATA_WIDTH  (16           )
//  )
//  sim_dat_gen(
//    .clk          (pclk_bufg_o     ),
//    .reset        (g_rst_p         ),
//    .gen_en       (camera_init_done),
//    .sim_dat      (image_data      ),
//    .sim_dat_vaild(image_data_valid)
//  );
//-------------------------------------------

  assign wrfifo_wren = image_data_valid;
  assign wrfifo_din = image_data;
  assign wrfifo_clr = ~camera_init_done;
  assign rdfifo_clr = frame_begin;

  assign disp_data = {rdfifo_dout[15:11],rdfifo_dout[15:13],rdfifo_dout[10:5],rdfifo_dout[10:9],rdfifo_dout[4:0],rdfifo_dout[4:2]};
  assign rdfifo_rden = disp_data_req;

	wire [11:0] H_Addr;
	wire [11:0] V_Addr;
	
  	disp_driver #(
        .AHEAD_CLK_CNT ( 1 )
    )disp_driver(
		.ClkDisp		(pixelclk				),
        .Rst_n          (~status_rst_pixel      ),
		.Data			(disp_data              ),
		.DataReq		(disp_data_req	    	),
		.H_Addr			(H_Addr					),
		.V_Addr			(V_Addr					),
		.Disp_HS		(disp_hs				),
		.Disp_VS		(disp_vs				),
		.Disp_Red		(disp_red				),
		.Disp_Green		(disp_green				),
		.Disp_Blue		(disp_blue				),
		.Disp_Sof       (frame_begin            ),
		.Disp_DE		(disp_de				),
		.Disp_PCLK		(disp_clk 				)
	);

    // Luma-preserving colour enrichment on the display stream, applied before
    // the status overlay. Grey level is preserved, so the frame-difference
    // motion detector is unaffected.
    wire [7:0]  enh_r, enh_g, enh_b;
    wire [11:0] enh_x, enh_y;
    wire        enh_de, enh_sof;
    color_enhance #(
        .SAT (320)
    ) color_enhance_inst (
        .clk     (pixelclk),
        .rst     (status_rst_pixel),
        .pixel_r (disp_red),
        .pixel_g (disp_green),
        .pixel_b (disp_blue),
        .x       (H_Addr),
        .y       (V_Addr),
        .de      (disp_de),
        .sof     (frame_begin),
        .enh_r   (enh_r),
        .enh_g   (enh_g),
        .enh_b   (enh_b),
        .enh_x   (enh_x),
        .enh_y   (enh_y),
        .enh_de  (enh_de),
        .enh_sof (enh_sof)
    );


    // Low-resolution evidence capture: taps the (pre-overlay) display pixels,
    // builds a 160x90 GRAY8 ring, and serialises a completed event window to
    // the byte CDC instantiated in the Ethernet block.
    wire image_window_overrun;
    generate if (0) begin: legacy_image_capture
    image_evidence_capture #(
       .FRAME_WIDTH (160),
       .FRAME_HEIGHT(90),
       .PRE_FRAMES  (8),
       .POST_FRAMES (8),
       .RING_DEPTH  (32)
    ) image_evidence_capture_inst (
       .clk                 (pixelclk),
       .rst                 (status_rst_pixel),
       .pixel_r             (enh_r),
       .pixel_g             (enh_g),
       .pixel_b             (enh_b),
       .x                   (enh_x),
       .y                   (enh_y),
       .de                  (enh_de),
       .sof                 (enh_sof),
       .meta_frame_id       (status_frame_id),
       .meta_timestamp_ms   (status_timestamp_ms),
       .meta_config_version (config_version_active),
       .meta_event_seq      (status_event_seq),
       .event_trigger       (image_event_trigger),
       .out_valid           (cap_out_valid),
       .out_data            (cap_out_data),
       .out_ready           (cap_out_ready),
       .window_available    (image_window_available),
       .window_busy         (image_window_busy),
       .window_overrun      (image_window_overrun),
       .snapshot_event_seq  ()
    );

    end endgenerate
    assign cap_out_valid=1'b0;
    assign cap_out_data=8'd0;
    assign image_window_available=1'b0;
    assign image_window_busy=1'b0;
    assign image_window_overrun=1'b0;

    // A dropped event (window already in progress) is a sticky level in the
    // ring; turn its first rising edge into a pulse and cross it to 50 MHz for
    // the health monitor. Best-effort: one pulse per power cycle.
    reg  image_overrun_seen_px;
    wire image_overrun_pulse_px = image_window_overrun & ~image_overrun_seen_px;
    always @(posedge pixelclk) begin
        if (status_rst_pixel) image_overrun_seen_px <= 1'b0;
        else if (image_window_overrun) image_overrun_seen_px <= 1'b1;
    end
    wire image_overrun_pulse_50m;
    pulse_cdc pulse_cdc_image_overrun (
        .src_clk   (pixelclk),
        .src_rst   (status_rst_pixel),
        .src_pulse (image_overrun_pulse_px),
        .dst_clk   (loc_clk50m),
        .dst_rst   (status_rst_50m),
        .dst_pulse (image_overrun_pulse_50m)
    );

    // --- ExamGuard full-frame activity (parallel observer, no fixed 3 ROI) ---
    wire [7:0]  fs_activity_pixel;
    wire [15:0] fs_cells_pixel;
    wire [7:0]  fs_luma_pixel;
    wire cover98_pixel;
    camera_black_gate #(.WIDTH(1280),.HEIGHT(720),.BLACK_MAX(8'd31),
        .BLACK_PERCENT(98),.CONFIRM_FRAMES(30),.RELEASE_FRAMES(3)) cover98_inst (
        .clk(pixelclk),.rst(status_rst_pixel || workflow_reset_pixel),
        .sof(enh_sof),.de(enh_de),.x(enh_x),.y(enh_y),
        .pixel({enh_r,enh_g,enh_b}),.covered(cover98_pixel),.frame_valid(),.frame_is_black());
    // A single stable episode level crosses domains; never an unsynchronised bus.
    (* ASYNC_REG="TRUE" *) reg [1:0] cover98_sync;
    always @(posedge loc_clk50m) begin
        if(status_rst_50m) cover98_sync <= 2'b00;
        else cover98_sync <= {cover98_sync[0],cover98_pixel};
    end
    fullscreen_monitor #(
        .SAMPLE_SHIFT(4),
        .GRID_WIDTH  (80),
        .GRID_HEIGHT (45),
        .SCORE_SHIFT (4),
        .NOISE_FLOOR (8'd8)
    ) fullscreen_monitor_inst (
        .clk            (pixelclk),
        .rst            (status_rst_pixel),
        .pixel_in       ({enh_r, enh_g, enh_b}),
        .x              (enh_x),
        .y              (enh_y),
        .de             (enh_de),
        .sof            (enh_sof),
        .activity_global(fs_activity_pixel),
        .active_cells   (fs_cells_pixel),
        .luma_avg       (fs_luma_pixel)
    );

    wire        fs_frame_50m;
    wire [7:0]  fs_activity_50m;
    wire [15:0] fs_cells_50m;
    wire [7:0]  fs_luma_50m;
    wire [7:0]  cover_debug_luma, cover_debug_base, cover_debug_flags;
    cdc_frame_activity cdc_frame_activity_inst (
        .src_clk     (pixelclk),
        .src_rst     (status_rst_pixel),
        .src_frame   (enh_sof),
        .src_activity(fs_activity_pixel),
        .src_cells   (fs_cells_pixel),
        .src_luma    (fs_luma_pixel),
        .dst_clk     (loc_clk50m),
        .dst_rst     (status_rst_50m),
        .dst_pulse   (fs_frame_50m),
        .dst_activity(fs_activity_50m),
        .dst_cells   (fs_cells_50m),
        .dst_luma    (fs_luma_50m)
    );

    motion_detect motion_detect_inst (
       .clk         (pixelclk),
       .rst         (status_rst_pixel),
       .pixel_in    ({enh_r, enh_g, enh_b}),
       .x           (enh_x),
       .y           (enh_y),
       .de          (enh_de),
       .sof         (enh_sof),
       .roi_pickup_x0    (act_pickup_x0),
       .roi_pickup_y0    (act_pickup_y0),
       .roi_pickup_x1    (act_pickup_x1),
       .roi_pickup_y1    (act_pickup_y1),
       .roi_operation_x0 (act_operation_x0),
       .roi_operation_y0 (act_operation_y0),
       .roi_operation_x1 (act_operation_x1),
       .roi_operation_y1 (act_operation_y1),
       .roi_forbidden_x0 (act_forbidden_x0),
       .roi_forbidden_y0 (act_forbidden_y0),
       .roi_forbidden_x1 (act_forbidden_x1),
       .roi_forbidden_y1 (act_forbidden_y1),
       .thr_pickup       (act_thr_pickup),
       .thr_operation    (act_thr_operation),
       .thr_forbidden    (act_thr_forbidden),
     .motion_pickup    (motion_pickup),
     .motion_operation (motion_operation),
     .motion_forbidden (motion_forbidden),
     .motion_global    (motion_global)
    );

     // ExamGuard: workflow_fsm retired from the status chain. The exam FSM
     // (50 MHz domain) drives stage / risk / event through cdc_exam_status.

     alarm_output alarm_output_inst (
       .risk_level     (status_risk_level),
       .alarm_active   (alarm_active),
       .warning_active (warning_active)
     );

     status_mailbox status_mailbox_inst (
       .src_clk              (pixelclk),
       .src_rst              (status_rst_pixel),
       .src_valid            (status_src_valid),
       .src_frame_id         (status_frame_id),
       .src_stage_id         (status_stage_id),
       .src_risk_level       (status_risk_level),
       .src_zone_id          (status_zone_id),
       .src_timestamp        (status_timestamp_ms),
       .src_event_code       (status_event_code),
       .src_event_seq        (status_event_seq),
       .src_motion_pickup    (motion_pickup),
       .src_motion_operation (motion_operation),
       .src_motion_forbidden (motion_forbidden),
       .dst_clk              (loc_clk50m),
       .dst_rst              (status_rst_50m),
       .dst_valid            (status_dst_valid),
       .dst_frame_id         (status_frame_id_50m),
       .dst_stage_id         (status_stage_id_50m),
       .dst_risk_level       (status_risk_level_50m),
       .dst_zone_id          (status_zone_id_50m),
       .dst_timestamp        (status_timestamp_50m),
       .dst_event_code       (status_event_code_50m),
       .dst_event_seq        (status_event_seq_50m),
       .dst_motion_pickup    (status_motion_pickup_50m),
       .dst_motion_operation (status_motion_operation_50m),
       .dst_motion_forbidden (status_motion_forbidden_50m)
     );

     // ---------------------------------------------------------------------
     // C01 event identity (independent module, additive).
     // Provides a device id, a per-power-cycle boot id, a per-exam session id
     // and a monotonic ms clock, plus a monotonic 64-bit event uid. The uid is
     // stamped onto each AL/EI pair. This does NOT persist across power loss
     // (no EEPROM/RTC yet); see docs/verification_2026-10-12_event_identity.md.
     // ---------------------------------------------------------------------
     localparam [31:0] IDENT_DEVICE_STRAPS = 32'h0000_0001;
     reg  [15:0] ident_ms_div;
     wire        ident_ms_tick = (ident_ms_div == 16'd49999); // 1 ms at 50 MHz
     reg  [7:0]  ident_prev_event_50m;
     wire        ident_new_event_50m = persistent_admission && status_dst_valid &&
                                       (status_event_code_50m != 8'd0) &&
                                       (status_event_code_50m != ident_prev_event_50m);
     reg  [2:0]  ident_prev_stage_50m;
     wire        ident_session_start = (status_stage_id_50m[2:0] == 3'd3) &&
                                       (ident_prev_stage_50m != 3'd3);
     wire        ident_session_end   = (status_stage_id_50m[2:0] == 3'd4) &&
                                       (ident_prev_stage_50m != 3'd4);
     wire [31:0] ident_device_id;
     wire [31:0] ident_boot_id;
     wire [31:0] ident_session_id;
     wire [63:0] ident_time_ms;
     wire        ident_session_active;
     reg  [63:0] ident_uid;
     wire [63:0] ident_uid_assign = (ident_uid == {64{1'b1}}) ? ident_uid : ident_uid + 64'd1;

     // C04 health flags (camera freeze / K230 silence / evidence busy / overrun),
     // produced by health_monitor below and appended to every ST packet.
      wire [7:0] health_flags;
      wire [7:0] base_health_flags;
       wire [7:0] uart_stream_valid,uart_stream_last,uart_stream_ready;
       wire [63:0] uart_stream_data;
       (* keep = "true" *) wire [2:0] exam_stage;
       localparam [15:0] EXAM_LEN_S = 16'd2700;
       wire [15:0] exam_display_duration;
       wire operator_mute;
      wire [63:0] ev_time;
      wire persistent_admission,persistent_done,persistent_active_slot;
      (* keep="true" *) wire [3:0] persistent_error;
      (* keep="true" *) wire [31:0] persistent_boot,persistent_generation;
      wire persistent_scl_low,persistent_sda_low;
      assign persist_scl=persistent_scl_low?1'b0:1'bz;
      assign persist_sda=persistent_sda_low?1'b0:1'bz;
       wire maint_request,maint_ready,maint_busy,maint_result,maint_result_ready,maint_pending;
       wire [1:0] maint_opcode,maint_result_opcode,maint_recovery;
       wire [3:0] maint_error,maint_detail,maint_store_error;
       wire [255:0] maint_proposed,profile_data;
       wire [55:0] maint_calendar;
       wire [71:0] maint_snapshot;
       wire maint_write_attempted,profile_known,profile_valid,profile_default_mute;
       wire [31:0] profile_generation,profile_seat;
       wire [15:0] profile_duration;
       wire [96:0] raw_board_monitor,held_board_monitor;
       wire monitor_snapshot_valid;wire [31:0] monitor_age;
       wire [31:0] effective_seat;wire straps_valid;wire [7:0] latched_switches;
       (* ASYNC_REG="TRUE" *) reg [2:0] monitor_reset_pipe;
       (* ASYNC_REG="TRUE" *) reg [1:0] monitor_network_pipe;
       always @(posedge loc_clk200m or posedge status_rst_50m)
           if(status_rst_50m) monitor_reset_pipe<=3'b111;
           else monitor_reset_pipe<={monitor_reset_pipe[1:0],1'b0};
       always @(posedge loc_clk50m)
           if(status_rst_50m) monitor_network_pipe<=0;
           else monitor_network_pipe<={monitor_network_pipe[0],eth_phy_tx_qualified};
       board_status_control board_status_inst(.clk(loc_clk50m),.rst(status_rst_50m),.switches(switches),
           .config_known(profile_known && profile_valid),.configured_seat(profile_seat),
           .ai_alive(!base_health_flags[1]),.network_qualified(monitor_network_pipe[1]),.evidence_fault(base_health_flags[3]),
           .straps_valid(straps_valid),.latched_switches(latched_switches),.seat_id(effective_seat),.led(led));
       cdc_stats_snapshot #(.WIDTH(97)) monitor_snapshot(.src_clk(loc_clk200m),.dst_clk(loc_clk50m),
           .src_rst(monitor_reset_pipe[2]),.dst_rst(status_rst_50m),.src_stats(raw_board_monitor),
           .stats(held_board_monitor),.valid(monitor_snapshot_valid),.age_cycles(monitor_age));
       board_monitor_record monitor_record(.clk(loc_clk50m),.rst(status_rst_50m),.monitor(held_board_monitor),
           .monitor_valid(monitor_snapshot_valid),.device_id(IDENT_DEVICE_STRAPS),.boot_id(persistent_boot),
           .seat_id(effective_seat),.monotonic_ms(ev_time),.straps_valid(straps_valid),.switches(latched_switches),
           .byte_valid(uart_stream_valid[6]),.byte_last(uart_stream_last[6]),
           .byte_data(uart_stream_data[55:48]),.byte_ready(uart_stream_ready[6]));
       wire maintenance_allowed=(exam_stage!=3) && (exam_stage!=4);
       persistent_maintenance_service persistent_boot_inst(.clk(loc_clk50m),.rst(status_rst_50m),.expected_device(IDENT_DEVICE_STRAPS),
          .monotonic_ms(ev_time),.rtc_known(),.rtc_fresh(),.rtc_age_cycles(),
          .byte_valid(uart_stream_valid[4]),.byte_last(uart_stream_last[4]),
          .byte_data(uart_stream_data[39:32]),.byte_ready(uart_stream_ready[4]),
          .scl_i(persist_scl),.sda_i(persist_sda),.scl_low(persistent_scl_low),.sda_low(persistent_sda_low),
          .admission(persistent_admission),.done(persistent_done),.error(persistent_error),
           .boot_id(persistent_boot),.generation(persistent_generation),.active_slot(persistent_active_slot),
           .request_valid(maint_request),.request_ready(maint_ready),.opcode(maint_opcode),
           .maintenance_allowed(maintenance_allowed),.proposed_config(maint_proposed),.calendar_data(maint_calendar),
           .maintenance_busy(maint_busy),.result_valid(maint_result),.result_ready(maint_result_ready),
           .result_opcode(maint_result_opcode),.result_error(maint_error),.result_detail(maint_detail),
           .result_store_error(maint_store_error),.result_recovery_error(maint_recovery),
           .result_write_attempted(maint_write_attempted),.result_snapshot(maint_snapshot),
           .config_known(profile_known),.active_config(profile_data),.config_generation(profile_generation));
       persistent_config_decode profile_decode(.config_data(profile_data),.valid(profile_valid),.legacy_defaults(),
           .seat_id(profile_seat),.exam_duration_s(profile_duration),.rtc_offset_known(),.rtc_offset_minutes(),.mute(profile_default_mute));
       maintenance_endpoint maintenance_endpoint_inst(.clk(loc_clk50m),.rst(status_rst_50m),
           .rx_valid(cfg_byte_valid),.rx_data(cfg_byte),.device_id(IDENT_DEVICE_STRAPS),.boot_id(persistent_boot),
           .generation(persistent_generation),.boot_done(persistent_done),
           .config_known(profile_known),.active_config(profile_data),.request_valid(maint_request),.request_ready(maint_ready),
           .opcode(maint_opcode),.proposed_config(maint_proposed),.calendar_data(maint_calendar),
           .result_valid(maint_result),.result_ready(maint_result_ready),.result_opcode(maint_result_opcode),
           .result_recovery_error(maint_recovery),.result_error(maint_error),.result_detail(maint_detail),
           .result_store_error(maint_store_error),.result_write_attempted(maint_write_attempted),.result_snapshot(maint_snapshot),
           .byte_valid(uart_stream_valid[5]),.byte_last(uart_stream_last[5]),
           .byte_data(uart_stream_data[47:40]),.byte_ready(uart_stream_ready[5]),.command_pending(maint_pending),.rejected_lines());
      assign health_flags=base_health_flags | (!persistent_done?8'h10:8'd0) |
          (persistent_done && !persistent_admission?8'h20:8'd0);

     event_identity #(
       .ID_WIDTH (32)
     ) event_identity_inst (
       .clk               (loc_clk50m),
       .rst               (status_rst_50m),
       .ms_tick           (ident_ms_tick),
       .device_straps     (IDENT_DEVICE_STRAPS),
       .boot_pulse        (1'b0),
       .session_start     (ident_session_start),
       .session_end       (ident_session_end),
       .device_id         (ident_device_id),
        .boot_id           (),
       .session_id        (ident_session_id),
       .time_ms           (ident_time_ms),
       .session_active    (ident_session_active),
       .boot_event        (),
       .session_event     (),
       .started_count     (),
       .ignored_start_count()
      );

      assign ident_boot_id=persistent_admission?persistent_boot:32'd0;

     always @(posedge loc_clk50m) begin
       if (status_rst_50m) begin
         ident_ms_div         <= 16'd0;
         ident_prev_event_50m <= 8'd0;
         ident_prev_stage_50m <= 3'd0;
         ident_uid            <= 64'd0;
       end else begin
         ident_ms_div         <= ident_ms_tick ? 16'd0 : ident_ms_div + 16'd1;
         ident_prev_stage_50m <= status_stage_id_50m[2:0];
         // Mirror status_uart_tx's re-arm: an event code returning to 0 clears
         // the active code, so the SAME code firing again is a new event and
         // must advance the uid too. Without this a "0x64 -> 0 -> 0x64" pair
         // reused the previous uid (observed on board, uid repeated).
          if (status_dst_valid && persistent_admission) begin
           if (status_event_code_50m == 8'd0)
             ident_prev_event_50m <= 8'd0;
           else if (status_event_code_50m != ident_prev_event_50m)
             ident_prev_event_50m <= status_event_code_50m;
         end
         if (ident_new_event_50m)
           ident_uid <= ident_uid_assign;
       end
     end

      (* keep = "true" *) wire [15:0] exam_remaining_s;
      wire [1023:0] ev_health_report;

      status_uart_tx #(
       .CLK_FREQ_HZ          (50000000),
       .BAUD_RATE            (115200),
        .STATUS_PERIOD_CYCLES (5000000),
         .ENABLE_TIMER         (1),
         .ENABLE_EVIDENCE_HEALTH(1),
         .STREAM_OUTPUT(1)
     ) status_uart_tx_inst (
       .clk                   (loc_clk50m),
       .rst                   (status_rst_50m),
       .status_valid          (status_dst_valid),
       .status_frame_id       (status_frame_id_50m),
        .status_stage_id       ({1'b0, exam_stage}),
       .status_risk_level     (status_risk_level_50m),
       .status_zone_id        (status_zone_id_50m),
       .status_timestamp      (status_timestamp_50m),
        .status_event_code     (persistent_admission ? status_event_code_50m : 8'd0),
        // [DEBUG-cover] Diagnostic build reuses ST's three legacy ROI fields.
        .status_motion_pickup  (COVER_DIAGNOSTICS ? cover_debug_luma : status_motion_pickup_50m),
        .status_motion_operation(COVER_DIAGNOSTICS ? cover_debug_base : status_motion_operation_50m),
        .status_motion_forbidden(COVER_DIAGNOSTICS ? cover_debug_flags : status_motion_forbidden_50m),
       .event_device_id       (ident_device_id),
       .event_boot_id         (ident_boot_id),
       .event_session_id      (ident_session_id),
       .event_uid             (ident_uid_assign),
       .event_seq             (status_event_seq_50m),
        .health_flags          (health_flags),
        .remaining_s           (exam_remaining_s),
          .exam_duration_s       (exam_display_duration),
         .evidence_health_data  (ev_health_report),
       .uart_txd              (status_uart_txd),
        .uart_busy             (uart_busy),
        .stream_valid(uart_stream_valid[0]),.stream_last(uart_stream_last[0]),
        .stream_data(uart_stream_data[7:0]),.stream_ready(uart_stream_ready[0])
     );

     alarm_beep #(
       .CLOCK_HZ       (50000000),
       .TONE_HZ        (2000),
       .WARNING_ON_MS  (150),
       .WARNING_OFF_MS (850)
     ) alarm_beep_inst (
       .clk            (loc_clk50m),
       .rst            (status_rst_50m),
       .warning_active (status_risk_level_50m == 4'd1),
       .alarm_active   (status_risk_level_50m >= 4'd2),
       .mute           (buzzer_mute),
       .beep           (beep)
     );

     // Operator key panel runs on the stable 50 MHz domain shared with the
     // buzzer and the UART transmitter.
     user_control #(
       .CLK_FREQ_HZ (50000000),
       .DEBOUNCE_MS (10)
     ) user_control_inst (
       .clk                (loc_clk50m),
       .rst                (status_rst_50m),
       .key                (key),
       .mute_toggle_pulse  (voice_mute_pulse),
       .alarm_ack_pulse    (alarm_ack_50m),
        .buzzer_mute        (operator_mute),
       .manual_event_pulse (manual_event_50m),
       .key_pressed        (key_pressed),
       .key_press_pulse    (key_press_pulse)
     );

     // Hiwonder WonderEcho voice assistant. Shares the 50 MHz domain with the
     // keys, buzzer and UART. The recognition register is polled every 50 ms;
     // matched words drive the same pulses as the keys, so an operator can
     // trigger the three actions by voice. Abnormal workflow events are turned
     // into spoken announcements here as well, so the voice prompt and the
     // buzzer respond to the same incident (no wake word needed for prompts).
      // Candidate interaction owns the sole WonderEcho I2C bus below. Old
      // voice-start must not bypass the physical S3 + information/ready gates.
      assign voice_manual_pulse=1'b0;
      wire voice_exam_start;

    // --- ExamGuard: K230 ASCII link + authorisation + exam FSM (50 MHz) ---
    wire        ai_result_valid;
    wire [1:0]  ai_msg_type;
    wire [15:0] ai_bbox_x, ai_bbox_y, ai_bbox_w, ai_bbox_h;
    wire [127:0] ai_msg_text;
    wire [4:0]  ai_msg_text_len;
    wire [7:0]  ai_msg_score;
    wire [15:0] ai_frame_count;

    ai_link_rx #(
        .CLK_FREQ(50000000),
        .BAUD    (115200),
        .TEXT_MAX(16)
    ) ai_link_rx_inst (
        .clk         (loc_clk50m),
        .rst         (status_rst_50m),
        .rx          (ai_uart_rx),
        .result_valid(ai_result_valid),
        .msg_type    (ai_msg_type),
        .bbox_x      (ai_bbox_x),
        .bbox_y      (ai_bbox_y),
        .bbox_w      (ai_bbox_w),
        .bbox_h      (ai_bbox_h),
        .msg_text    (ai_msg_text),
        .msg_text_len(ai_msg_text_len),
        .msg_score   (ai_msg_score),
        .frame_count (ai_frame_count)
    );

    wire        ai_face_pulse, ai_face_ok;
    wire [1:0]  ai_face_id;
    wire [7:0]  ai_face_score;
    wire        ai_object_pulse;
    wire [2:0]  ai_object_class;
    wire        ai_gaze_pulse, ai_gaze_away, ai_gaze_present;
    wire [15:0] ai_debug_gaze_cnt;

    ai_mailbox #(
        .TEXT_MAX(16)
    ) ai_mailbox_inst (
        .clk         (loc_clk50m),
        .rst         (status_rst_50m),
        .result_valid(ai_result_valid),
        .msg_type    (ai_msg_type),
        .bbox_x      (ai_bbox_x),
        .bbox_y      (ai_bbox_y),
        .bbox_w      (ai_bbox_w),
        .bbox_h      (ai_bbox_h),
        .msg_text    (ai_msg_text),
        .msg_text_len(ai_msg_text_len),
        .msg_score   (ai_msg_score),
        .face_pulse  (ai_face_pulse),
        .face_ok     (ai_face_ok),
        .face_id     (ai_face_id),
        .face_score  (ai_face_score),
        .object_pulse(ai_object_pulse),
        .object_class(ai_object_class),
        .object_x    (),
        .object_y    (),
        .object_w    (),
        .object_h    (),
        .object_name (),
        .gaze_pulse  (ai_gaze_pulse),
        .gaze_away   (ai_gaze_away),
        .gaze_present(ai_gaze_present)
    );

    // 1 Hz tick for the exam timer.
    reg [25:0] tick_div;
    reg        tick_1s;
    always @(posedge loc_clk50m) begin
        if (status_rst_50m) begin
            tick_div <= 26'd0;
            tick_1s  <= 1'b0;
        end else if (tick_div == 26'd49_999_999) begin
            tick_div <= 26'd0;
            tick_1s  <= 1'b1;
        end else begin
            tick_div <= tick_div + 26'd1;
            tick_1s  <= 1'b0;
        end
    end

    (* keep = "true" *) wire [1:0]  exam_risk;
    (* keep = "true" *) wire [7:0]  exam_event_code;
    (* keep = "true" *) wire [15:0] exam_event_seq;
    (* keep = "true" *) wire [1:0]  exam_authorized_id;
    wire exam_new_event;

    // Bench demo: S4 (KEY[3]) forces the exam timeout during S_EXAM, emitting
    // EV_TIMEOUT (0x31) -> S_SUBMITTED so the "????????????????? prompt can
    // be shown without waiting EXAM_LEN_S. (Replaces the old simulated-auth hook;
    // identity now comes from the real K230 on E13/E14.)
    wire        sim_timeout_pulse = key_press_pulse[3];
    wire        exam_face_pulse = ai_face_pulse;
    wire        exam_face_ok    = ai_face_ok;
    wire [1:0]  exam_face_id    = ai_face_id;

    wire [3:0] evidence_requests;
    wire [15:0] configured_duration=(profile_known && profile_valid)?profile_duration:EXAM_LEN_S;
    reg [15:0] exam_latched_duration;
    always @(posedge loc_clk50m) begin
        if(status_rst_50m) begin exam_latched_duration<=EXAM_LEN_S;end
        else begin
            if(exam_stage==2) exam_latched_duration<=configured_duration;
        end
    end
    assign exam_display_duration=(exam_stage>=3)?exam_latched_duration:configured_duration;
    assign buzzer_mute=operator_mute ^ (profile_known && profile_valid && profile_default_mute);
    wire [63:0] evidence_lanes;
    exam_fsm #(
        .EXAM_LEN_S(EXAM_LEN_S),
        .PARALLEL_EVENTS(1),.ENABLE_RUNTIME_DURATION(1),.USE_PIXEL_BLACK_GATE(1)
    ) exam_fsm_inst (
        .clk            (loc_clk50m),
        .rst            (status_rst_50m),
        .tick_1s        (tick_1s),
        .frame_pulse    (fs_frame_50m),
        .face_pulse     (exam_face_pulse),
        .face_ok        (exam_face_ok),
        .face_id        (exam_face_id),
        .object_pulse   (ai_object_pulse),
        .object_class   (ai_object_class),
        .activity_global(fs_activity_50m),
        .active_cells   (fs_cells_50m),
        .luma_avg       (fs_luma_50m),
        .camera_covered (cover98_sync[1]),
        .gaze_pulse     (ai_gaze_pulse),
        .gaze_away      (ai_gaze_away),
        .gaze_present   (ai_gaze_present),
        .start_pulse    (voice_exam_start),
        .configured_duration_s(configured_duration),
        .submit_pulse   (alarm_ack_50m),
        .ack_pulse      (alarm_ack_50m),
        .timeout_pulse  (sim_timeout_pulse),
        .stage_id       (exam_stage),
        .risk_level     (exam_risk),
        .event_code     (exam_event_code),
        .event_seq      (exam_event_seq),
        .remaining_s    (exam_remaining_s),
        .authorized_id  (exam_authorized_id),
        .new_event      (exam_new_event),
        .debug_luma     (cover_debug_luma),
        .debug_base     (cover_debug_base),
        .debug_flags    (cover_debug_flags),
        .debug_gaze_cnt (ai_debug_gaze_cnt),
        .event_request(evidence_requests),
        .event_request_data(evidence_lanes)
    );

    // New evidence-only identity space; legacy UART AL/EI UID is independent.
    wire evidence_ui_clk,evidence_mig_raw_rst;
    wire [3:0] evidence_resets;
    wire evidence_control_rst=evidence_resets[0];
    wire evidence_cap_rst=evidence_resets[1];
    wire evidence_ui_rst=evidence_resets[2];
    wire evidence_eth_rst=evidence_resets[3];
    // Live PHY state affects ONLY packet admission and the Ethernet MAC.
    // In particular it must not become evidence_arst (shared MIG/video AXI).
    (* ASYNC_REG="TRUE" *) reg eth_qual_meta,eth_qual_sync;
    always @(posedge eth_clk125) begin
        if(evidence_eth_rst) begin eth_qual_meta<=0;eth_qual_sync<=0;end
        else begin eth_qual_meta<=eth_phy_tx_qualified;eth_qual_sync<=eth_qual_meta;end
    end
    wire evidence_mac_rst=evidence_eth_rst || !eth_qual_sync;
    // All causes cancel the slave AXI interface too. RAW MIG ready is upstream
    // of aresetn; no barrier output is fed back to its own reset cause.
    wire evidence_arst=eth_tx_reset_p || !dvi_pll_locked || evidence_mig_raw_rst || status_rst_50m;
    evidence_reset_barrier evidence_reset_barrier_inst(.arst(evidence_arst),
        .clocks({eth_clk125,evidence_ui_clk,pixelclk,loc_clk50m}),.resets(evidence_resets));
    wire ev_request_rst,ev_session_start,ev_session_end,ev_session_active;
    wire ev_request_enable;
    (* keep="true" *) wire ev_boot_exhausted;
    wire [31:0] ev_device,ev_boot,ev_session;
    wire hist_client_transport_rst,hist_source_epoch_rst;
    persistent_event_identity evidence_identity_inst(.clk(loc_clk50m),.system_rst(status_rst_50m),.transport_rst(hist_source_epoch_rst),
        .persistent_boot(persistent_boot),.boot_admission(persistent_admission),
        .ms_tick(ident_ms_tick),.device_straps(IDENT_DEVICE_STRAPS),.session_start(ev_session_start),.session_end(ev_session_end),
        .device_id(ev_device),.boot_id(ev_boot),.session_id(ev_session),.time_ms(ev_time),.session_active(ev_session_active),
        .request_rst(ev_request_rst),.request_enable(ev_request_enable));
    assign ev_boot_exhausted=persistent_done && persistent_error==4'd6;
    wire voice_scl_low,voice_sda_low;
    wire candidate_display_valid;
    wire [127:0] candidate_display_text;
    wire [31:0] candidate_display_token,displayed_token;
    assign voice_scl=voice_scl_low?1'b0:1'bz;
    assign voice_sda=voice_sda_low?1'b0:1'bz;
    voice_interaction_system voice_interaction_inst(
        .clk(loc_clk50m),.rst(status_rst_50m),.tick_1ms(ident_ms_tick),.tick_1s(tick_1s),
        .device_id(IDENT_DEVICE_STRAPS),.boot_id(persistent_boot),.session_id(ev_session),.seat_id(effective_seat),
        .monotonic_ms(ev_time),.boot_ready(persistent_done && persistent_admission),
        .start_blocked(!persistent_done || !persistent_admission || maint_busy || maint_pending),
        .s3_pulse(manual_event_50m),.exam_stage(exam_stage),.face_id(exam_authorized_id),
        .event_request(evidence_requests),.event_lanes(evidence_lanes),.rx_valid(cfg_byte_valid),.rx_data(cfg_byte),
        .exam_start_pulse(voice_exam_start),.legacy_ack_pulse(voice_ack_pulse),.legacy_mute_pulse(voice_mute_pulse),
        .byte_valid(uart_stream_valid[7]),.byte_last(uart_stream_last[7]),
        .byte_data(uart_stream_data[63:56]),.byte_ready(uart_stream_ready[7]),
        .scl_i(voice_scl),.sda_i(voice_sda),.scl_low(voice_scl_low),.sda_low(voice_sda_low),
        .help_pending(),.help_ticket(),.info_state(),.prep_state(),.round_id(),.info_tag(),.interaction_fresh(),
        .candidate_display_valid(candidate_display_valid),.candidate_display_text(candidate_display_text),
        .candidate_display_token(candidate_display_token),.displayed_token(displayed_token));
    wire [192:0] candidate_px;
    wire candidate_px_valid;
    wire [31:0] display_token_px;
    wire display_ack_valid;
    cdc_stats_snapshot #(.WIDTH(193)) candidate_to_pixel(
        .src_clk(loc_clk50m),.src_rst(status_rst_50m),
        .src_stats({candidate_display_valid,candidate_display_token,effective_seat,candidate_display_text}),
        .dst_clk(pixelclk),.dst_rst(status_rst_pixel),.stats(candidate_px),.valid(candidate_px_valid),.age_cycles());
    cdc_stats_snapshot #(.WIDTH(32)) candidate_to_host(
        .src_clk(pixelclk),.src_rst(status_rst_pixel),.src_stats(display_token_px),
        .dst_clk(loc_clk50m),.dst_rst(status_rst_50m),.stats(displayed_token),.valid(display_ack_valid),.age_cycles());
    wire [3:0] ev_aligned_request;
    wire [63:0] ev_aligned_data,ev_aligned_time;
    wire [31:0] ev_aligned_device,ev_aligned_boot,ev_aligned_session;
    // Keep local stage tracking alive across transport-only cancellation. Source
    // queue admission is gated separately, preserving the running exam session.
    exam_event_context evidence_event_context_inst(.clk(loc_clk50m),.rst(status_rst_50m),.stage(exam_stage),
        .request(evidence_requests & {4{ev_request_enable}}),.request_data(evidence_lanes),.device_id(ev_device),.boot_id(ev_boot),.session_id(ev_session),
        .session_active(ev_session_active),.time_ms(ev_time),.session_start(ev_session_start),.session_end(ev_session_end),
        .aligned_request(ev_aligned_request),.aligned_data(ev_aligned_data),.aligned_time_ms(ev_aligned_time),
        .aligned_device(ev_aligned_device),.aligned_boot(ev_aligned_boot),.aligned_session(ev_aligned_session));
    wire ev_valid,ev_ready;
    wire [255:0] ev_data;
    wire ev_capture_valid,ev_capture_ready,ev_log_valid,ev_log_ready;
    wire [255:0] ev_capture_data,ev_log_data;
    (* keep="true" *) wire [31:0] ev_accept_count,ev_reject_count,ev_deliver_count;
    wire [3:0] ev_source_occupancy,ev_source_high;
    wire ev_uid_exhausted;
    event_transaction_queue #(.DEPTH(8),.SEPARATE_ID_RESET(1)) evidence_event_queue_inst(.clk(loc_clk50m),.rst(ev_request_rst),.id_rst(status_rst_50m),
        .request(ev_aligned_request & {4{ev_request_enable}}),.request_data(ev_aligned_data),.device_id(ev_aligned_device),.boot_id(ev_aligned_boot),
        .session_id(ev_aligned_session),.request_time_ms(ev_aligned_time),.accepted(),.rejected(),.event_valid(ev_valid),.event_ready(ev_ready),.event_data(ev_data),
        .occupancy(ev_source_occupancy),.high_water(ev_source_high),.accepted_count(ev_accept_count),.rejected_count(ev_reject_count),.delivered_count(ev_deliver_count),.id_exhausted(ev_uid_exhausted));
    event_transaction_fork evidence_event_fork_inst(.clk(loc_clk50m),.rst(ev_request_rst),.in_valid(ev_valid),.in_data(ev_data),.in_ready(ev_ready),
        .a_valid(ev_capture_valid),.a_data(ev_capture_data),.a_ready(ev_capture_ready),.b_valid(ev_log_valid),.b_data(ev_log_data),.b_ready(ev_log_ready));
    wire [3:0] ev_log_occupancy;
    wire ev_log_queue_valid,ev_log_queue_ready;
    wire [255:0] ev_log_queue_data;
    assign ev_log_ready=!ev_request_rst && ev_log_occupancy<8;
    // Once accepted by the UART log queue, keep the ORIGINAL transaction across
    // transport-only reset. That record never asserts successful evidence.
    event_request_fifo #(.SOURCES(1),.DATA_WIDTH(256),.DEPTH(8)) evidence_log_queue_inst(
        .clk(loc_clk50m),.rst(status_rst_50m),.request(ev_log_valid && ev_log_ready),.request_data(ev_log_data),
        .accepted(),.rejected(),.event_valid(ev_log_queue_valid),.event_ready(ev_log_queue_ready),.event_data(ev_log_queue_data),
        .occupancy(ev_log_occupancy),.high_water(),.accepted_count(),.rejected_count(),.delivered_count());
    event_transaction_log evidence_event_log_inst(.clk(loc_clk50m),.rst(status_rst_50m),.event_valid(ev_log_queue_valid),.event_data(ev_log_queue_data),.event_ready(ev_log_queue_ready),
        .byte_valid(uart_stream_valid[3]),.byte_last(uart_stream_last[3]),.byte_data(uart_stream_data[31:24]),.byte_ready(uart_stream_ready[3]));
    wire [3:0] ev_awid,ev_arid,ev_bid,ev_rid;
    wire [29:0] ev_awaddr,ev_araddr;
    wire [7:0] ev_awlen,ev_arlen;
    wire [2:0] ev_awsize,ev_arsize;
    wire [1:0] ev_awburst,ev_arburst,ev_bresp,ev_rresp;
    wire ev_awvalid,ev_awready,ev_arvalid,ev_arready,ev_wvalid,ev_wready,ev_wlast,ev_bvalid,ev_bready,ev_rvalid,ev_rready,ev_rlast;
    wire [127:0] ev_wdata,ev_rdata;
    wire [15:0] ev_wstrb;
    wire ev_tx_start,ev_tx_done,ev_payload_req;
    wire [15:0] ev_tx_length;
    wire [7:0] ev_payload_data;
    (* keep="true" *) wire [31:0] ev_frames_committed,ev_frames_failed,ev_read_errors,ev_packets_sent,ev_results_sent,ev_udp_sent,ev_udp_dropped;
    (* keep="true" *) wire ev_packet_fault,ev_udp_fault;
    wire [255:0] ev_cap_stats,ev_ui_stats;
    wire [127:0] ev_eth_stats;

    // History client replaces camera_evidence_transport. Its store/AXI run in
    // the MIG UI clock; the 50 MHz event transaction crosses through the
    // existing bundled-data channel. Pixel packet and HR record are arbitrated
    // as whole byte-stream packets into ONE UDP bridge/MAC.
    wire hist_ui_rst,hist_cap_rst,hist_control_rst,hist_cancelled;
    wire hist_ev_valid,hist_ev_ready;
    wire [255:0] hist_ev_data;
    wire hist_event_ready;
    wire hist_out_valid,hist_out_sof,hist_out_last,hist_out_ready;
    wire [15:0] hist_out_data;
    wire [95:0] hist_out_meta;
    wire [255:0] hist_out_event;
    wire [31:0] hist_out_index;
    wire hist_res_valid,hist_res_ready,hist_res_ok,hist_res_trunc,hist_res_cap;
    wire hist_res_unknown,hist_res_bad,hist_res_cov;
    wire [1:0] hist_res_window;
    wire [31:0] hist_res_token,hist_res_frames,hist_res_gap_count;
    wire [2:0] hist_res_code;
    wire [63:0] hist_res_lower,hist_res_upper;
    wire [95:0] hist_res_first,hist_res_last;
    wire [7:0] hist_res_first_reason,hist_res_last_reason;
    wire [255:0] hist_res_event;
    wire hist_fork_ready,hist_fa_valid,hist_fa_ready,hist_fb_valid,hist_fb_ready;
    wire [1:0] hist_fa_window,hist_fb_window;
    wire [31:0] hist_fa_token,hist_fb_token,hist_fa_frames,hist_fb_frames,hist_fa_gap_count,hist_fb_gap_count;
    wire [2:0] hist_fa_code,hist_fb_code;
    wire hist_fa_ok,hist_fa_trunc,hist_fa_cap,hist_fa_unknown,hist_fa_bad,hist_fa_cov;
    wire hist_fb_ok,hist_fb_trunc,hist_fb_cap,hist_fb_unknown,hist_fb_bad,hist_fb_cov;
    wire [63:0] hist_fa_lower,hist_fa_upper,hist_fb_lower,hist_fb_upper;
    wire [95:0] hist_fa_first,hist_fa_last,hist_fb_first,hist_fb_last;
    wire [7:0] hist_fa_first_reason,hist_fa_last_reason,hist_fb_first_reason,hist_fb_last_reason;
    wire [255:0] hist_fa_event,hist_fb_event;
    wire hist_pix_tx_valid,hist_pix_tx_last,hist_pix_tx_ready;
    wire [7:0] hist_pix_tx_data;
    wire hist_pix_cdc_valid,hist_pix_cdc_last,hist_pix_cdc_ready;
    wire [7:0] hist_pix_cdc_data;
    wire hist_hr_tx_valid,hist_hr_tx_last,hist_hr_tx_ready;
    wire [7:0] hist_hr_tx_data;
    wire hist_hr_cdc_valid,hist_hr_cdc_last,hist_hr_cdc_ready;
    wire [7:0] hist_hr_cdc_data;
    wire hist_mux_valid,hist_mux_last,hist_mux_ready;
    wire [7:0] hist_mux_data;
    wire hist_pixel_fault,hist_hr_fault,hist_udp_fault;
    wire [31:0] hist_records_sent;
    wire [2:0] hist_faults;
    wire [31:0] hist_frames_seen,hist_frames_published,hist_capture_dropped,hist_decisions_sent;
    wire [31:0] hist_sofs,hist_cadence_skipped,hist_time_unknown,hist_time_stale;
    wire [31:0] hist_decisions_completed,hist_gaps_recorded,hist_gap_recorded,hist_gap_evicted;
    wire [2:0] hist_pending_windows;
    wire hist_pix_out_ready;
    (* ASYNC_REG="TRUE" *) reg hist_eth_meta,hist_eth_sync;
    always @(posedge eth_clk125 or posedge hist_ui_rst)
        if(hist_ui_rst) begin hist_eth_meta<=1;hist_eth_sync<=1;end
        else begin hist_eth_meta<=0;hist_eth_sync<=hist_eth_meta;end
    wire hist_eth_cancel=hist_eth_sync;
    wire hist_eth_rst=evidence_eth_rst || hist_eth_cancel;
    wire hist_mac_rst=evidence_mac_rst || hist_eth_cancel;
    wire [3:0] guard_awid,guard_arid,guard_bid,guard_rid;
    wire [29:0] guard_awaddr,guard_araddr;
    wire [7:0] guard_awlen,guard_arlen;
    wire [2:0] guard_awsize,guard_arsize;
    wire [1:0] guard_awburst,guard_arburst,guard_bresp,guard_rresp;
    wire guard_awvalid,guard_awready,guard_arvalid,guard_arready,guard_wvalid,guard_wready,guard_wlast;
    wire guard_bvalid,guard_bready,guard_rvalid,guard_rready,guard_rlast;
    wire [127:0] guard_wdata,guard_rdata;
    wire [15:0] guard_wstrb;
    // Shared video/MIG reset depends only on upstream readiness/system reset.
    // Local history cancellation drains through an independent AXI epoch guard.
    wire video_fabric_arst=status_rst_50m || !dvi_pll_locked || evidence_mig_raw_rst;
    (* ASYNC_REG="TRUE" *) reg [2:0] video_fabric_rst_sync;
    always @(posedge evidence_ui_clk or posedge video_fabric_arst)
        if(video_fabric_arst) video_fabric_rst_sync<=3'b111;
        else video_fabric_rst_sync<={video_fabric_rst_sync[1:0],1'b0};
    wire hist_fabric_rst=video_fabric_rst_sync[2];
    wire hist_axi_idle,hist_axi_fault;
    history_axi_epoch_guard history_axi_guard_inst(.clk(evidence_ui_clk),.rst(hist_fabric_rst),.cancel(hist_ui_rst),
        .idle(hist_axi_idle),.protocol_fault(hist_axi_fault),
        .s_awid(ev_awid),.s_arid(ev_arid),.s_awaddr(ev_awaddr),.s_araddr(ev_araddr),.s_awlen(ev_awlen),.s_arlen(ev_arlen),
        .s_awsize(ev_awsize),.s_arsize(ev_arsize),.s_awburst(ev_awburst),.s_arburst(ev_arburst),
        .s_awvalid(ev_awvalid),.s_arvalid(ev_arvalid),.s_awready(ev_awready),.s_arready(ev_arready),
        .s_wdata(ev_wdata),.s_wstrb(ev_wstrb),.s_wlast(ev_wlast),.s_wvalid(ev_wvalid),.s_wready(ev_wready),
        .s_bid(ev_bid),.s_rid(ev_rid),.s_bresp(ev_bresp),.s_rresp(ev_rresp),.s_bvalid(ev_bvalid),.s_rvalid(ev_rvalid),
        .s_rlast(ev_rlast),.s_rdata(ev_rdata),.s_bready(ev_bready),.s_rready(ev_rready),
        .m_awid(guard_awid),.m_arid(guard_arid),.m_awaddr(guard_awaddr),.m_araddr(guard_araddr),
        .m_awlen(guard_awlen),.m_arlen(guard_arlen),.m_awsize(guard_awsize),.m_arsize(guard_arsize),
        .m_awburst(guard_awburst),.m_arburst(guard_arburst),.m_awvalid(guard_awvalid),.m_arvalid(guard_arvalid),
        .m_awready(guard_awready),.m_arready(guard_arready),.m_wdata(guard_wdata),.m_wstrb(guard_wstrb),
        .m_wlast(guard_wlast),.m_wvalid(guard_wvalid),.m_wready(guard_wready),
        .m_bid(guard_bid),.m_rid(guard_rid),.m_bresp(guard_bresp),.m_rresp(guard_rresp),
        .m_bvalid(guard_bvalid),.m_rvalid(guard_rvalid),.m_rlast(guard_rlast),.m_rdata(guard_rdata),
        .m_bready(guard_bready),.m_rready(guard_rready));
    history_lifecycle_control history_lifecycle_inst(.clk(loc_clk50m),.transport_rst(evidence_control_rst),
        .axi_idle(hist_axi_idle),.local_cancelled(hist_cancelled),
        .client_transport_rst(hist_client_transport_rst),.source_epoch_rst(hist_source_epoch_rst));
    // Capture metadata uses exactly the event source's monotonic time, including
    // ticks while the history UI is cancelled; no second drifting tick counter.
    wire [63:0] hist_sample_time;
    wire hist_sample_time_valid;
    wire [31:0] hist_sample_time_age;
    cdc_time_snapshot hist_source_time_cdc(.src_clk(loc_clk50m),.src_rst(ev_request_rst),.src_time_ms(ev_time),
        .dst_clk(pixelclk),.dst_rst(hist_cap_rst),.time_ms(hist_sample_time),
        .time_valid(hist_sample_time_valid),.age_cycles(hist_sample_time_age));
    wire ms_tick_ui,session_start_ui,session_end_ui;
    pulse_cdc hist_ms_tick_cdc(.src_clk(loc_clk50m),.src_rst(status_rst_50m),.src_pulse(ident_ms_tick),
        .dst_clk(evidence_ui_clk),.dst_rst(hist_ui_rst),.dst_pulse(ms_tick_ui));
    pulse_cdc hist_session_start_cdc(.src_clk(loc_clk50m),.src_rst(status_rst_50m),.src_pulse(ev_session_start),
        .dst_clk(evidence_ui_clk),.dst_rst(hist_ui_rst),.dst_pulse(session_start_ui));
    pulse_cdc hist_session_end_cdc(.src_clk(loc_clk50m),.src_rst(status_rst_50m),.src_pulse(ev_session_end),
        .dst_clk(evidence_ui_clk),.dst_rst(hist_ui_rst),.dst_pulse(session_end_ui));
    cdc_event_transaction #(.DATA_WIDTH(256)) hist_event_cdc(
        .src_clk(loc_clk50m),.src_rst(ev_request_rst),.src_valid(ev_capture_valid),.src_data(ev_capture_data),
        .src_ready(ev_capture_ready),.src_accepted_count(),
        .dst_clk(evidence_ui_clk),.dst_rst(hist_ui_rst),.dst_valid(hist_ev_valid),.dst_data(hist_ev_data),
        .dst_ready(hist_event_ready),.dst_delivered_count());
    history_capture_client #(.SRC_WIDTH(DISP_WIDTH),.SRC_HEIGHT(DISP_HEIGHT),.SAMPLE_STRIDE(4),.FRAME_INTERVAL(6),
        .CAP_DEPTH(16),.CDC_DEPTH(64),.SLOTS(64),.WINDOWS(4),.BURST(32),.GAP_DEPTH(16),
        .PRE_MS(2000),.POST_MS(2000),.BASE_ADDR(30'h10000000),.WITH_HR_UDP(0),.EXTERNAL_CAP_TIME(1),.WITH_EXTERNAL_HALT(1)) history_client_inst(
        .clk(evidence_ui_clk),.control_clk(loc_clk50m),.cap_clk(pixelclk),
        .system_rst(status_rst_50m),.transport_rst(hist_client_transport_rst),.restart(1'b0),
        .ms_tick(ms_tick_ui),.session_start(session_start_ui),.session_end(session_end_ui),.device_straps(IDENT_DEVICE_STRAPS),
        .device_id(),.boot_id(),.session_id(),.time_ms(),.session_active(),.boot_exhausted(),.identity_request_enable(),
        // disp_driver H_Addr is one cycle ahead of the registered pixel and
        // color_enhance adds one extra coordinate stage; align the sampler to
        // the actual pixel data. Without this the first x/y=0 grid sample is
        // missed and every frame drops with source reason3 (index/LAST).
        .cap_enable(1'b1),.pixel_r(enh_r),.pixel_g(enh_g),.pixel_b(enh_b),
        .x(enh_x-12'd2),.y(enh_y-12'd2),.de(enh_de),.sof(enh_sof),
        .cap_time_ms(hist_sample_time),.cap_time_valid(hist_sample_time_valid),.cap_time_age(hist_sample_time_age),
        .external_ui_halt(hist_axi_fault),
        .event_valid(hist_ev_valid),.event_ready(hist_event_ready),.event_event(hist_ev_data),
        .decision_valid(),.decision_ready(1'b1),.decision_kind(),.decision_meta(),.decision_code(),
        .out_valid(hist_out_valid),.out_sof(hist_out_sof),.out_last(hist_out_last),.out_data(hist_out_data),
        .out_meta(hist_out_meta),.out_event(hist_out_event),.out_index(hist_out_index),.out_ready(hist_pix_out_ready),
        .result_valid(hist_res_valid),.result_ready(hist_res_ready),.result_window(hist_res_window),
        .result_token(hist_res_token),.result_code(hist_res_code),.result_ok(hist_res_ok),
        .result_truncated(hist_res_trunc),.result_capture_error(hist_res_cap),
        .result_frames(hist_res_frames),.result_gap_count(hist_res_gap_count),
        .result_gap_unknown(hist_res_unknown),.result_gap_bad_range(hist_res_bad),
        .result_coverage_ok(hist_res_cov),.result_lower(hist_res_lower),.result_upper(hist_res_upper),
        .result_gap_first_meta(hist_res_first),.result_gap_last_meta(hist_res_last),
        .result_gap_first_reason(hist_res_first_reason),.result_gap_last_reason(hist_res_last_reason),
        .result_event(hist_res_event),
        .hr_tx_qualified(1'b1),.hr_tx_en_pulse(),.hr_data_length(),.hr_payload_req(1'b0),.hr_tx_done(1'b0),
        .hr_payload_data(),.hr_protocol_fault(),.hr_records_sent(),.hr_packets_sent(),.hr_packets_dropped(),
        .ui_rst(hist_ui_rst),.cap_rst(hist_cap_rst),.control_rst(hist_control_rst),.cancelled(hist_cancelled),
        .cancellation_count(),.src_halted(),.dst_halted(),.source_halted(),.cdc_src_halted(),.cdc_dst_halted(),
        .ingress_halted(),.journal_halted(),.client_halted(),
        .source_sofs(hist_sofs),.cadence_skipped(hist_cadence_skipped),
        .time_unknown_count(hist_time_unknown),.time_stale_count(hist_time_stale),
        .frames_seen(hist_frames_seen),.frames_published(hist_frames_published),
        .capture_dropped(hist_capture_dropped),.decisions_sent(hist_decisions_sent),
        .decisions_completed(hist_decisions_completed),.gaps_recorded(hist_gaps_recorded),
        .gap_recorded(hist_gap_recorded),.gap_evicted(hist_gap_evicted),
        .pending_windows(hist_pending_windows),
        .frames_committed(ev_frames_committed),.frames_dropped(ev_frames_failed),
        .reserve_rejected(),.write_failed(),.faults(hist_faults),.protected_slots(),.done(),.done_ok(),
        .m_axi_awid(ev_awid),.m_axi_arid(ev_arid),.m_axi_awaddr(ev_awaddr),.m_axi_araddr(ev_araddr),
        .m_axi_awlen(ev_awlen),.m_axi_arlen(ev_arlen),.m_axi_awsize(ev_awsize),.m_axi_arsize(ev_arsize),
        .m_axi_awburst(ev_awburst),.m_axi_arburst(ev_arburst),.m_axi_awvalid(ev_awvalid),.m_axi_arvalid(ev_arvalid),
        .m_axi_awready(ev_awready),.m_axi_arready(ev_arready),.m_axi_wdata(ev_wdata),.m_axi_wstrb(ev_wstrb),
        .m_axi_wlast(ev_wlast),.m_axi_wvalid(ev_wvalid),.m_axi_wready(ev_wready),.m_axi_bid(ev_bid),
        .m_axi_bresp(ev_bresp),.m_axi_bvalid(ev_bvalid),.m_axi_bready(ev_bready),.m_axi_rid(ev_rid),
        .m_axi_rdata(ev_rdata),.m_axi_rresp(ev_rresp),.m_axi_rlast(ev_rlast),.m_axi_rvalid(ev_rvalid),.m_axi_rready(ev_rready));
    history_result_fork #(.WINDOWS(4)) history_result_fork_inst(
        .clk(evidence_ui_clk),.rst(hist_ui_rst),.in_valid(hist_res_valid),.in_ready(hist_res_ready),
        .in_window(hist_res_window),.in_token(hist_res_token),.in_code(hist_res_code),
        .in_ok(hist_res_ok),.in_trunc(hist_res_trunc),.in_cap(hist_res_cap),
        .in_gap_unknown(hist_res_unknown),.in_gap_bad_range(hist_res_bad),.in_coverage(hist_res_cov),
        .in_frames(hist_res_frames),.in_gap_count(hist_res_gap_count),.in_lower(hist_res_lower),.in_upper(hist_res_upper),
        .in_first_meta(hist_res_first),.in_last_meta(hist_res_last),
        .in_first_reason(hist_res_first_reason),.in_last_reason(hist_res_last_reason),.in_event(hist_res_event),
        .a_valid(hist_fa_valid),.a_ready(hist_fa_ready),.a_window(hist_fa_window),.a_token(hist_fa_token),
        .a_code(hist_fa_code),.a_ok(hist_fa_ok),.a_trunc(hist_fa_trunc),.a_cap(hist_fa_cap),
        .a_gap_unknown(hist_fa_unknown),.a_gap_bad_range(hist_fa_bad),.a_coverage(hist_fa_cov),
        .a_frames(hist_fa_frames),.a_gap_count(hist_fa_gap_count),.a_lower(hist_fa_lower),.a_upper(hist_fa_upper),
        .a_first_meta(hist_fa_first),.a_last_meta(hist_fa_last),.a_first_reason(hist_fa_first_reason),
        .a_last_reason(hist_fa_last_reason),.a_event(hist_fa_event),
        .b_valid(hist_fb_valid),.b_ready(hist_fb_ready),.b_window(hist_fb_window),.b_token(hist_fb_token),
        .b_code(hist_fb_code),.b_ok(hist_fb_ok),.b_trunc(hist_fb_trunc),.b_cap(hist_fb_cap),
        .b_gap_unknown(hist_fb_unknown),.b_gap_bad_range(hist_fb_bad),.b_coverage(hist_fb_cov),
        .b_frames(hist_fb_frames),.b_gap_count(hist_fb_gap_count),.b_lower(hist_fb_lower),.b_upper(hist_fb_upper),
        .b_first_meta(hist_fb_first),.b_last_meta(hist_fb_last),.b_first_reason(hist_fb_first_reason),
        .b_last_reason(hist_fb_last_reason),.b_event(hist_fb_event));
    evidence_window_packetizer #(.WIDTH(DISP_WIDTH/4),.HEIGHT(DISP_HEIGHT/4),.CHUNK_PIXELS(512)) history_pixel_packetizer_inst(
        .clk(evidence_ui_clk),.rst(hist_ui_rst),
        .out_valid(hist_out_valid),.out_sof(hist_out_sof),.out_last(hist_out_last),.out_data(hist_out_data),
        .out_meta(hist_out_meta),.out_event(hist_out_event),.out_deferred(1'b0),.out_ready(hist_pix_out_ready),
        .result_valid(hist_fa_valid),.result_ok(hist_fa_ok),.result_deferred(1'b0),
        .result_event(hist_fa_event),.result_frames(hist_fa_frames),.result_ready(hist_fa_ready),
        .tx_valid(hist_pix_tx_valid),.tx_last(hist_pix_tx_last),.tx_data(hist_pix_tx_data),.tx_ready(hist_pix_tx_ready),
        .protocol_fault(hist_pixel_fault),.packets_sent(),.results_sent());
    evidence_packet_cdc #(.DEPTH(256)) history_pixel_cdc_inst(
        .src_clk(evidence_ui_clk),.src_rst(hist_ui_rst),.src_valid(hist_pix_tx_valid),.src_last(hist_pix_tx_last),
        .src_data(hist_pix_tx_data),.src_ready(hist_pix_tx_ready),
        .dst_clk(eth_clk125),.dst_rst(hist_eth_rst),.dst_ready(hist_pix_cdc_ready),
        .dst_valid(hist_pix_cdc_valid),.dst_data(hist_pix_cdc_data),.dst_last(hist_pix_cdc_last));
    history_result_record #(.WINDOWS(4)) history_hr_record_inst(
        .clk(evidence_ui_clk),.rst(hist_ui_rst),.result_valid(hist_fb_valid),.result_ready(hist_fb_ready),
        .result_window(hist_fb_window),.result_token(hist_fb_token),.result_code(hist_fb_code),
        .result_ok(hist_fb_ok),.result_truncated(hist_fb_trunc),.result_capture_error(hist_fb_cap),
        .result_frames(hist_fb_frames),.result_gap_count(hist_fb_gap_count),
        .result_gap_unknown(hist_fb_unknown),.result_gap_bad_range(hist_fb_bad),.result_coverage_ok(hist_fb_cov),
        .result_lower(hist_fb_lower),.result_upper(hist_fb_upper),
        .result_gap_first_meta(hist_fb_first),.result_gap_last_meta(hist_fb_last),
        .result_gap_first_reason(hist_fb_first_reason),.result_gap_last_reason(hist_fb_last_reason),
        .result_event(hist_fb_event),.tx_valid(hist_hr_tx_valid),.tx_last(hist_hr_tx_last),.tx_data(hist_hr_tx_data),
        .tx_ready(hist_hr_tx_ready),.protocol_fault(hist_hr_fault),.records_sent(hist_records_sent));
    evidence_packet_cdc #(.DEPTH(256)) history_hr_cdc_inst(
        .src_clk(evidence_ui_clk),.src_rst(hist_ui_rst),.src_valid(hist_hr_tx_valid),.src_last(hist_hr_tx_last),
        .src_data(hist_hr_tx_data),.src_ready(hist_hr_tx_ready),
        .dst_clk(eth_clk125),.dst_rst(hist_eth_rst),.dst_ready(hist_hr_cdc_ready),
        .dst_valid(hist_hr_cdc_valid),.dst_data(hist_hr_cdc_data),.dst_last(hist_hr_cdc_last));
    evidence_byte_mux history_byte_mux_inst(
        .clk(eth_clk125),.rst(hist_eth_rst),
        .a_valid(hist_pix_cdc_valid),.a_last(hist_pix_cdc_last),.a_data(hist_pix_cdc_data),.a_ready(hist_pix_cdc_ready),
        .b_valid(hist_hr_cdc_valid),.b_last(hist_hr_cdc_last),.b_data(hist_hr_cdc_data),.b_ready(hist_hr_cdc_ready),
        .dst_valid(hist_mux_valid),.dst_last(hist_mux_last),.dst_data(hist_mux_data),.dst_ready(hist_mux_ready));
    evidence_packet_udp_bridge #(.REQUIRE_TX_QUALIFIED(1)) history_udp_bridge_inst(
        .clk(eth_clk125),.rst(hist_eth_rst),.tx_qualified(eth_qual_sync),
        .in_valid(hist_mux_valid),.in_last(hist_mux_last),.in_data(hist_mux_data),.in_ready(hist_mux_ready),
        .tx_en_pulse(ev_tx_start),.data_length(ev_tx_length),.payload_req(ev_payload_req),
        .tx_done(ev_tx_done),.payload_data(ev_payload_data),.protocol_fault(hist_udp_fault),
        .packets_sent(ev_packets_sent),.packets_dropped(ev_udp_dropped));
    assign ev_packet_fault=hist_pixel_fault || hist_hr_fault || hist_udp_fault;
    assign ev_udp_fault=hist_udp_fault;
    assign ev_read_errors=32'd0;
    assign ev_results_sent=hist_records_sent;
    assign ev_udp_sent=ev_packets_sent;
    assign ev_cap_stats=256'd0; // cap-domain history stats are not yet exported; do not cross UI stats here
    history_health_stats history_health_stats_inst(.ui_clk(evidence_ui_clk),.ui_rst(hist_ui_rst),
        .eth_clk(eth_clk125),.eth_rst(hist_eth_rst),
        .request_fire(hist_ev_valid && hist_event_ready),.result_fire(hist_res_valid && hist_res_ready),
        .result_ok(hist_res_ok),.result_code(hist_res_code),.pending_windows(hist_pending_windows),
        .result_valid(hist_res_valid),.out_valid(hist_out_valid),.axi_fault(hist_axi_fault),
        .pixel_fault(hist_pixel_fault),.hr_fault(hist_hr_fault),
        .frames_committed(ev_frames_committed),.frames_failed(ev_frames_failed),
        .pixel_packet_fire(hist_pix_tx_valid && hist_pix_tx_ready && hist_pix_tx_last),
        .hr_packet_fire(hist_hr_tx_valid && hist_hr_tx_ready && hist_hr_tx_last),
        .packet_stall(hist_mux_valid && !hist_mux_ready),.udp_fault(hist_udp_fault),
        .udp_sent(ev_packets_sent),.udp_dropped(ev_udp_dropped),.ui_stats(ev_ui_stats),.eth_stats(ev_eth_stats));
    wire [7:0] ev_gmii_data;
    wire ev_gmii_en,ev_gmii_clk;
    eth_udp_tx_gmii evidence_eth_tx_inst(.clk125m(eth_clk125),.reset_p(hist_mac_rst),.tx_en_pulse(ev_tx_start),.tx_done(ev_tx_done),
        .dst_mac(48'hffffffffffff),.src_mac(48'h020000000002),.dst_ip(32'hc0a80003),.src_ip(32'hc0a80002),.dst_port(16'd6102),.src_port(16'd5000),
        .data_length(ev_tx_length),.payload_req_o(ev_payload_req),.payload_dat_i(ev_payload_data),.gmii_tx_clk(ev_gmii_clk),.gmii_txen(ev_gmii_en),.gmii_txd(ev_gmii_data));
    gmii_to_rgmii evidence_rgmii_inst(.reset_n(!hist_eth_rst),.gmii_tx_clk(ev_gmii_clk),.gmii_txd(ev_gmii_data),.gmii_txen(ev_gmii_en),.gmii_txer(1'b0),
        .rgmii_tx_clk(eth_gtx_clk),.rgmii_txd(eth_txd),.rgmii_txen(eth_txen));

    wire [23:0] ev_health_flags;
    evidence_health_telemetry #(.ENABLE_PHY_HEALTH(1)) evidence_health_inst(.clk(loc_clk50m),.system_rst(status_rst_50m),.control_rst(evidence_control_rst),
        .cap_clk(pixelclk),.cap_rst(hist_cap_rst),.ui_clk(evidence_ui_clk),.ui_rst(hist_ui_rst),.eth_clk(eth_clk125),.eth_rst(hist_eth_rst),
        .device_id(ev_device),.boot_id(ev_boot),.session_id(ev_session),.time_ms(ev_time),.boot_exhausted(ev_boot_exhausted),.id_exhausted(ev_uid_exhausted),
        .request_enable(ev_request_enable),.fsm_requests(evidence_requests),.source_occupancy(ev_source_occupancy),.source_high_water(ev_source_high),
        .source_accepted(ev_accept_count),.source_rejected(ev_reject_count),.source_delivered(ev_deliver_count),
        .cap_stats(ev_cap_stats),.ui_stats(ev_ui_stats),.eth_stats(ev_eth_stats),.phy_summary(phy_summary),.report_data(ev_health_report),.flags(ev_health_flags),.cancel_epochs(),.blocked_requests());

    // C04 health monitor: distinguishes "no violation" from "input/link failed".
    // camera_frame_pulse = video frame tick; k230_pulse = any K230 result frame.
    health_monitor health_monitor_inst (
       .clk                (loc_clk50m),
       .rst                (status_rst_50m),
       .tick_1s            (tick_1s),
       .camera_frame_pulse (fs_frame_50m),
       .k230_pulse         (ai_face_pulse | ai_object_pulse | ai_gaze_pulse),
       .evidence_busy      (evidence_busy_50m),
       .overrun_pulse      (image_overrun_pulse_50m),
       .health_flags       (base_health_flags),
       .overrun_count      (),
       .camera_silent_s    (),
       .k230_silent_s      ()
    );

    // Idle-high until FPGA -> K230 commands are added.
    assign ai_uart_tx = 1'b1;

    // Bridge the exam status back to the pixel domain for the HDMI panel.
    wire [2:0] exam_stage_px;
    wire [1:0] exam_risk_px;
    wire [7:0] exam_event_px;
    cdc_exam_status cdc_exam_status_inst (
        .src_clk (loc_clk50m),
        .src_rst (status_rst_50m),
        .src_stage(exam_stage),
        .src_risk (exam_risk),
        .src_event(exam_event_code),
        .dst_clk (pixelclk),
        .dst_rst (status_rst_pixel),
        .dst_stage(exam_stage_px),
        .dst_risk (exam_risk_px),
        .dst_event(exam_event_px)
    );

    // Exam status now feeds the shared status fields (HDMI panel, UART, voice
    // announcer and the evidence ring), replacing the retired workflow_fsm.
    assign status_stage_id   = {1'b0, exam_stage_px};
    assign status_risk_level = {2'b00, exam_risk_px};
    assign status_zone_id    = 4'd0;
    assign status_event_code = exam_event_px;

     // Key pulses must reach the pixel domain where the workflow and the
     // evidence ring live.
     pulse_cdc pulse_cdc_workflow_reset (
       .src_clk   (loc_clk50m),
       .src_rst   (status_rst_50m),
       .src_pulse (alarm_ack_src),
       .dst_clk   (pixelclk),
       .dst_rst   (status_rst_pixel),
       .dst_pulse (workflow_reset_pixel)
     );

     pulse_cdc pulse_cdc_manual_event (
       .src_clk   (loc_clk50m),
       .src_rst   (status_rst_50m),
       .src_pulse (manual_event_src),
       .dst_clk   (pixelclk),
       .dst_rst   (status_rst_pixel),
       .dst_pulse (manual_event_pixel)
     );

     // CDC2: register the profile/operator XOR in its source domain before
     // crossing. Only the on-screen mute indication gains one source cycle;
     // the local buzzer's existing mute logic remains unchanged.
     reg buzzer_mute_cdc_source;
     always @(posedge loc_clk50m) begin
       if (status_rst_50m)
         buzzer_mute_cdc_source <= 1'b0;
       else
         buzzer_mute_cdc_source <= buzzer_mute;
     end
     (* ASYNC_REG = "TRUE" *) reg [1:0] buzzer_mute_pixel_ff;
     always @(posedge pixelclk) begin
       if (status_rst_pixel)
         buzzer_mute_pixel_ff <= 2'b00;
       else
         buzzer_mute_pixel_ff <= {buzzer_mute_pixel_ff[0], buzzer_mute_cdc_source};
     end
     wire buzzer_mute_pixel = buzzer_mute_pixel_ff[1];

     // Metadata evidence ring samples the frame-domain workflow once per frame
     // and captures a pre/post window around every alarm or manual trigger.
     //
     // The manual key pulse is one pixel clock wide, but the ring only
     // evaluates event_trigger on the frame_begin cycle, so an unlatched pulse
     // is almost always dropped. Hold it as a frame-aligned flag that is
     // cleared once it has been presented at a frame boundary.
     reg manual_trigger_pending;
     always @(posedge pixelclk) begin
       if (status_rst_pixel)
         manual_trigger_pending <= 1'b0;
       else if (manual_event_pixel)
         manual_trigger_pending <= 1'b1;
       else if (frame_begin)
         manual_trigger_pending <= 1'b0;
     end
     assign event_trigger_pixel = new_event_pending | manual_trigger_pending;

     // One image evidence window per incident. A manual press OR any newly
     // latched event arms a window. new_event_pixel is already a one-shot pulse
     // per episode, so this cannot burst on a sustained event; the request
     // disarms as soon as the image ring starts capturing.
     always @(posedge pixelclk) begin
       if (status_rst_pixel) begin
         image_trigger_armed   <= 1'b0;
       end else if (image_trigger_armed && (image_window_busy || image_window_available)) begin
         image_trigger_armed   <= 1'b0;
       end else if (manual_event_pixel || new_event_pending) begin
         image_trigger_armed   <= 1'b1;
       end
     end
     assign image_event_trigger = image_trigger_armed;

     event_meta_ring #(
       .ADDR_WIDTH  (7),
       .PRE_SAMPLES (32),
       .POST_SAMPLES(32)
     ) event_meta_ring_inst (
       .clk                     (pixelclk),
       .rst                     (status_rst_pixel),
       .sample_valid            (frame_begin),
       .sample_frame_id         (status_frame_id),
       .sample_timestamp_ms     (status_timestamp_ms),
       .sample_stage_id         (status_stage_id),
       .sample_risk_level       (status_risk_level),
       .sample_zone_id          (status_zone_id),
       .sample_event_code       (status_event_code),
       .sample_motion_pickup    (motion_pickup),
       .sample_motion_operation (motion_operation),
       .sample_motion_forbidden (motion_forbidden),
       .sample_config_version   (config_version_active),
       .sample_health_flags     (8'd0),
        .sample_event_seq        (status_event_seq),
        .event_trigger           (event_trigger_pixel),
        .readout_active          (evidence_busy),
        .event_busy              (event_ring_busy),
       .event_done              (event_ring_done),
       .event_available         (event_ring_available),
       .event_overrun           (event_ring_overrun),
       .snapshot_event_seq      (event_ring_seq),
       .read_req                (ring_read_req),
       .read_index              (ring_read_index),
       .read_valid              (event_ring_read_valid),
       .read_data               (event_ring_data)
     );

     // Streams the completed window out of the evidence ring as ASCII. This is
     // the consumer that keeps the ring in the netlist.
     evidence_dump #(
       .UART_CLK_HZ    (50000000),
       .BAUD_RATE      (115200),
       .CAPTURE_LENGTH (65),
       .INDEX_WIDTH    (7),
        .SEQ_WIDTH      (8),
        .STREAM_OUTPUT  (1)
     ) evidence_dump_inst (
       .ev_clk          (pixelclk),
       .ev_rst          (status_rst_pixel),
       .ev_start        (event_ring_done),
       .ring_available  (event_ring_available),
       .ring_read_valid (event_ring_read_valid),
       .ring_read_data  (event_ring_data),
       .ring_seq        (event_ring_seq),
       .ring_read_req   (ring_read_req),
       .ring_read_index (ring_read_index),
       .busy            (evidence_busy),
       .uart_clk        (loc_clk50m),
       .uart_rst        (status_rst_50m),
        .uart_txd        (evidence_uart_txd),
        .stream_valid(uart_stream_valid[2]),.stream_last(uart_stream_last[2]),
        .stream_data(uart_stream_data[23:16]),.stream_ready(uart_stream_ready[2])
     );

     // ------------------------------------------------------------------
     // Host downlink: receive ROI requests, apply them at a frame boundary,
     // and acknowledge the result.
     // ------------------------------------------------------------------
      uart_rx #(
        .CLK_FREQ_HZ (50000000),
        .BAUD_RATE   (115200)
     ) uart_rx_inst (
       .clk   (loc_clk50m),
       .rst   (status_rst_50m),
       .rx    (uart_rxd),
       .data  (cfg_byte),
       .valid (cfg_byte_valid)
     );

      generate if(0) begin: retired_roi_downlink
      config_rx #(
       .H_ACTIVE (DISP_WIDTH),
       .V_ACTIVE (DISP_HEIGHT)
     ) config_rx_inst (
       .clk         (loc_clk50m),
       .rst         (status_rst_50m),
       .valid       (cfg_byte_valid),
       .data        (cfg_byte),
       .cfg_we      (cfg_we),
       .cfg_region  (cfg_region),
       .cfg_x0      (cfg_x0),
       .cfg_y0      (cfg_y0),
       .cfg_x1      (cfg_x1),
       .cfg_y1      (cfg_y1),
       .cfg_thr     (cfg_thr),
       .cfg_version (cfg_version),
       .cfg_status  (cfg_status)
      );
      end else begin: disabled_roi_downlink
          assign cfg_we=1'b0;assign cfg_region=0;assign cfg_x0=0;assign cfg_y0=0;
          assign cfg_x1=0;assign cfg_y1=0;assign cfg_thr=0;assign cfg_version=0;assign cfg_status=0;
      end endgenerate

      config_mailbox config_mailbox_inst (
       .src_clk     (loc_clk50m),
       .src_rst     (status_rst_50m),
       .src_valid   (cfg_we && (cfg_status == 3'd0)),
       .src_version (cfg_version),
       .src_region  (cfg_region),
       .src_x0      (cfg_x0),
       .src_y0      (cfg_y0),
       .src_x1      (cfg_x1),
       .src_y1      (cfg_y1),
       .src_thr     (cfg_thr),
       .dst_clk     (pixelclk),
       .dst_rst     (status_rst_pixel),
       .dst_valid   (cfg_dst_valid),
       .dst_version (cfg_dst_version),
       .dst_region  (cfg_dst_region),
       .dst_x0      (cfg_dst_x0),
       .dst_y0      (cfg_dst_y0),
       .dst_x1      (cfg_dst_x1),
       .dst_y1      (cfg_dst_y1),
       .dst_thr     (cfg_dst_thr)
     );

     pulse_cdc pulse_cdc_cfg_applied (
       .src_clk   (pixelclk),
       .src_rst   (status_rst_pixel),
       .src_pulse (cfg_applied_pulse),
       .dst_clk   (loc_clk50m),
       .dst_rst   (status_rst_50m),
       .dst_pulse (cfg_applied_50m)
     );

     // Pixel domain: hold a request, then apply it only at frame start so the
     // detector and the overlay always switch to the same revision together.
     always @(posedge pixelclk) begin
       if (status_rst_pixel) begin
         act_pickup_x0    <= PICKUP_X0;
         act_pickup_y0    <= PICKUP_Y0;
         act_pickup_x1    <= PICKUP_X1;
         act_pickup_y1    <= PICKUP_Y1;
         act_operation_x0 <= OPERATION_X0;
         act_operation_y0 <= OPERATION_Y0;
         act_operation_x1 <= OPERATION_X1;
         act_operation_y1 <= OPERATION_Y1;
         act_forbidden_x0 <= FORBIDDEN_X0;
         act_forbidden_y0 <= FORBIDDEN_Y0;
         act_forbidden_x1 <= FORBIDDEN_X1;
         act_forbidden_y1 <= FORBIDDEN_Y1;
         act_thr_pickup    <= 8'd12;
         act_thr_operation <= 8'd12;
         act_thr_forbidden <= 8'd16;
         config_version_active <= 8'd0;
         cfg_pending       <= 1'b0;
         cfg_applied_pulse <= 1'b0;
       end else begin
         cfg_applied_pulse <= 1'b0;

         if (cfg_dst_valid) begin
           cfg_pending  <= 1'b1;
           pend_version <= cfg_dst_version;
           pend_region  <= cfg_dst_region;
           pend_x0      <= cfg_dst_x0;
           pend_y0      <= cfg_dst_y0;
           pend_x1      <= cfg_dst_x1;
           pend_y1      <= cfg_dst_y1;
           pend_thr     <= cfg_dst_thr;
         end else if (frame_begin && cfg_pending) begin
           case (pend_region)
             2'd1: begin
               act_pickup_x0  <= pend_x0;
               act_pickup_y0  <= pend_y0;
               act_pickup_x1  <= pend_x1;
               act_pickup_y1  <= pend_y1;
               act_thr_pickup <= pend_thr;
             end
             2'd2: begin
               act_operation_x0  <= pend_x0;
               act_operation_y0  <= pend_y0;
               act_operation_x1  <= pend_x1;
               act_operation_y1  <= pend_y1;
               act_thr_operation <= pend_thr;
             end
             default: begin
               act_forbidden_x0  <= pend_x0;
               act_forbidden_y0  <= pend_y0;
               act_forbidden_x1  <= pend_x1;
               act_forbidden_y1  <= pend_y1;
               act_thr_forbidden <= pend_thr;
             end
           endcase
           config_version_active <= pend_version;
           cfg_applied_pulse     <= 1'b1;
           cfg_pending           <= 1'b0;
         end
       end
     end

     // 50 MHz: acknowledge a rejected request immediately, but only report an
     // accepted one after the pixel domain confirms it was applied. Either way
     // the line is held until the evidence stream has released the UART pin,
     // so a configuration acknowledgement can never be dropped by arbitration.
     always @(posedge loc_clk50m) begin
       if (status_rst_50m) begin
         ack_waiting      <= 1'b0;
         ack_trigger      <= 1'b0;
         ack_pending      <= 1'b0;
         ack_version_hold <= 8'd0;
         ack_status_hold  <= 3'd0;
         evidence_busy_sync <= 2'b00;
       end else begin
         ack_trigger <= 1'b0;
         evidence_busy_sync <= {evidence_busy_sync[0], evidence_busy};

         if (cfg_we) begin
           ack_version_hold <= cfg_version;
           ack_status_hold  <= cfg_status;
           ack_pending      <= 1'b1;
           if (cfg_status == 3'd0)
             ack_waiting <= 1'b1;
         end else if (ack_waiting && cfg_applied_50m) begin
           ack_waiting <= 1'b0;
         end

         if (ack_pending && !ack_waiting && !evidence_busy_50m && !cfg_ack_busy) begin
           ack_pending <= 1'b0;
           ack_trigger <= 1'b1;
         end
       end
     end

      config_ack_tx #(
        .CLK_FREQ_HZ (50000000),
        .BAUD_RATE   (115200),
        .STREAM_OUTPUT(1)
     ) config_ack_tx_inst (
       .clk      (loc_clk50m),
       .rst      (status_rst_50m),
       .trigger  (ack_trigger),
       .version  (ack_version_hold),
       .status   (ack_status_hold),
       .busy     (cfg_ack_busy),
        .uart_txd (cfg_ack_txd),
        .stream_valid(uart_stream_valid[1]),.stream_last(uart_stream_last[1]),
        .stream_data(uart_stream_data[15:8]),.stream_ready(uart_stream_ready[1])
     );

      // Complete packets only, one physical serializer. Status AL+EI stays a
      // single packet so an intervening record cannot misassociate legacy EI.
      (* keep="true" *) wire uart_packet_fault;
      (* keep="true" *) wire [31:0] uart_packets_sent,uart_packets_dropped;
       uart_packet_mux #(.SOURCES(8)) uart_packet_mux_inst(.clk(loc_clk50m),.rst(status_rst_50m),
        .in_valid(uart_stream_valid),.in_last(uart_stream_last),.in_data(uart_stream_data),.in_ready(uart_stream_ready),
         .source_cancel(8'd0),.uart_txd(uart_txd),.protocol_fault(uart_packet_fault),
        .packets_sent(uart_packets_sent),.packets_dropped(uart_packets_dropped));

     // Seven-segment status display, all in the 50 MHz domain:
     //   digits 7-4  elapsed exam time MM:SS (BCD, counts up; freezes at end)
     //   digit  3    stage                    digit 2    risk
     //   digits 1-0  last event code
     always @(posedge loc_clk50m) begin
       if (status_rst_50m)
         last_event_code_50m <= 8'd0;
       else if (status_dst_valid && (status_event_code_50m != 8'd0))
         last_event_code_50m <= status_event_code_50m;
     end

     always @(posedge loc_clk50m) begin
       if (status_rst_50m) begin
         uptime_div     <= 32'd0;
         uptime_seconds <= 8'd0;
       end else if (uptime_div >= 32'd49999999) begin
         uptime_div     <= 32'd0;
         uptime_seconds <= uptime_seconds + 8'd1;
       end else begin
         uptime_div <= uptime_div + 32'd1;
       end
     end

     // [GAZE-DIAG] Live gaze counters for the diagnostic build.
     reg [7:0] gaze_frame_cnt;
     reg [7:0] gaze_away_cnt;
     always @(posedge loc_clk50m) begin
       if (status_rst_50m) begin
         gaze_frame_cnt <= 8'd0;
         gaze_away_cnt  <= 8'd0;
       end else begin
         if (ai_gaze_pulse)
           gaze_frame_cnt <= gaze_frame_cnt + 8'd1;
         if (ai_gaze_pulse && ai_gaze_away)
           gaze_away_cnt <= gaze_away_cnt + 8'd1;
       end
     end

     // Elapsed exam timer for the seven-segment display. `remaining_s` is 0
     // before the exam, counts down in S_EXAM and freezes once submitted, so
     // EXAM_LEN_S - remaining_s counts up live and then holds. Forcing the
     // timeout (S4) drives remaining_s to 0, so the display jumps to the full
     // exam length. Shown as MM:SS BCD on digits 7-4.
     wire [15:0] exam_elapsed_s  = (exam_stage >= 3'd3)
                                    ? (exam_display_duration - exam_remaining_s) : 16'd0;
     wire [15:0] exam_elapsed_mm = exam_elapsed_s / 16'd60;
     wire [15:0] exam_elapsed_ss = exam_elapsed_s % 16'd60;
     wire [3:0]  elapsed_mm_t = exam_elapsed_mm / 16'd10;
     wire [3:0]  elapsed_mm_o = exam_elapsed_mm % 16'd10;
     wire [3:0]  elapsed_ss_t = exam_elapsed_ss / 16'd10;
     wire [3:0]  elapsed_ss_o = exam_elapsed_ss % 16'd10;

     assign seg_data = GAZE_DIAGNOSTICS ? {
       gaze_frame_cnt,        // digits 7-6: number of 07 frames received
       gaze_away_cnt,         // digits 5-4: number of away samples
       status_stage_id_50m,   // digit 3: stage
       ai_debug_gaze_cnt[3:0],// digit 2: exam_fsm gaze_cnt (low nibble)
       last_event_code_50m    // digits 1-0: last event code (does 60 appear?)
     } : {
       elapsed_mm_t,               // digit 7: elapsed minutes tens
       elapsed_mm_o,               // digit 6: elapsed minutes ones
       elapsed_ss_t,               // digit 5: elapsed seconds tens
       elapsed_ss_o,               // digit 4: elapsed seconds ones
       status_stage_id_50m,        // digit 3: stage
       status_risk_level_50m,      // digit 2: risk
       last_event_code_50m         // digits 1-0: last event code
     };

     hex8 #(
       .CLK_HZ  (50000000),
       .SCAN_HZ (1000)
     ) hex8_inst (
       .clk       (loc_clk50m),
       .rst       (status_rst_50m),
       .en        (1'b1),
       .disp_data (seg_data),
       .sel       (seg_sel),
       .seg       (seg_seg)
     );

     hc595_driver #(
       .CLK_HZ  (50000000),
       .CNT_MAX (2)
     ) hc595_driver_inst (
       .clk   (loc_clk50m),
       .rst   (status_rst_50m),
       .data  ({1'b0, seg_seg, seg_sel}),
       .s_en  (1'b1),
       .sh_cp (seg7_sclk),
       .st_cp (seg7_rclk),
       .ds    (seg7_dio)
     );
	
	// Status overlay is inserted after the proven camera/DDR3/display path.
    overlay_status #(
      .ENABLE (1'b1)
   ) overlay_status_inst (
      .pixel_in  ({enh_r, enh_g, enh_b}),
      .x         (enh_x),
      .y         (enh_y),
      .de        (enh_de),
     .roi_pickup_x0    (act_pickup_x0),
     .roi_pickup_y0    (act_pickup_y0),
     .roi_pickup_x1    (act_pickup_x1),
     .roi_pickup_y1    (act_pickup_y1),
     .roi_operation_x0 (act_operation_x0),
     .roi_operation_y0 (act_operation_y0),
     .roi_operation_x1 (act_operation_x1),
     .roi_operation_y1 (act_operation_y1),
     .roi_forbidden_x0 (act_forbidden_x0),
     .roi_forbidden_y0 (act_forbidden_y0),
     .roi_forbidden_x1 (act_forbidden_x1),
     .roi_forbidden_y1 (act_forbidden_y1),
       .stage_id  ({1'b0, exam_stage_px}),
       .risk_level({2'b00, exam_risk_px}),
       .zone_id   (4'd0),
       .event_code(exam_event_px),
       .mute      (buzzer_mute_pixel),
      .alarm_active  (alarm_active),
      .warning_active(warning_active),
      .motion_pickup    (motion_pickup),
     .motion_operation (motion_operation),
     .motion_forbidden (motion_forbidden),
     .motion_global    (motion_global),
     .pixel_out (overlay_data)
   );

	// VGA display
    wire [23:0] candidate_overlay_data;
    candidate_overlay candidate_overlay_inst(.clk(pixelclk),.rst(status_rst_pixel),.sof(enh_sof),
        .snapshot_valid(candidate_px_valid),.candidate_valid(candidate_px[192]),
        .text_codes(candidate_px[127:0]),.text_token(candidate_px[191:160]),.seat(candidate_px[159:128]),
        .stage(exam_stage_px),.x(enh_x),.y(enh_y),.de(enh_de),.pixel_in(overlay_data),
        .pixel_out(candidate_overlay_data),.displayed_token(display_token_px));
    assign disp_rgb = candidate_overlay_data;

  // Aligned HDMI boundary stage splits overlay rendering from TMDS logic.
  wire [23:0] hdmi_rgb_pipe;
  wire hdmi_hs_pipe,hdmi_vs_pipe,hdmi_de_pipe;
  display_output_pipeline hdmi_boundary_inst(.clk(pixelclk),.rst(status_rst_pixel),
      .in_rgb(candidate_overlay_data),.in_hs(disp_hs),.in_vs(disp_vs),.in_de(disp_de),
      .out_rgb(hdmi_rgb_pipe),.out_hs(hdmi_hs_pipe),.out_vs(hdmi_vs_pipe),.out_de(hdmi_de_pipe));

  //HDMI
  dvi_encoder dvi_encoder(
    .pixelclk    (pixelclk    ),
    .pixelclk5x  (pixelclk5x  ),
    .rst_p       (status_rst_pixel),
     .blue_din    (hdmi_rgb_pipe[7:0]   ),
     .green_din   (hdmi_rgb_pipe[15:8]  ),
     .red_din     (hdmi_rgb_pipe[23:16] ),
    .hsync       (hdmi_hs_pipe),
    .vsync       (hdmi_vs_pipe),
    .de          (hdmi_de_pipe),
    .tmds_clk_p  (hdmi_clk_p ),
    .tmds_clk_n  (hdmi_clk_n ),
    .tmds_data_p (hdmi_dat_p ),
    .tmds_data_n (hdmi_dat_n )
  );

  assign hdmi_oe = 1'b1;

  // Independent evidence snapshot: video client0 + live DDR evidence client1
  // share one MIG. SOF clears only video; common barrier cancels AXI together.
  (* keep = "true" *) wire [31:0] shared_source_overflow,shared_display_underflow;
  (* keep = "true" *) wire [9:0] shared_source_high,shared_display_low;
  (* keep = "true" *) wire [3:0] shared_video_fault,shared_protocol_fault;
  ddr3_shared_video_ctrl #(
    .FIFO_DW           (16  ),
    .WR_BYTE_ADDR_BEGIN (0   ),
    .WR_BYTE_ADDR_END   (DISP_WIDTH*DISP_HEIGHT*2 -1),
    .RD_BYTE_ADDR_BEGIN (0   ),
    .RD_BYTE_ADDR_END   (DISP_WIDTH*DISP_HEIGHT*2 -1),
    .FIFO_ADDR_DEPTH    (64  )
  )
  ddr3_ctrl_2port(
    .board_monitor(raw_board_monitor),
    .shared_ui_clk (evidence_ui_clk),
    .shared_ui_rst (evidence_mig_raw_rst),
    .fabric_rst(hist_fabric_rst),
    .e_awid(guard_awid),.e_arid(guard_arid),.e_awaddr(guard_awaddr),.e_araddr(guard_araddr),.e_awlen(guard_awlen),.e_arlen(guard_arlen),
    .e_awsize(guard_awsize),.e_arsize(guard_arsize),.e_awburst(guard_awburst),.e_arburst(guard_arburst),.e_awvalid(guard_awvalid),.e_arvalid(guard_arvalid),
    .e_awready(guard_awready),.e_arready(guard_arready),.e_wdata(guard_wdata),.e_wstrb(guard_wstrb),.e_wlast(guard_wlast),.e_wvalid(guard_wvalid),.e_wready(guard_wready),
    .e_bid(guard_bid),.e_bresp(guard_bresp),.e_bvalid(guard_bvalid),.e_bready(guard_bready),.e_rid(guard_rid),.e_rresp(guard_rresp),.e_rvalid(guard_rvalid),.e_rlast(guard_rlast),.e_rdata(guard_rdata),.e_rready(guard_rready),
    .source_overflow(shared_source_overflow),
    .display_underflow(shared_display_underflow),
    .source_high(shared_source_high),
    .display_low(shared_display_low),
    .video_fault(shared_video_fault),
    .protocol_fault(shared_protocol_fault),
    //clock reset
    .ddr3_clk200m  (loc_clk200m   ),
    .ddr3_rst_n    (ddr3_rst_n    ),
    .ddr3_init_done(ddr3_init_done),
    //wr_fifo Interface
    .wrfifo_clr    (wrfifo_clr    ),
    .wrfifo_clk    (pclk_bufg_o   ),
    .wrfifo_wren   (wrfifo_wren   ),
    .wrfifo_din    (wrfifo_din    ),
    .wrfifo_full   (              ),
    .wrfifo_wr_cnt (              ),
    //rd_fifo Interface
    .rdfifo_clr    (rdfifo_clr    ),
    .rdfifo_clk    (pixelclk      ),
    .rdfifo_rden   (rdfifo_rden   ),
    .rdfifo_dout   (rdfifo_dout   ),
    .rdfifo_empty  (              ),
    .rdfifo_rd_cnt (              ),
    //DDR3 Interface
    // Inouts
    .ddr3_dq       (ddr3_dq       ),
    .ddr3_dqs_n    (ddr3_dqs_n    ),
    .ddr3_dqs_p    (ddr3_dqs_p    ),
    // Outputs      
    .ddr3_addr     (ddr3_addr     ),
    .ddr3_ba       (ddr3_ba       ),
    .ddr3_ras_n    (ddr3_ras_n    ),
    .ddr3_cas_n    (ddr3_cas_n    ),
    .ddr3_we_n     (ddr3_we_n     ),
    .ddr3_reset_n  (ddr3_reset_n  ),
    .ddr3_ck_p     (ddr3_ck_p     ),
    .ddr3_ck_n     (ddr3_ck_n     ),
    .ddr3_cke      (ddr3_cke      ),
    .ddr3_cs_n     (ddr3_cs_n     ),
    .ddr3_dm       (ddr3_dm       ),
    .ddr3_odt      (ddr3_odt      )
  );

endmodule



