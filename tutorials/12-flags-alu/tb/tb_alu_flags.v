`timescale 1ns/1ps

// WIDTH should stay small: the loops multiply the work by 4 for each extra bit,
// and the plain integers below hold the answers only up to about 16 bits.
module tb_alu_flags;

    parameter WIDTH = 8;
    // If not 0, the main loops keep a and b between -SMALL and SMALL-1.
    parameter SMALL = 0;

    localparam integer RANGE = 1 << WIDTH;
    localparam integer LIMIT = (SMALL != 0) ? SMALL : RANGE / 2;

    localparam integer ADD = 0, ADC = 1, SUB = 2, SBC = 3;
    localparam integer SHL = 8, ROL = 11;

    // The ALU has no clock. This one only paces the test: a new input on each
    // falling edge, checked before the next, as with the clocked designs.
    reg              clk = 1'b0;
    reg  [WIDTH-1:0] a;
    reg  [WIDTH-1:0] b;
    reg              carry_in;
    reg  [3:0]       op;
    wire [WIDTH-1:0] y;
    wire             z, c, n, v;

    integer errors = 0;
    integer ia, ib, ic, iop, i;
    integer unsigned_a, unsigned_b, signed_a, signed_b, cin;
    integer unsigned_answer, signed_answer;
    integer expected_y, expected_c, expected_v;

    alu_flags #(.WIDTH(WIDTH)) dut (.a(a), .b(b), .carry_in(carry_in), .op(op),
                                    .y(y), .z(z), .c(c), .n(n), .v(v));

    always #5 clk = ~clk;

    task report_failure;
        begin
            if (errors < 10)
                $display("FAIL t=%0t op=%0d a=%0d b=%0d carry_in=%b y=%0d z=%b c=%b n=%b v=%b expected y=%0d c=%0d v=%0d",
                         $time, op, a, b, carry_in, y, z, c, n, v,
                         expected_y, expected_c, expected_v);
            errors = errors + 1;
        end
    endtask

    // Works out the answers with plain integers, not by copying the design.
    task expect_result(input integer o);
        begin
            unsigned_a = {{32-WIDTH{1'b0}}, a};
            unsigned_b = {{32-WIDTH{1'b0}}, b};
            cin        = carry_in ? 1 : 0;
            signed_a   = (unsigned_a >= RANGE / 2) ? unsigned_a - RANGE : unsigned_a;
            signed_b   = (unsigned_b >= RANGE / 2) ? unsigned_b - RANGE : unsigned_b;

            // Anything that does not set signed_answer has no overflow.
            unsigned_answer = 0;
            signed_answer   = 0;
            expected_c      = 0;

            case (o)
                0, 1: begin  // ADD, ADC
                    unsigned_answer = unsigned_a + unsigned_b + ((o == ADC) ? cin : 0);
                    signed_answer   = signed_a + signed_b + ((o == ADC) ? cin : 0);
                    expected_c      = (unsigned_answer >= RANGE) ? 1 : 0;
                end
                2, 3: begin  // SUB, SBC
                    unsigned_answer = unsigned_a - unsigned_b - ((o == SBC) ? 1 - cin : 0);
                    signed_answer   = signed_a - signed_b - ((o == SBC) ? 1 - cin : 0);
                    expected_c      = (unsigned_answer >= 0) ? 1 : 0;
                end
                4: unsigned_answer = unsigned_a & unsigned_b;
                5: unsigned_answer = unsigned_a | unsigned_b;
                6: unsigned_answer = unsigned_a ^ unsigned_b;
                7: unsigned_answer = RANGE - 1 - unsigned_a;
                8, 11: begin  // SHL and ROL double
                    unsigned_answer = 2 * unsigned_a + ((o == ROL) ? cin : 0);
                    signed_answer   = 2 * signed_a + ((o == ROL) ? cin : 0);
                    expected_c      = (unsigned_answer >= RANGE) ? 1 : 0;
                end
                9: begin  // SHR
                    unsigned_answer = unsigned_a / 2;
                    expected_c      = unsigned_a % 2;
                end
                10: begin  // ASR rounds down, and integer / rounds toward 0
                    unsigned_answer = (signed_a - unsigned_a % 2) / 2;
                    expected_c      = unsigned_a % 2;
                end
                12: begin  // ROR
                    unsigned_answer = unsigned_a / 2 + cin * RANGE / 2;
                    expected_c      = unsigned_a % 2;
                end
                13: unsigned_answer = unsigned_b;
                default: ;
            endcase

            expected_y = ((unsigned_answer % RANGE) + RANGE) % RANGE;
            expected_v = (signed_answer < -RANGE / 2 || signed_answer >= RANGE / 2) ? 1 : 0;
        end
    endtask

    // Call just after a falling edge, and each call takes one clock cycle.
    // !== also catches a value that is still x or z.
    task step(input integer o, input [WIDTH-1:0] x, input [WIDTH-1:0] w, input ci);
        begin
            a        = x;
            b        = w;
            carry_in = ci;
            op       = o[3:0];
            expect_result(o);
            #1;
            if (y !== expected_y[WIDTH-1:0] || c !== expected_c[0] || v !== expected_v[0]
                    || z !== (expected_y == 0) || n !== (expected_y >= RANGE / 2))
                report_failure;

            // The comparisons from the README, against plain integer comparisons.
            if (o == SUB && (z !== (signed_a == signed_b)
                    || (!c)      !== (unsigned_a <  unsigned_b)
                    || (!c || z) !== (unsigned_a <= unsigned_b)
                    || (n ^ v)   !== (signed_a   <  signed_b)
                    || ((n ^ v) || z) !== (signed_a <= signed_b)))
                report_failure;

            @(negedge clk);
        end
    endtask

    // One step, printed, so the numbers in the README come from this run.
    task show(input [23:0] name, input integer o, input integer x, input integer w, input ci);
        begin
            step(o, x[WIDTH-1:0], w[WIDTH-1:0], ci);
            $display("%s a=%0d (%0d) b=%0d (%0d) carry_in=%b: y=%0d (%0d) z=%b c=%b n=%b v=%b",
                     name, a, $signed(a), b, $signed(b), carry_in,
                     y, $signed(y), z, c, n, v);
        end
    endtask

    // A sum twice as wide as the ALU, built from two ALU operations.
    reg [2*WIDTH-1:0]        wide_y;
    reg                      wide_c, wide_v, wide_n, wide_z;
    reg signed [2*WIDTH+1:0] exact_signed, wide_top;
    reg [2*WIDTH+1:0]        exact_unsigned;

    task wide_add(input [2*WIDTH-1:0] p, input [2*WIDTH-1:0] q);
        begin
            step(ADD, p[WIDTH-1:0], q[WIDTH-1:0], 1'b0);
            wide_y[WIDTH-1:0] = y;
            wide_z            = z;
            step(ADC, p[2*WIDTH-1:WIDTH], q[2*WIDTH-1:WIDTH], c);
            wide_y[2*WIDTH-1:WIDTH] = y;
            {wide_c, wide_n, wide_v} = {c, n, v};
            wide_z = wide_z && z;  // z alone only describes the high half

            exact_unsigned = {2'b00, p} + {2'b00, q};
            exact_signed   = $signed({{2{p[2*WIDTH-1]}}, p}) + $signed({{2{q[2*WIDTH-1]}}, q});
            wide_check(exact_unsigned >= (wide_top << 1), p, q);
        end
    endtask

    task wide_sub(input [2*WIDTH-1:0] p, input [2*WIDTH-1:0] q);
        begin
            step(SUB, p[WIDTH-1:0], q[WIDTH-1:0], 1'b0);
            wide_y[WIDTH-1:0] = y;
            wide_z            = z;
            step(SBC, p[2*WIDTH-1:WIDTH], q[2*WIDTH-1:WIDTH], c);
            wide_y[2*WIDTH-1:WIDTH] = y;
            {wide_c, wide_n, wide_v} = {c, n, v};
            wide_z = wide_z && z;

            exact_unsigned = {2'b00, p} - {2'b00, q};
            exact_signed   = $signed({{2{p[2*WIDTH-1]}}, p}) - $signed({{2{q[2*WIDTH-1]}}, q});
            wide_check(p >= q, p, q);
        end
    endtask

    task wide_check(input expected_carry, input [2*WIDTH-1:0] p, input [2*WIDTH-1:0] q);
        begin
            if (wide_y !== exact_unsigned[2*WIDTH-1:0] || wide_c !== expected_carry
                    || wide_n !== exact_unsigned[2*WIDTH-1]
                    || wide_z !== (exact_unsigned[2*WIDTH-1:0] == 0)
                    || wide_v !== (exact_signed >= wide_top || exact_signed < -wide_top)) begin
                if (errors < 10)
                    $display("FAIL wide p=%0d q=%0d y=%0d c=%b n=%b v=%b z=%b",
                             p, q, wide_y, wide_c, wide_n, wide_v, wide_z);
                errors = errors + 1;
            end
        end
    endtask

    // Shifting a wide number: SHL the low half, then ROL the carry into the high half.
    task wide_shift(input [2*WIDTH-1:0] p);
        begin
            step(SHL, p[WIDTH-1:0], {WIDTH{1'b0}}, 1'b0);
            wide_y[WIDTH-1:0] = y;
            step(ROL, p[2*WIDTH-1:WIDTH], {WIDTH{1'b0}}, c);
            wide_y[2*WIDTH-1:WIDTH] = y;
            if ({c, wide_y} !== {p, 1'b0}) begin
                if (errors < 10)
                    $display("FAIL wide shift p=%0d y=%0d c=%b", p, wide_y, c);
                errors = errors + 1;
            end
        end
    endtask

    reg [2*WIDTH-1:0] wide_p, wide_q;
    reg [63:0]        random_bits;

    initial begin
        $dumpfile("build/tb_alu_flags.vcd");
        $dumpvars(0, tb_alu_flags);

        wide_top = 1;
        wide_top = wide_top << (2 * WIDTH - 1);

        @(negedge clk);

        // The same adder, read both ways. Numbers in brackets are signed.
        // SMALL means small numbers only, so it leaves these out.
        if (SMALL == 0) begin
            show("ADD", ADD, 100,  20, 1'b0);  // neither flag
            show("ADD", ADD, 200, 100, 1'b0);  // c only
            show("ADD", ADD, 100, 100, 1'b0);  // v only
            show("ADD", ADD, 128, 255, 1'b0);  // c and v
            show("SUB", SUB,   5,   3, 1'b0);  // no borrow, so c is 1
            show("SUB", SUB,   3,   5, 1'b0);  // borrow, so c is 0
            show("SUB", SUB, 100, 156, 1'b0);  // unsigned a < b, signed a > b
            show("ADD", ADD, 200, 100, 1'b0);  // low byte of 456 + 356
            show("ADC", ADC,   1,   1, c);     // high byte takes the carry
            show("ADD", ADD,   1,   0, 1'b0);  // low byte of 1 + 0
            show("ADC", ADC,   0,   0, c);     // z is high, but the answer is 1
        end

        // These are the checks, not a picture: without this the VCD is very large.
        $dumpoff;

        // Every combination of the inputs. op changes fastest, so that a latch
        // cannot hide behind a stale value (see the end of Tutorial 4).
        for (ia = -LIMIT; ia < LIMIT; ia = ia + 1)
            for (ib = -LIMIT; ib < LIMIT; ib = ib + 1)
                for (ic = 0; ic < 2; ic = ic + 1)
                    for (iop = 0; iop < 16; iop = iop + 1)
                        step(iop, ia[WIDTH-1:0], ib[WIDTH-1:0], ic[0]);

        // Sums twice as wide as the ALU: corner values, then random ones.
        for (i = 0; i < ((SMALL != 0) ? 0 : 4000); i = i + 1) begin
            random_bits = {$random, $random};
            wide_p = random_bits[2*WIDTH-1:0];
            random_bits = {$random, $random};
            wide_q = random_bits[2*WIDTH-1:0];
            if (i % 8 == 1) wide_q = wide_p;
            if (i % 8 == 2) wide_q = -wide_p;
            if (i % 8 == 3) wide_q = {{WIDTH{1'b0}}, {WIDTH{1'b1}}};  // carry across
            if (i % 8 == 4) wide_p = {1'b1, {2*WIDTH-1{1'b0}}};       // most negative
            if (i % 8 == 5) wide_p = {{WIDTH{1'b0}}, wide_p[WIDTH-1:0]};  // high half 0
            wide_add(wide_p, wide_q);
            wide_sub(wide_p, wide_q);
            wide_shift(wide_p);
        end

        if (errors == 0)
            $display("PASS: %0d input combinations, %0d wide operations",
                     32 * (2 * LIMIT) * (2 * LIMIT), 3 * i);
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
