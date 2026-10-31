`timescale 1ns/1ps

// Self-checking testbench for voice_asr_i2c and voice_command_map.
//
// An open-drain I2C slave BFM answers address 0x34, returns a programmable
// word from register 0x64 and captures writes to register 0x6E. The test
// checks new-word reporting, de-duplication, re-arming after a zero, the
// word-to-action mapping, a TTS write and error status.
module voice_asr_i2c_tb;

    reg        clk;
    reg        rst;
    reg        tts_req;
    reg  [7:0] tts_type;
    reg  [7:0] tts_id;
    wire       word_valid;
    wire [7:0] word_id;
    wire       busy;
    wire       nack_error;
    wire       scl;
    wire       sda;

    wire       ack_pulse;
    wire       mute_pulse;
    wire       manual_pulse;
    wire [7:0] last_id;

    // 10 MHz core, 1 MHz-ish SCL: each bit is 4 phases of 2 clocks.
    voice_asr_i2c #(
        .SYS_CLOCK      (10_000_000),
        .SCL_CLOCK      (1_000_000),
        .POLL_CYCLES    (200),
        .TIMEOUT_CYCLES (100_000)
    ) dut (
        .clk        (clk),
        .rst        (rst),
        .tts_req    (tts_req),
        .tts_type   (tts_type),
        .tts_id     (tts_id),
        .word_valid (word_valid),
        .word_id    (word_id),
        .busy       (busy),
        .nack_error (nack_error),
        .i2c_scl    (scl),
        .i2c_sda    (sda)
    );

    voice_command_map map_inst (
        .clk          (clk),
        .rst          (rst),
        .word_valid   (word_valid),
        .word_id      (word_id),
        .ack_pulse    (ack_pulse),
        .mute_pulse   (mute_pulse),
        .manual_pulse (manual_pulse),
        .last_id      (last_id)
    );

    pullup(scl);
    pullup(sda);

    // -------------------------------------------------------------------------
    // Open-drain slave BFM.
    // -------------------------------------------------------------------------
    reg        sda_low;
    assign sda = sda_low ? 1'b0 : 1'bz;

    reg [7:0]  slave_word;
    reg [7:0]  addr_b;
    reg [7:0]  reg_b;
    reg [7:0]  rx_b;
    reg [7:0]  tts_type_cap;
    reg [7:0]  tts_id_cap;
    integer    tts_count;
    reg        master_ack;

    task wait_start;
        begin
            @(negedge sda);
            while (scl !== 1'b1)
                @(negedge sda);
        end
    endtask

    task rx_byte;
        integer k;
        begin
            for (k = 7; k >= 0; k = k - 1) begin
                @(posedge scl);
                rx_b[k] = sda;
                @(negedge scl);
            end
        end
    endtask

    task drive_ack;
        begin
            sda_low = 1'b1;
            @(posedge scl);
            @(negedge scl);
            sda_low = 1'b0;
        end
    endtask

    task tx_byte;
        input [7:0] d;
        integer k;
        begin
            for (k = 7; k >= 0; k = k - 1) begin
                sda_low = ~d[k];
                @(posedge scl);
                @(negedge scl);
            end
            sda_low = 1'b0;
        end
    endtask

    task read_master_ack;
        begin
            sda_low = 1'b0;
            @(posedge scl);
            master_ack = sda;
            @(negedge scl);
        end
    endtask

    task wait_stop;
        begin
            @(posedge sda);
            while (scl !== 1'b1)
                @(posedge sda);
        end
    endtask

    initial begin
        sda_low = 1'b0;
        forever begin
            wait_start;
            rx_byte;
            addr_b = rx_b;
            drive_ack;

            if (addr_b[0] == 1'b0) begin
                rx_byte;
                reg_b = rx_b;
                drive_ack;

                if (reg_b == 8'h6E) begin
                    rx_byte;
                    tts_type_cap = rx_b;
                    drive_ack;
                    rx_byte;
                    tts_id_cap = rx_b;
                    drive_ack;
                    tts_count = tts_count + 1;
                    wait_stop;
                end else if (reg_b == 8'h64) begin
                    wait_start;            // repeated START
                    rx_byte;
                    addr_b = rx_b;
                    drive_ack;
                    tx_byte(slave_word);
                    read_master_ack;
                    wait_stop;
                end else begin
                    wait_stop;
                end
            end else begin
                wait_stop;
            end
        end
    end

    // -------------------------------------------------------------------------
    // Scoreboard and test sequence.
    // -------------------------------------------------------------------------
    integer   errors;
    integer   word_count;
    integer   ack_count;
    integer   mute_count;
    integer   manual_count;
    reg [7:0] seen_id;
    reg       seen_valid;
    reg       test_done;

    always @(posedge clk) begin
        if (word_valid) begin
            word_count = word_count + 1;
            seen_id    = word_id;
            seen_valid = 1'b1;
        end
        if (ack_pulse)
            ack_count = ack_count + 1;
        if (mute_pulse)
            mute_count = mute_count + 1;
        if (manual_pulse)
            manual_count = manual_count + 1;
    end

    always #50 clk = ~clk;   // 10 MHz

    task run_cycles;
        input integer n;
        integer i;
        begin
            for (i = 0; i < n; i = i + 1)
                @(posedge clk);
        end
    endtask

    task check;
        input             cond;
        input [8*40-1:0]  name;
        begin
            if (cond)
                $display("  ok   : %0s", name);
            else begin
                $display("  FAIL : %0s", name);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        clk          = 1'b0;
        rst          = 1'b1;
        tts_req      = 1'b0;
        tts_type     = 8'h00;
        tts_id       = 8'h00;
        slave_word   = 8'h00;
        errors       = 0;
        word_count   = 0;
        ack_count    = 0;
        mute_count   = 0;
        manual_count = 0;
        seen_id      = 8'h00;
        seen_valid   = 1'b0;
        tts_count    = 0;
        tts_type_cap = 8'h00;
        tts_id_cap   = 8'h00;
        test_done    = 1'b0;

        run_cycles(8);
        rst = 1'b0;

        // 1) First poll returns word 1 -> acknowledge action.
        slave_word = 8'd1;
        seen_valid = 1'b0;
        run_cycles(3000);
        check(seen_valid === 1'b1 && seen_id === 8'd1, "word 1 recognised");
        check(ack_count === 1 && mute_count === 0 && manual_count === 0,
              "word 1 -> acknowledge only");

        // 2) The same standing word must not fire twice.
        seen_valid = 1'b0;
        run_cycles(3000);
        check(seen_valid === 1'b0 && ack_count === 1, "duplicate word suppressed");

        // 3) A different word maps to mute.
        slave_word = 8'd2;
        seen_valid = 1'b0;
        run_cycles(3000);
        check(seen_valid === 1'b1 && seen_id === 8'd2, "word 2 recognised");
        check(mute_count === 1 && ack_count === 1, "word 2 -> mute only");

        // 4) Zero is ignored.
        slave_word = 8'd0;
        seen_valid = 1'b0;
        run_cycles(3000);
        check(seen_valid === 1'b0, "zero word ignored");

        // 5) The same word re-arms after it returns to zero.
        slave_word = 8'd2;
        seen_valid = 1'b0;
        run_cycles(3000);
        check(seen_valid === 1'b1 && seen_id === 8'd2, "word re-armed after zero");
        check(mute_count === 2, "second mute action");

        // 6) TTS write to 0x6E.
        tts_type = 8'h00;
        tts_id   = 8'd5;
        tts_req  = 1'b1;
        run_cycles(2);
        tts_req  = 1'b0;
        run_cycles(3000);
        check(tts_count === 1 && tts_type_cap === 8'h00 && tts_id_cap === 8'd5,
              "TTS announcement written");

        // 7) Word 3 maps to the manual evidence trigger.
        slave_word = 8'd3;
        seen_valid = 1'b0;
        run_cycles(3000);
        check(seen_valid === 1'b1 && seen_id === 8'd3, "word 3 recognised");
        check(manual_count === 1, "word 3 -> manual trigger only");

        // 8) An unmapped word is recorded but produces no action.
        slave_word = 8'd4;
        seen_valid = 1'b0;
        run_cycles(3000);
        check(seen_valid === 1'b1 && seen_id === 8'd4, "word 4 recorded");
        check(ack_count === 1 && mute_count === 2 && manual_count === 1,
              "unmapped word has no action");
        check(last_id === 8'd4, "last_id tracks latest word");
        check(nack_error === 1'b0, "no NACK reported");

        if (errors == 0)
            $display("PASS: voice_asr_i2c (%0d words, %0d tts)", word_count, tts_count);
        else
            $display("FAIL: voice_asr_i2c (%0d errors)", errors);
        test_done = 1'b1;
        $finish;
    end

    initial begin
        #10_000_000;
        if (!test_done)
            $display("FAIL: voice_asr_i2c timeout");
        $finish;
    end

endmodule
