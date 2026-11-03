// Only for "make pnr". A real pin for every input would need a pin assignment
// for each one, so bits arrive and leave through one pin each. Every path into
// and out of pipe_adder then starts and ends at a flip-flop, and gets timed.
module pipe_adder_top #(
    parameter WIDTH  = 32,
    parameter STAGES = 2
) (
    input  wire clk,
    input  wire din,
    output wire dout
);

    reg [2*WIDTH+1:0] in_sr;    // rst, in_valid, a, b
    reg [WIDTH+1:0]   out_sr;

    wire             out_valid;
    wire [WIDTH-1:0] sum;
    wire             carry;

    // The inversion stops Yosys merging this shift register with the alignment
    // registers, which would hold the same bits.
    always @(posedge clk) begin
        in_sr  <= ~{in_sr[2*WIDTH:0], din};
        out_sr <= {out_sr[WIDTH:0], 1'b0} ^ {out_valid, carry, sum};
    end

    assign dout = out_sr[WIDTH+1];

    pipe_adder #(.WIDTH(WIDTH), .STAGES(STAGES)) dut (
        .clk(clk), .rst(in_sr[2*WIDTH+1]), .in_valid(in_sr[2*WIDTH]),
        .a(in_sr[2*WIDTH-1:WIDTH]), .b(in_sr[WIDTH-1:0]),
        .out_valid(out_valid), .sum(sum), .carry(carry)
    );

endmodule
