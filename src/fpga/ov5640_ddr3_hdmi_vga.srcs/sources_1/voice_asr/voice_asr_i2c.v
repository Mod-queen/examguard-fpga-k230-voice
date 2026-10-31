`timescale 1ns/1ps

// -----------------------------------------------------------------------------
// Hiwonder WonderEcho (CI1302) I2C master.
//
// The module is an I2C slave at 7-bit address 0x34:
//   * reading register 0x64 returns the last recognised word ID (0 = none);
//   * writing [type, id] to register 0x6E triggers a TTS announcement, where
//     type 0x00 selects a command-word clip and 0xFF a general announcement.
//
// The FPGA polls 0x64 every POLL_CYCLES. A one-clock word_valid pulse is
// produced whenever the returned ID is non-zero and differs from the previous
// read, so one spoken word yields exactly one command pulse (the module returns
// 0 between words, which re-arms the same word). A pending TTS request takes
// priority over the next poll.
//
// The bit engine is self-contained (a synchronous-reset variant of the proven
// camera I2C shift core) with an open-drain SCL as well as open-drain SDA, so
// the bus idles high from the first clock and another master on the shared bus
// cannot be fought.
// -----------------------------------------------------------------------------
module voice_asr_i2c #(
    parameter integer SYS_CLOCK      = 50_000_000,
    parameter integer SCL_CLOCK      = 100_000,
    parameter integer POLL_CYCLES    = 2_500_000, // 50 ms at 50 MHz
    parameter integer TIMEOUT_CYCLES = 500_000    // abort a stuck transaction
) (
    input         clk,
    input         rst,             // synchronous, active high

    // TTS request: hold tts_type/tts_id valid while tts_req is high.
    input         tts_req,
    input  [7:0]  tts_type,
    input  [7:0]  tts_id,

    // Recognised word, one-clock pulse.
    output reg        word_valid,
    output reg [7:0]  word_id,

    // Diagnostics.
    output            busy,
    output reg        nack_error,

    // I2C bus, open drain, externally pulled up.
    output            i2c_scl,
    inout             i2c_sda
);

    localparam [6:0] DEV_ADDR   = 7'h34;
    localparam [7:0] REG_RESULT = 8'h64;
    localparam [7:0] REG_SPEAK  = 8'h6E;

    // Command bits, matching the camera I2C core.
    localparam [5:0] CMD_WR   = 6'b000001;
    localparam [5:0] CMD_STA  = 6'b000010;
    localparam [5:0] CMD_RD   = 6'b000100;
    localparam [5:0] CMD_STO  = 6'b001000;
    localparam [5:0] CMD_ACK  = 6'b010000;
    localparam [5:0] CMD_NACK = 6'b100000;

    // -------------------------------------------------------------------------
    // Quarter-bit clock divider and open-drain bus drivers.
    // -------------------------------------------------------------------------
    localparam integer SCL_CNT_M = (SYS_CLOCK / SCL_CLOCK / 4) - 1;

    reg  [19:0] div_cnt;
    reg         en_div_cnt;
    wire        sclk_plus = (div_cnt == SCL_CNT_M);

    reg scl_reg;   // 1 releases SCL high, 0 pulls it low
    reg sda_oe;
    reg sda_o;     // level to drive when sda_oe

    always @(posedge clk) begin
        if (rst)
            div_cnt <= 20'd0;
        else if (en_div_cnt)
            div_cnt <= sclk_plus ? 20'd0 : (div_cnt + 20'd1);
        else
            div_cnt <= 20'd0;
    end

    assign i2c_scl = scl_reg ? 1'bz : 1'b0;
    assign i2c_sda = (sda_oe && !sda_o) ? 1'b0 : 1'bz;

    wire sda_in = i2c_sda;

    // -------------------------------------------------------------------------
    // Bit engine: START, byte TX, byte RX, ACK/NACK, STOP.
    // -------------------------------------------------------------------------
    reg  [5:0] cmd;
    reg  [7:0] tx_data;
    reg        go;
    wire [7:0] rx_data;
    wire       trans_done;
    wire       ack_o;

    reg [7:0]  bstate;
    reg [4:0]  bcnt;
    reg [7:0]  rx_shift;
    reg        trans_done_r;
    reg        ack_o_r;

    localparam B_IDLE   = 8'h01,
               B_STA    = 8'h02,
               B_WR     = 8'h04,
               B_RD     = 8'h08,
               B_ACKCHK = 8'h10,
               B_ACKGEN = 8'h20,
               B_STO    = 8'h40;

    always @(posedge clk) begin
        if (rst) begin
            bstate       <= B_IDLE;
            bcnt         <= 5'd0;
            rx_shift     <= 8'd0;
            trans_done_r <= 1'b0;
            ack_o_r      <= 1'b0;
            en_div_cnt   <= 1'b0;
            scl_reg      <= 1'b1;
            sda_oe       <= 1'b0;
            sda_o        <= 1'b1;
        end else begin
            case (bstate)
                B_IDLE: begin
                    trans_done_r <= 1'b0;
                    sda_oe       <= 1'b1;
                    if (go) begin
                        en_div_cnt <= 1'b1;
                        if (cmd & CMD_STA)
                            bstate <= B_STA;
                        else if (cmd & CMD_WR)
                            bstate <= B_WR;
                        else if (cmd & CMD_RD)
                            bstate <= B_RD;
                        else
                            bstate <= B_IDLE;
                    end else begin
                        en_div_cnt <= 1'b0;
                        bstate     <= B_IDLE;
                    end
                end

                B_STA: begin
                    if (sclk_plus) begin
                        bcnt <= (bcnt == 5'd3) ? 5'd0 : (bcnt + 5'd1);
                        case (bcnt)
                            5'd0:    begin sda_o <= 1'b1; sda_oe <= 1'b1; end
                            5'd1:    begin scl_reg <= 1'b1; end
                            5'd2:    begin sda_o <= 1'b0; scl_reg <= 1'b1; end
                            5'd3:    begin scl_reg <= 1'b0; end
                            default: begin sda_o <= 1'b1; scl_reg <= 1'b1; end
                        endcase
                        if (bcnt == 5'd3) begin
                            if (cmd & CMD_WR)
                                bstate <= B_WR;
                            else if (cmd & CMD_RD)
                                bstate <= B_RD;
                        end
                    end
                end

                B_WR: begin
                    if (sclk_plus) begin
                        bcnt <= (bcnt == 5'd31) ? 5'd0 : (bcnt + 5'd1);
                        case (bcnt)
                            5'd0, 5'd4, 5'd8,  5'd12,
                            5'd16, 5'd20, 5'd24, 5'd28: begin
                                sda_o  <= tx_data[7-bcnt[4:2]];
                                sda_oe <= 1'b1;
                            end
                            5'd1, 5'd5, 5'd9,  5'd13,
                            5'd17, 5'd21, 5'd25, 5'd29: scl_reg <= 1'b1;
                            5'd2, 5'd6, 5'd10, 5'd14,
                            5'd18, 5'd22, 5'd26, 5'd30: scl_reg <= 1'b1;
                            5'd3, 5'd7, 5'd11, 5'd15,
                            5'd19, 5'd23, 5'd27, 5'd31: scl_reg <= 1'b0;
                            default: begin sda_o <= 1'b1; scl_reg <= 1'b1; end
                        endcase
                        if (bcnt == 5'd31)
                            bstate <= B_ACKCHK;
                    end
                end

                B_RD: begin
                    if (sclk_plus) begin
                        bcnt <= (bcnt == 5'd31) ? 5'd0 : (bcnt + 5'd1);
                        case (bcnt)
                            5'd0, 5'd4, 5'd8,  5'd12,
                            5'd16, 5'd20, 5'd24, 5'd28: begin
                                sda_oe  <= 1'b0;
                                scl_reg <= 1'b0;
                            end
                            5'd1, 5'd5, 5'd9,  5'd13,
                            5'd17, 5'd21, 5'd25, 5'd29: scl_reg <= 1'b1;
                            5'd2, 5'd6, 5'd10, 5'd14,
                            5'd18, 5'd22, 5'd26, 5'd30: begin
                                scl_reg  <= 1'b1;
                                rx_shift <= {rx_shift[6:0], sda_in};
                            end
                            5'd3, 5'd7, 5'd11, 5'd15,
                            5'd19, 5'd23, 5'd27, 5'd31: scl_reg <= 1'b0;
                            default: begin sda_o <= 1'b1; scl_reg <= 1'b1; end
                        endcase
                        if (bcnt == 5'd31)
                            bstate <= B_ACKGEN;
                    end
                end

                B_ACKCHK: begin
                    if (sclk_plus) begin
                        bcnt <= (bcnt == 5'd3) ? 5'd0 : (bcnt + 5'd1);
                        case (bcnt)
                            5'd0:    begin sda_oe <= 1'b0; scl_reg <= 1'b0; end
                            5'd1:    begin scl_reg <= 1'b1; end
                            5'd2:    begin ack_o_r <= sda_in; scl_reg <= 1'b1; end
                            5'd3:    begin scl_reg <= 1'b0; end
                            default: begin sda_o <= 1'b1; scl_reg <= 1'b1; end
                        endcase
                        if (bcnt == 5'd3) begin
                            if (cmd & CMD_STO)
                                bstate <= B_STO;
                            else begin
                                bstate       <= B_IDLE;
                                trans_done_r <= 1'b1;
                            end
                        end
                    end
                end

                B_ACKGEN: begin
                    if (sclk_plus) begin
                        bcnt <= (bcnt == 5'd3) ? 5'd0 : (bcnt + 5'd1);
                        case (bcnt)
                            5'd0: begin
                                sda_oe  <= 1'b1;
                                scl_reg <= 1'b0;
                                if (cmd & CMD_ACK)
                                    sda_o <= 1'b0;
                                else if (cmd & CMD_NACK)
                                    sda_o <= 1'b1;
                            end
                            5'd1:    begin scl_reg <= 1'b1; end
                            5'd2:    begin scl_reg <= 1'b1; end
                            5'd3:    begin scl_reg <= 1'b0; end
                            default: begin sda_o <= 1'b1; scl_reg <= 1'b1; end
                        endcase
                        if (bcnt == 5'd3) begin
                            if (cmd & CMD_STO)
                                bstate <= B_STO;
                            else begin
                                bstate       <= B_IDLE;
                                trans_done_r <= 1'b1;
                            end
                        end
                    end
                end

                B_STO: begin
                    if (sclk_plus) begin
                        bcnt <= (bcnt == 5'd3) ? 5'd0 : (bcnt + 5'd1);
                        case (bcnt)
                            5'd0:    begin sda_o <= 1'b0; sda_oe <= 1'b1; end
                            5'd1:    begin scl_reg <= 1'b1; end
                            5'd2:    begin sda_o <= 1'b1; scl_reg <= 1'b1; end
                            5'd3:    begin scl_reg <= 1'b1; end
                            default: begin sda_o <= 1'b1; scl_reg <= 1'b1; end
                        endcase
                        if (bcnt == 5'd3) begin
                            trans_done_r <= 1'b1;
                            bstate       <= B_IDLE;
                        end
                    end
                end

                default: bstate <= B_IDLE;
            endcase
        end
    end

    assign rx_data    = rx_shift;
    assign trans_done = trans_done_r;
    assign ack_o      = ack_o_r;

    // -------------------------------------------------------------------------
    // Transaction sequencer.
    //
    // READ (register 0x64):  START W 0x68 | 0x64 | START 0x69 | read, NACK, STOP
    // WRITE (register 0x6E): START W 0x68 | 0x6E | type | id, STOP
    // -------------------------------------------------------------------------
    localparam OP_READ  = 1'b0;
    localparam OP_WRITE = 1'b1;

    localparam [2:0] SEQ_IDLE  = 3'd0,
                     SEQ_ISSUE = 3'd1,
                     SEQ_WAIT  = 3'd2,
                     SEQ_DONE  = 3'd3;

    reg [2:0]  seq;
    reg        op;
    reg [2:0]  step;
    reg [7:0]  tts_type_hold;
    reg [7:0]  tts_id_hold;
    reg        tts_pending;
    reg [7:0]  last_word;
    reg [23:0] poll_cnt;
    reg [19:0] wd_cnt;
    reg        is_tx_step;

    always @(posedge clk) begin
        if (rst) begin
            seq           <= SEQ_IDLE;
            op            <= OP_READ;
            step          <= 3'd0;
            cmd           <= 6'd0;
            tx_data       <= 8'd0;
            go            <= 1'b0;
            tts_pending   <= 1'b0;
            tts_type_hold <= 8'd0;
            tts_id_hold   <= 8'd0;
            last_word     <= 8'd0;
            poll_cnt      <= 24'd0;
            wd_cnt        <= 20'd0;
            word_valid    <= 1'b0;
            word_id       <= 8'd0;
            nack_error    <= 1'b0;
            is_tx_step    <= 1'b0;
        end else begin
            word_valid <= 1'b0;
            go         <= 1'b0;

            if (tts_req && !tts_pending) begin
                tts_pending   <= 1'b1;
                tts_type_hold <= tts_type;
                tts_id_hold   <= tts_id;
            end

            case (seq)
                SEQ_IDLE: begin
                    poll_cnt <= poll_cnt + 24'd1;
                    if (tts_pending) begin
                        tts_pending <= 1'b0;
                        op         <= OP_WRITE;
                        step       <= 3'd0;
                        poll_cnt   <= 24'd0;
                        seq        <= SEQ_ISSUE;
                    end else if (poll_cnt >= (POLL_CYCLES - 1)) begin
                        op       <= OP_READ;
                        step     <= 3'd0;
                        poll_cnt <= 24'd0;
                        seq      <= SEQ_ISSUE;
                    end
                end

                SEQ_ISSUE: begin
                    go         <= 1'b1;
                    is_tx_step <= 1'b1;
                    nack_error <= (step == 3'd0) ? 1'b0 : nack_error;
                    if (op == OP_READ) begin
                        case (step)
                            3'd0: begin cmd <= CMD_WR | CMD_STA; tx_data <= {DEV_ADDR, 1'b0}; end
                            3'd1: begin cmd <= CMD_WR;          tx_data <= REG_RESULT;        end
                            3'd2: begin cmd <= CMD_WR | CMD_STA; tx_data <= {DEV_ADDR, 1'b1}; end
                            3'd3: begin
                                cmd        <= CMD_RD | CMD_NACK | CMD_STO;
                                tx_data    <= 8'h00;
                                is_tx_step <= 1'b0;
                            end
                            default: ;
                        endcase
                    end else begin
                        case (step)
                            3'd0: begin cmd <= CMD_WR | CMD_STA; tx_data <= {DEV_ADDR, 1'b0}; end
                            3'd1: begin cmd <= CMD_WR;          tx_data <= REG_SPEAK;         end
                            3'd2: begin cmd <= CMD_WR;          tx_data <= tts_type_hold;     end
                            3'd3: begin cmd <= CMD_WR | CMD_STO; tx_data <= tts_id_hold;      end
                            default: ;
                        endcase
                    end
                    wd_cnt <= 20'd0;
                    seq    <= SEQ_WAIT;
                end

                SEQ_WAIT: begin
                    if (trans_done) begin
                        if (is_tx_step && ack_o)
                            nack_error <= 1'b1;
                        if (step == 3'd3) begin
                            seq <= SEQ_DONE;
                        end else begin
                            step <= step + 3'd1;
                            seq  <= SEQ_ISSUE;
                        end
                    end else begin
                        wd_cnt <= wd_cnt + 20'd1;
                        if (wd_cnt >= TIMEOUT_CYCLES) begin
                            nack_error <= 1'b1;
                            seq        <= SEQ_IDLE;
                        end
                    end
                end

                SEQ_DONE: begin
                    if (op == OP_READ) begin
                        if ((rx_data != 8'd0) && (rx_data != last_word)) begin
                            word_valid <= 1'b1;
                            word_id    <= rx_data;
                        end
                        last_word <= (rx_data != 8'd0) ? rx_data : 8'd0;
                    end
                    poll_cnt <= 24'd0;
                    seq      <= SEQ_IDLE;
                end

                default: seq <= SEQ_IDLE;
            endcase
        end
    end

    assign busy = (seq != SEQ_IDLE);

endmodule
