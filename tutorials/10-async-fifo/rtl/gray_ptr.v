// A FIFO pointer, held in binary and in Gray code. It has ADDR_WIDTH+1 bits:
// the low bits are the memory address and the extra top bit counts the wraps.
module gray_ptr #(
    parameter ADDR_WIDTH = 4
) (
    input  wire                  clk,
    input  wire                  rst,   // synchronous, active high, overrides inc
    input  wire                  inc,   // moves the pointer on by one
    output wire [ADDR_WIDTH-1:0] addr,  // binary, for the memory in this clock domain
    output reg  [ADDR_WIDTH:0]   gray   // Gray, the only form that leaves this clock domain
);

    reg  [ADDR_WIDTH:0] bin;
    wire [ADDR_WIDTH:0] bin_next = bin + {{ADDR_WIDTH{1'b0}}, inc};

    // Gray code is the binary value XORed with itself shifted right by one.
    function [ADDR_WIDTH:0] to_gray(input [ADDR_WIDTH:0] value);
        to_gray = value ^ (value >> 1);
    endfunction

    assign addr = bin[ADDR_WIDTH-1:0];

    // gray is a flop, not an assign from bin. Logic between here and the other
    // clock domain could glitch, and the far side could catch the glitch.
    always @(posedge clk) begin
        if (rst) begin
            bin  <= 0;
            gray <= 0;
        end else begin
            bin  <= bin_next;
            gray <= to_gray(bin_next);
        end
    end

`ifdef FORMAL
    // The rest of the proof sees only gray, so tie bin to it here. Power-up
    // values are ruled out only until reset, which sets both to 0 anyway.
    initial assume (gray == to_gray(bin));

    always @(*)
        assert (gray == to_gray(bin));
`endif

endmodule
