// WIDTH bits of the flip-flop from Tutorial 1: synchronous reset and enable.
module enreg #(
    parameter WIDTH = 8
) (
    input  wire             clk,
    input  wire             rst,  // synchronous, active high, overrides en
    input  wire             en,   // q holds its value when low
    input  wire [WIDTH-1:0] d,
    output reg  [WIDTH-1:0] q
);

    always @(posedge clk) begin
        if (rst)
            q <= {WIDTH{1'b0}};
        else if (en)
            q <= d;
    end

endmodule
