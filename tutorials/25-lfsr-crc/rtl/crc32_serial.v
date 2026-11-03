// CRC-32 as used by Ethernet, zip and PNG, one bit per clock.
//
// Reflected: each byte goes in bit 0 first, and the register shifts right.
// The register starts at all ones, and crc is the register inverted.
module crc32_serial (
    input  wire        clk,
    input  wire        rst,     // synchronous, starts a new message
    input  wire        clear,   // starts a new message, and beats valid
    input  wire        valid,   // take bit_in on this clock
    input  wire        bit_in,
    output wire [31:0] crc      // the CRC of every bit taken since the last clear
);

    // x^32 + x^26 + x^23 + x^22 + x^16 + x^12 + x^11 + x^10 + x^8 + x^7 + x^5
    // + x^4 + x^2 + x + 1 is 32'h04C11DB7. Shifting right needs it reversed.
    localparam [31:0] POLY = 32'hEDB88320;

    reg  [31:0] state;
    wire        feedback = state[0] ^ bit_in;

    always @(posedge clk) begin
        if (rst || clear)
            state <= 32'hFFFFFFFF;
        else if (valid)
            state <= {1'b0, state[31:1]} ^ (feedback ? POLY : 32'd0);
    end

    assign crc = ~state;

endmodule
