// Three flip-flops in a row, written as separate registers. Each stage takes the
// value that the stage before it held just before the clock edge.
module chain (
    input  wire clk,
    input  wire d,
    output reg  a,
    output reg  b,
    output reg  c
);

    always @(posedge clk) begin
        a <= d;
        b <= a;
        c <= b;
    end

endmodule
