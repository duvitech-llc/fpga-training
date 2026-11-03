// Galois LFSR: the bit leaving the top is XORed into every tap position while
// the register shifts left. This is multiplying by x, modulo the polynomial.
//
// POLY has the same meaning as in lfsr_fib.v: bit k is the coefficient of x^k,
// without the x^WIDTH term. Bit 0 must be 1, and the state must never be 0.
module lfsr_galois #(
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

    wire top = q[WIDTH-1];

    assign out = top;

    always @(posedge clk) begin
        if (rst)
            q <= SEED;
        else if (load)
            q <= load_value;
        else if (en)
            q <= {q[WIDTH-2:0], 1'b0} ^ (top ? POLY : {WIDTH{1'b0}});
    end

endmodule
