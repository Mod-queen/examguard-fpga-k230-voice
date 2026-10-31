/////////////////////////////////////////////////////////////////////////////////
// Company       : �人о·��Ƽ����޹�˾
//                 http://xiaomeige.taobao.com
// Web           : http://www.corecourse.cn
// 
// Create Date   : 2019/05/01 00:00:00
// Module Name   : camera_init
// Description   : ����ͷ��ʼ������ģ��
// 
// Dependencies  : 
// 
// Revision:
// Revision 0.01 - File Created
// Additional Comments:
// 
/////////////////////////////////////////////////////////////////////////////////

module camera_init #(
  parameter CAMERA_TYPE     = "ov5640", //"ov5640" or "ov7725"
  parameter IMAGE_TYPE      = 0,        //0:RGB 1:JPEG
  parameter IMAGE_WIDTH     = 640,
  parameter IMAGE_HEIGHT    = 480,
  parameter IMAGE_FLIP_EN   = 0,
  parameter IMAGE_MIRROR_EN = 0
)
(
  input      Clk,
  input      Rst_n,

  output reg Init_Done,
  output     camera_rst_n,
  output     camera_pwdn,

  output     i2c_sclk,
  inout      i2c_sdat
);
  localparam RGB = 0;
  localparam JPEG = 1;

  wire [15:0]addr;
  reg wrreg_req;
  reg rdreg_req;
  wire [7:0]wrdata;
  wire [7:0]rddata;
  wire RW_Done;
  wire ack;
  reg [31:0] i2c_dly_cnt_max;

  reg [8:0]cnt;
  wire [23:0]lut;

  wire [8:0]lut_size;
  wire [7:0]device_id;
  wire addr_mode;

  assign camera_pwdn = 0;

  generate
  ////////////////////////////ov5640///////////////////////////////
  if(CAMERA_TYPE == "ov5640")
  begin
    assign device_id = 8'h78;
    assign addr_mode = 1'b1;
    assign addr = lut[23:8];
    assign wrdata = lut[7:0];

    if(IMAGE_TYPE == RGB) //------RGB------
    begin
      // Count includes final ROM[266] polarity write (0x4740=0x20).
      assign lut_size = 267;

      ov5640_init_table_rgb #(
        .ADDR_WIDTH     (9               ),
        .IMAGE_WIDTH     (IMAGE_WIDTH     ),
        .IMAGE_HEIGHT    (IMAGE_HEIGHT    ),
        .IMAGE_FLIP_EN   (IMAGE_FLIP_EN   ),
        .IMAGE_MIRROR_EN (IMAGE_MIRROR_EN )
      )ov5640_init_table_rgb_inst
      (
        .addr (cnt ),
        .clk  (Clk ),
        .q    (lut )
      );
    end
    else  //------JPEG------
    begin
      assign lut_size = 264;

      ov5640_init_table_jpeg #(
        .ADDR_WIDTH     (9               ),
        .IMAGE_WIDTH     (IMAGE_WIDTH     ),
        .IMAGE_HEIGHT    (IMAGE_HEIGHT    ),
        .IMAGE_FLIP_EN   (IMAGE_FLIP_EN   ),
        .IMAGE_MIRROR_EN (IMAGE_MIRROR_EN )
      )ov5640_init_table_jpeg_inst
      (
        .addr (cnt ),
        .clk  (Clk ),
        .q    (lut )
      );
    end
  end
  ////////////////////////////ov7725////////////////////////////////
  else if(CAMERA_TYPE == "ov7725")
  begin
    assign device_id = 8'h42;
    assign addr_mode = 1'b0;
    assign addr = lut[15:8];
    assign wrdata = lut[7:0];

    if(IMAGE_TYPE == RGB) //------RGB------
    begin
      assign lut_size  = 68;

      ov7725_init_table_rgb #(
        .IMAGE_WIDTH     (IMAGE_WIDTH     ),
        .IMAGE_HEIGHT    (IMAGE_HEIGHT    ),
        .IMAGE_FLIP_EN   (IMAGE_FLIP_EN   ),
        .IMAGE_MIRROR_EN (IMAGE_MIRROR_EN )
      )ov7725_init_table_rgb_inst
      (
        .addr (cnt[7:0] ),
        .clk  (Clk ),
        .q    (lut )
      );
    end
  end
  endgenerate


  i2c_control i2c_control(
    .Clk         (Clk             ),
    .Rst_n       (Rst_n           ),
    .wrreg_req   (wrreg_req       ),
    .rdreg_req   (1'b0            ),
    .addr        (addr            ),
    .addr_mode   (addr_mode       ),
    .wrdata      (wrdata          ),
    .rddata      (rddata          ),
    .device_id   (device_id       ),
    .RW_Done     (RW_Done         ),
    .ack         (ack             ),
    .dly_cnt_max (i2c_dly_cnt_max ),
    .i2c_sclk    (i2c_sclk        ),
    .i2c_sdat    (i2c_sdat        )
  );

  wire Go;   //initial enable
  reg [20:0] delay_cnt;

  //�ϵ粢��λ���20ms������������ͷ�����Դ��ϵ絽��ʼ����Ӧ����1.0034 + 20 = 21.0034ms
  //����Ϊ���Ż��߼����򻯱Ƚ����߼���ֱ��ʹ�ӳٱȽ�ֵΪ24'h100800����21.0125ms
  always@(posedge Clk or negedge Rst_n)
  if(~Rst_n)
    delay_cnt <= 21'd0;
  else if (delay_cnt == 21'h100800)
    delay_cnt <= 21'h100800;
  else
    delay_cnt <= delay_cnt + 1'd1;

  //����ʱʱ�䵽����ʼʹ�ܳ�ʼ��ģ���OV5640�ļĴ�������д��  
  assign Go = (delay_cnt == 21'h1007ff) ? 1'b1 : 1'b0;

//  //5640Ҫ���ϵ���临λ״̬��Ҫ����1ms�������ϵ����Ҫ1ms֮����ʹ���ͷ�����ͷ�ĸ�λ�ź�
//  //����Ϊ���Ż��߼����򻯱Ƚ����߼���ֱ��ʹ�ӳٱȽ�ֵΪ24'hC400����1.003520ms
//  assign camera_rst_n = (delay_cnt > 21'h00C400);

  assign camera_rst_n = 1;

  always@(posedge Clk or negedge Rst_n)
  if(~Rst_n)
    cnt <= 0;
  else if(Go) 
    cnt <= 0;
  else if(cnt < lut_size)begin
    if(RW_Done && (!ack))
      cnt <= cnt + 1'b1;
    else
      cnt <= cnt;
  end
  else
    cnt <= 0;

  always@(posedge Clk or negedge Rst_n)
  if(~Rst_n)
    Init_Done <= 0;
  else if(Go) 
    Init_Done <= 0;
  else if(cnt == lut_size)
    Init_Done <= 1;

  reg [1:0]state;

  always@(posedge Clk or negedge Rst_n)
  if(~Rst_n)begin
    state <= 0;
    wrreg_req <= 1'b0;
    i2c_dly_cnt_max <= 32'd0;
  end
  else if(cnt < lut_size)begin
    case(state)
      0:
        if(Go)
          state <= 1;
        else
          state <= 0;
      1:
        begin
          wrreg_req <= 1'b1;
          state <= 2;
          if(cnt == 1)
            i2c_dly_cnt_max <= 32'h40000; //��ʱ5ms
          else
            i2c_dly_cnt_max <= 32'd0;
        end
      2:
        begin
          wrreg_req <= 1'b0;
          if(RW_Done)
            state <= 1;
          else
            state <= 2;
        end
      default:state <= 0;
    endcase
  end
  else
    state <= 0;

endmodule
