// Combinational ALU: no clock and no stored state. WIDTH must be at least 2.
module alu #(
    parameter WIDTH = 8
) (
    input  wire [WIDTH-1:0] a,
    input  wire [WIDTH-1:0] b,
    input  wire [2:0]       op,
    output reg  [WIDTH-1:0] y,
    output reg              carry,  // carry out of add, borrow out of sub, otherwise 0
    output wire             zero    // high when y is 0
);

    localparam [2:0] OP_ADD = 3'd0;
    localparam [2:0] OP_SUB = 3'd1;
    localparam [2:0] OP_AND = 3'd2;
    localparam [2:0] OP_OR  = 3'd3;
    localparam [2:0] OP_XOR = 3'd4;
    localparam [2:0] OP_SHL = 3'd5;  // logical, by the low bits of b
    localparam [2:0] OP_SHR = 3'd6;  // logical, by the low bits of b
    localparam [2:0] OP_SLT = 3'd7;  // y is 1 if a < b as signed numbers

    wire [$clog2(WIDTH)-1:0] shift = b[$clog2(WIDTH)-1:0];

    always @(*) begin
        // Default assignments. Each path through the case now gives both
        // outputs a value, so neither has to remember an old one.
        y     = {WIDTH{1'b0}};
        carry = 1'b0;

        case (op)
            OP_ADD: {carry, y} = {1'b0, a} + {1'b0, b};
            OP_SUB: {carry, y} = {1'b0, a} - {1'b0, b};
            OP_AND: y = a & b;
            OP_OR:  y = a | b;
            OP_XOR: y = a ^ b;
            OP_SHL: y = a << shift;
            OP_SHR: y = a >> shift;
            OP_SLT: y[0] = $signed(a) < $signed(b);
        endcase
    end

    assign zero = ~|y;

`ifdef FORMAL
    // The rules from the table in the README, written apart from the design:
    // numbers rather than the OP_ names, and b rather than the shift wire, so
    // that a mistake in those cannot hide. Add and sub are stated as properties.
    always @(*) begin
        case (op)
            3'd0: begin
                assert (y == a + b);
                assert (carry == (y < a));
            end
            3'd1: begin
                assert (y + b == a);
                assert (carry == (a < b));
            end
            3'd2: assert (y == (a & b));
            3'd3: assert (y == (a | b));
            3'd4: assert (y == (a ^ b));
            3'd5: assert (y == (a << b[$clog2(WIDTH)-1:0]));
            3'd6: assert (y == (a >> b[$clog2(WIDTH)-1:0]));
            3'd7: begin
                if (a[WIDTH-1] != b[WIDTH-1])
                    assert (y == a[WIDTH-1]);
                else
                    assert (y == (a < b));
            end
        endcase

        if (op >= 3'd2)
            assert (!carry);

        assert (zero == (y == 0));
    end
`endif

endmodule
