// Combinational ALU with four status flags. No clock and no stored state.
// WIDTH must be at least 2.
//
// z is high when y is 0, and n is the top bit of y, for every operation.
// c and v depend on the operation:
//
//   op  name    y                          c                   v
//    0  ADD     a + b                      carry out           signed overflow
//    1  ADC     a + b + carry_in           carry out           signed overflow
//    2  SUB     a - b                      NOT borrow          signed overflow
//    3  SBC     a - b - !carry_in          NOT borrow          signed overflow
//    4  AND     a & b                      0                   0
//    5  OR      a | b                      0                   0
//    6  XOR     a ^ b                      0                   0
//    7  NOT     ~a                         0                   0
//    8  SHL     a left, 0 comes in         old top bit of a    sign of a changed
//    9  SHR     a right, 0 comes in        old bit 0 of a      0
//   10  ASR     a right, sign bit is kept  old bit 0 of a      0
//   11  ROL     a left, carry_in comes in  old top bit of a    sign of a changed
//   12  ROR     a right, carry_in comes in old bit 0 of a      0
//   13  PASS_B  b                          0                   0
//   14, 15      0                          0                   0
//
// Subtraction: c is NOT borrow. c = 1 means nothing was borrowed, so a >= b.
// SBC takes the same meaning on carry_in: 1 means no borrow is coming in.
// Shifts and rotates move a by exactly one place and ignore b.
module alu_flags #(
    parameter WIDTH = 8
) (
    input  wire [WIDTH-1:0] a,
    input  wire [WIDTH-1:0] b,
    input  wire             carry_in,  // used by ADC, SBC, ROL and ROR only
    input  wire [3:0]       op,
    output reg  [WIDTH-1:0] y,
    output wire             z,         // zero
    output reg              c,         // carry
    output wire             n,         // negative
    output reg              v          // signed overflow
);

    localparam [3:0] OP_ADD    = 4'd0;
    localparam [3:0] OP_ADC    = 4'd1;
    localparam [3:0] OP_SUB    = 4'd2;
    localparam [3:0] OP_SBC    = 4'd3;
    localparam [3:0] OP_AND    = 4'd4;
    localparam [3:0] OP_OR     = 4'd5;
    localparam [3:0] OP_XOR    = 4'd6;
    localparam [3:0] OP_NOT    = 4'd7;
    localparam [3:0] OP_SHL    = 4'd8;
    localparam [3:0] OP_SHR    = 4'd9;
    localparam [3:0] OP_ASR    = 4'd10;
    localparam [3:0] OP_ROL    = 4'd11;
    localparam [3:0] OP_ROR    = 4'd12;
    localparam [3:0] OP_PASS_B = 4'd13;

    // One adder does all four sums. a - b is a + ~b + 1.
    wire             is_sub    = (op == OP_SUB) || (op == OP_SBC);
    wire             use_carry = (op == OP_ADC) || (op == OP_SBC);
    wire [WIDTH-1:0] addend    = is_sub ? ~b : b;
    wire             add_in    = use_carry ? carry_in : is_sub;
    wire [WIDTH:0]   sum       = {1'b0, a} + {1'b0, addend} + {{WIDTH{1'b0}}, add_in};

    // Two numbers of the same sign gave a result of the other sign. The sign
    // that counts is that of addend, the number really added, not that of b.
    wire overflow = (a[WIDTH-1] == addend[WIDTH-1]) && (sum[WIDTH-1] != a[WIDTH-1]);

    // Doubling a number overflows when it changes the sign bit.
    wire sign_changed = a[WIDTH-1] != a[WIDTH-2];

    always @(*) begin
        // Default assignments, as in Tutorial 4, so no path makes a latch.
        y = {WIDTH{1'b0}};
        c = 1'b0;
        v = 1'b0;

        case (op)
            OP_ADD, OP_ADC, OP_SUB, OP_SBC: begin
                {c, y} = sum;
                v      = overflow;
            end
            OP_AND: y = a & b;
            OP_OR:  y = a | b;
            OP_XOR: y = a ^ b;
            OP_NOT: y = ~a;
            OP_SHL: begin
                {c, y} = {a, 1'b0};
                v      = sign_changed;
            end
            OP_SHR: {y, c} = {1'b0, a};
            OP_ASR: begin
                y = $signed(a) >>> 1'b1;
                c = a[0];
            end
            OP_ROL: begin
                {c, y} = {a, carry_in};
                v      = sign_changed;
            end
            OP_ROR:    {y, c} = {carry_in, a};
            OP_PASS_B: y = b;
            default:   ;  // 14 and 15 are unused, and keep the defaults
        endcase
    end

    assign z = ~|y;
    assign n = y[WIDTH-1];

`ifdef FORMAL
    // Every flag from its definition, using numbers two bits wider than the
    // design so that nothing can overflow here. All of these are signed, and
    // none of them use sum, addend, overflow or the OP_ names.
    wire signed [WIDTH+1:0] f_ua = {2'b00, a};
    wire signed [WIDTH+1:0] f_ub = {2'b00, b};
    wire signed [WIDTH+1:0] f_uy = {2'b00, y};
    wire signed [WIDTH+1:0] f_sa = {{2{a[WIDTH-1]}}, a};
    wire signed [WIDTH+1:0] f_sb = {{2{b[WIDTH-1]}}, b};
    wire signed [WIDTH+1:0] f_sy = {{2{y[WIDTH-1]}}, y};

    wire signed [WIDTH+1:0] f_cin      = {{WIDTH+1{1'b0}}, carry_in};
    wire signed [WIDTH+1:0] f_c        = {{WIDTH+1{1'b0}}, c};
    wire signed [WIDTH+1:0] f_wrap     = {2'b01, {WIDTH{1'b0}}};            // 2**WIDTH
    wire signed [WIDTH+1:0] f_c_weight = c ? f_wrap : {WIDTH+2{1'b0}};      // c * 2**WIDTH
    wire signed [WIDTH+1:0] f_b_weight = c ? {WIDTH+2{1'b0}} : f_wrap;      // !c * 2**WIDTH
    wire signed [WIDTH+1:0] f_in_top   = carry_in ? f_wrap : {WIDTH+2{1'b0}};
    wire signed [WIDTH+1:0] f_smax     = {3'b000, {WIDTH-1{1'b1}}};         // largest signed
    wire signed [WIDTH+1:0] f_smin     = {3'b111, {WIDTH-1{1'b0}}};         // smallest signed

    // The true answer for one operation, for the v column.
    reg signed [WIDTH+1:0] f_exact;

    always @(*) begin
        f_exact = 0;

        case (op)
            // y and c together hold the true sum, and c is its top bit.
            4'd0: begin
                assert (f_uy + f_c_weight == f_ua + f_ub);
                f_exact = f_sa + f_sb;
            end
            4'd1: begin
                assert (f_uy + f_c_weight == f_ua + f_ub + f_cin);
                f_exact = f_sa + f_sb + f_cin;
            end
            // y falls short of the true difference by 2**WIDTH if we borrowed.
            4'd2: begin
                assert (f_uy - f_b_weight == f_ua - f_ub);
                f_exact = f_sa - f_sb;
            end
            4'd3: begin
                assert (f_uy - f_b_weight == f_ua - f_ub - 1 + f_cin);
                f_exact = f_sa - f_sb - 1 + f_cin;
            end
            4'd4: assert (y == (a & b));
            4'd5: assert (y == (a | b));
            4'd6: assert (y == (a ^ b));
            4'd7: assert (y == ~a);
            // A shift left doubles. A shift right halves, and c is the remainder.
            4'd8: begin
                assert (f_uy + f_c_weight == f_ua + f_ua);
                f_exact = f_sa + f_sa;
            end
            4'd9:  assert (f_uy + f_uy + f_c == f_ua);
            4'd10: assert (f_sy + f_sy + f_c == f_sa);
            4'd11: begin
                assert (f_uy + f_c_weight == f_ua + f_ua + f_cin);
                f_exact = f_sa + f_sa + f_cin;
            end
            4'd12: assert (f_uy + f_uy + f_c == f_ua + f_in_top);
            4'd13: assert (y == b);
            default: assert (y == 0);
        endcase

        // v: the true answer does not fit in WIDTH signed bits.
        assert (v == (f_exact < f_smin || f_exact > f_smax));

        // Logic operations clear c.
        if ((op >= 4'd4 && op <= 4'd7) || op >= 4'd13)
            assert (!c);

        assert (z == (y == 0));
        assert (n == (f_sy < 0));

        // What the flags are for: after SUB they compare a and b.
        if (op == 4'd2) begin
            assert (z == (a == b));
            assert (c == (f_ua >= f_ub));
            assert ((n != v) == (f_sa < f_sb));
        end
    end
`endif

endmodule
