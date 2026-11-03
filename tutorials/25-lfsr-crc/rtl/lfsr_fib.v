// Fibonacci LFSR: the taps are XORed together into one new bit, which enters at
// the top while the register shifts right.
//
// POLY holds the polynomial without its x^WIDTH term: bit k is the coefficient
// of x^k. x^4 + x + 1 is 4'b0011. Bit 0 must be 1. The state must never be 0,
// because 0 stays 0 for ever.
module lfsr_fib #(
    parameter             WIDTH = 16,
    parameter [WIDTH-1:0] POLY  = 16'h6801,  // x^16 + x^14 + x^13 + x^11 + 1
    parameter [WIDTH-1:0] SEED  = 1
) (
    input  wire             clk,
    input  wire             rst,
    input  wire             en,
    input  wire             load,
    input  wire [WIDTH-1:0] load_value,
    output reg  [WIDTH-1:0] q,
    output wire             out
);

    wire feedback = ^(q & POLY);

    assign out = q[0];

    always @(posedge clk) begin
        if (rst)
            q <= SEED;
        else if (load)
            q <= load_value;
        else if (en)
            q <= {feedback, q[WIDTH-1:1]};
    end

endmodule
