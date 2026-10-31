`timescale 1ns/1ps
// TEST ONLY. I2C slave interprets pins, not the master's internal request wires.
module wonderecho_wire_model(
    input wire rst,scl,sda,
    input wire enabled,
    input wire [7:0] word_id,
    output reg slave_low=0,
    output reg [7:0] last_clip=0,
    output integer writes=0,reads=0
);
    integer mode=0,bitno=0,stage=0,pointer=0;
    reg [7:0] rx=0,tx=0,clip_type=0;
    reg ack_ok=0,ack_risen=0,reading=0,ack_seen=0;
    always @(negedge sda) if(scl===1 && !rst) begin
        mode=1;bitno=0;stage=0;rx=0;reading=0;slave_low=0;
    end
    always @(posedge sda) if(scl===1 && !rst) begin mode=0;slave_low=0;end
    always @(posedge scl) if(!rst) begin
        case(mode)
            1:begin
                rx={rx[6:0],sda};
                if(bitno==7) begin
                    ack_ok=enabled;
                    if(stage==0) begin
                        if(rx[7:1]!=7'h34) $fatal(1,"wrong slave address");
                        reading=rx[0];
                    end else if(ack_ok) begin
                        if(stage==1) begin
                            pointer=rx;
                            if(pointer!=8'h64 && pointer!=8'h6e) $fatal(1,"wrong register");
                        end else begin
                            if(pointer!=8'h6e || reading) $fatal(1,"unexpected data write");
                            if(stage==2) clip_type=rx;
                            else if(stage==3) begin
                                last_clip=rx;writes=writes+1;
                                if(clip_type!=8'hff) $fatal(1,"wrong clip type");
                            end else $fatal(1,"too many write bytes");
                        end
                    end
                    stage=stage+1;mode=2;ack_risen=0;bitno=0;
                end else bitno=bitno+1;
            end
            2:ack_risen=1;
            3:if(bitno==7) begin reads=reads+1;mode=4;ack_seen=0;end else bitno=bitno+1;
            4:begin ack_seen=1;if(!sda) $fatal(1,"single byte read must NACK");end
        endcase
    end
    always @(negedge scl) if(!rst) begin
        case(mode)
            2:if(!ack_risen) slave_low=ack_ok;
              else begin
                  slave_low=0;
                  if(!ack_ok) mode=5;
                  else if(reading && stage==1) begin
                      if(pointer!=8'h64) $fatal(1,"read without pointer");
                      tx=word_id;mode=3;bitno=0;slave_low=!tx[7];
                  end else begin mode=1;bitno=0;rx=0;end
              end
            3:slave_low=!tx[7-bitno];
            4:if(!ack_seen) slave_low=0;else begin slave_low=0;mode=5;end
        endcase
    end
endmodule
