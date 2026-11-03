`timescale 1ns/1ps

// Sends the same bytes to the serial CRC, one bit per clock, and to both byte
// CRCs, one byte per clock. The expected values are the published CRC-32 ones.
module tb_crc;

    reg         clk = 1'b0;
    reg         rst = 1'b1;
    reg         clear = 1'b0;
    reg         bit_valid = 1'b0;
    reg         bit_in = 1'b0;
    reg         byte_valid = 1'b0;
    reg  [7:0]  data = 8'd0;
    wire [31:0] serial_crc;
    wire [31:0] byte_crc;
    wire [31:0] xor_crc;

    reg  [31:0] sent_crc;

    integer errors = 0;
    integer i;

    crc32_serial serial (
        .clk(clk), .rst(rst), .clear(clear), .valid(bit_valid), .bit_in(bit_in),
        .crc(serial_crc)
    );

    crc32_byte parallel (
        .clk(clk), .rst(rst), .clear(clear), .valid(byte_valid), .data(data),
        .crc(byte_crc)
    );

    crc32_byte_xor generated (
        .clk(clk), .rst(rst), .clear(clear), .valid(byte_valid), .data(data),
        .crc(xor_crc)
    );

    always #5 clk = ~clk;

    // One byte, in eight clocks. The byte CRCs take it on the first clock, and
    // the serial CRC takes one bit per clock, bit 0 first. Call after a falling edge.
    task send_byte(input [7:0] b);
        integer k;
        begin
            for (k = 0; k < 8; k = k + 1) begin
                byte_valid = (k == 0);
                data       = b;
                bit_valid  = 1'b1;
                bit_in     = b[k];
                @(negedge clk);
            end
            byte_valid = 1'b0;
            bit_valid  = 1'b0;
            if (serial_crc !== byte_crc || xor_crc !== byte_crc) begin
                $display("FAIL t=%0t after %h serial=%h byte=%h xor=%h",
                         $time, b, serial_crc, byte_crc, xor_crc);
                errors = errors + 1;
            end
        end
    endtask

    task start_message;
        begin
            clear = 1'b1;
            @(negedge clk);
            clear = 1'b0;
        end
    endtask

    // The first character of a Verilog string is in its top byte.
    task send_string(input [8*64-1:0] s, input integer len);
        integer k;
        begin
            for (k = len - 1; k >= 0; k = k - 1)
                send_byte(s[8*k +: 8]);
        end
    endtask

    task expect_crc(input [31:0] want, input [8*32-1:0] what);
        begin
            $display("%0s: serial=%h byte=%h xor=%h", what, serial_crc, byte_crc, xor_crc);
            if (serial_crc !== want || byte_crc !== want || xor_crc !== want) begin
                $display("FAIL %0s expected=%h", what, want);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("build/tb_crc.vcd");
        $dumpvars(0, tb_crc);

        @(negedge clk);
        rst = 1'b0;

        // No bytes at all: the register is still all ones, and the CRC is 0.
        expect_crc(32'h00000000, "empty message");

        // The standard check value for CRC-32.
        send_string("123456789", 9);
        expect_crc(32'hCBF43926, "\"123456789\"");

        // The residue: append the CRC, low byte first, and the CRC of the whole
        // thing is always 2144DF1C, whatever the message was.
        sent_crc = byte_crc;
        for (i = 0; i < 4; i = i + 1)
            send_byte(sent_crc[8*i +: 8]);
        expect_crc(32'h2144DF1C, "with its CRC appended");

        // A second message, after clear.
        start_message;
        send_string("The quick brown fox jumps over the lazy dog", 43);
        expect_crc(32'h414FA339, "\"The quick brown fox...\"");
        sent_crc = byte_crc;
        for (i = 0; i < 4; i = i + 1)
            send_byte(sent_crc[8*i +: 8]);
        expect_crc(32'h2144DF1C, "with its CRC appended");

        // valid low holds, and clear beats valid.
        start_message;
        send_string("123456789", 9);
        repeat (5) @(negedge clk);
        expect_crc(32'hCBF43926, "after 5 idle clocks");
        clear      = 1'b1;
        byte_valid = 1'b1;
        bit_valid  = 1'b1;
        data       = 8'h31;
        bit_in     = 1'b1;
        @(negedge clk);
        clear      = 1'b0;
        byte_valid = 1'b0;
        bit_valid  = 1'b0;
        expect_crc(32'h00000000, "clear with valid high");

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
