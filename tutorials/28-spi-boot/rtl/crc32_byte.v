// CRC-32 as used by Ethernet, zip and PNG, one byte per clock.
//
// The same CRC as crc32_serial.v. The loop below is eight steps of the serial
// CRC, and synthesis unrolls it into one layer of XOR gates.
module crc32_byte (
    input  wire        clk,
    input  wire        rst,     // synchronous, starts a new message
    input  wire        clear,   // starts a new message, and beats valid
    input  wire        valid,   // take data on this clock
    input  wire [7:0]  data,
    output wire [31:0] crc      // the CRC of every byte taken since the last clear
);

    localparam [31:0] POLY = 32'hEDB88320;

    // Bit 0 of the byte goes first, as on an Ethernet wire.
    function [31:0] next_state(input [31:0] s, input [7:0] d);
        integer i;
        begin
            next_state = s;
            for (i = 0; i < 8; i = i + 1)
                next_state = {1'b0, next_state[31:1]}
                           ^ ((next_state[0] ^ d[i]) ? POLY : 32'd0);
        end
    endfunction

    reg [31:0] state;

    always @(posedge clk) begin
        if (rst || clear)
            state <= 32'hFFFFFFFF;
        else if (valid)
            state <= next_state(state, data);
    end

    assign crc = ~state;

endmodule
