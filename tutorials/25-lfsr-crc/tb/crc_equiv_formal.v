// Proves that the serial CRC and both byte CRCs agree after every byte, for
// every stream of bytes, gaps and clears that the solver can choose.
module crc_equiv_formal (
    input wire clk
);

    // Chosen by the solver, afresh on every clock.
    (* anyseq *) reg       f_start;
    (* anyseq *) reg [7:0] f_byte;
    (* anyseq *) reg       f_clear;

    reg       past_valid = 1'b0;
    reg       busy       = 1'b0;   // the serial CRC is part way through a byte
    reg [2:0] bits_left  = 3'd0;
    reg [6:0] shift      = 7'd0;   // the bits of the byte still to send

    // A new byte starts only between bytes. Clear also happens only between
    // bytes, and goes to all three CRCs at once.
    wire start = !busy && f_start && !f_clear;
    wire clear = !busy && f_clear;
    wire rst   = !past_valid;

    wire bit_valid = start || busy;
    wire bit_in    = busy ? shift[0] : f_byte[0];

    wire [31:0] serial_crc;
    wire [31:0] byte_crc;
    wire [31:0] xor_crc;

    crc32_serial serial (
        .clk(clk), .rst(rst), .clear(clear), .valid(bit_valid), .bit_in(bit_in),
        .crc(serial_crc)
    );

    crc32_byte parallel (
        .clk(clk), .rst(rst), .clear(clear), .valid(start), .data(f_byte),
        .crc(byte_crc)
    );

    crc32_byte_xor generated (
        .clk(clk), .rst(rst), .clear(clear), .valid(start), .data(f_byte),
        .crc(xor_crc)
    );

    always @(posedge clk) begin
        past_valid <= 1'b1;
        if (rst) begin
            busy <= 1'b0;
        end else if (start) begin
            busy      <= 1'b1;
            bits_left <= 3'd7;
            shift     <= f_byte[7:1];
        end else if (busy) begin
            shift     <= {1'b0, shift[6:1]};
            bits_left <= bits_left - 3'd1;
            if (bits_left == 3'd1)
                busy <= 1'b0;
        end
    end

    // The two byte CRCs are the same logic, so they agree on every clock.
    // The serial one catches up at the end of each byte.
    always @(*) begin
        if (past_valid) begin
            assert (xor_crc == byte_crc);
            if (!busy)
                assert (serial_crc == byte_crc);
        end
    end

    // Counts bytes since the last clear, to give the covers something to aim at.
    reg [3:0] bytes = 4'd0;
    always @(posedge clk) begin
        if (rst || clear)
            bytes <= 4'd0;
        else if (start && bytes != 4'd15)
            bytes <= bytes + 4'd1;
    end

    always @(*) begin
        if (past_valid && !busy) begin
            cover (bytes == 4'd2);
            // Another message with the same CRC as "123456789".
            cover (bytes == 4'd4 && byte_crc == 32'hCBF43926);
        end
    end

endmodule
