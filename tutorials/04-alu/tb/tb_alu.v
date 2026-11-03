`timescale 1ns/1ps

module tb_alu;

    parameter WIDTH = 4;

    localparam integer RANGE = 1 << WIDTH;

    // The ALU has no clock. This one only paces the test: a new input on each
    // falling edge, checked before the next, as with the clocked designs.
    reg              clk = 1'b0;
    reg  [WIDTH-1:0] a;
    reg  [WIDTH-1:0] b;
    reg  [2:0]       op;
    wire [WIDTH-1:0] y;
    wire             carry;
    wire             zero;

    integer errors = 0;
    integer ia, ib, iop;
    integer signed_a, signed_b, shift;
    integer expected_y, expected_carry;

    alu #(.WIDTH(WIDTH)) dut (.a(a), .b(b), .op(op), .y(y), .carry(carry), .zero(zero));

    always #5 clk = ~clk;

    // Works out the answers with plain integers, not by copying the design.
    task expect_result;
        begin
            signed_a = (ia >= RANGE / 2) ? ia - RANGE : ia;
            signed_b = (ib >= RANGE / 2) ? ib - RANGE : ib;
            shift    = ib % (1 << $clog2(WIDTH));

            expected_carry = 0;
            case (iop)
                0: begin
                    expected_y     = (ia + ib) % RANGE;
                    expected_carry = (ia + ib >= RANGE) ? 1 : 0;
                end
                1: begin
                    expected_y     = (ia + RANGE - ib) % RANGE;
                    expected_carry = (ia < ib) ? 1 : 0;
                end
                2: expected_y = ia & ib;
                3: expected_y = ia | ib;
                4: expected_y = ia ^ ib;
                5: expected_y = (ia << shift) % RANGE;
                6: expected_y = ia >> shift;
                default: expected_y = (signed_a < signed_b) ? 1 : 0;
            endcase
        end
    endtask

    // Call just after a falling edge, and each call takes one clock cycle.
    // !== also catches a value that is still x or z.
    task step;
        begin
            a  = ia[WIDTH-1:0];
            b  = ib[WIDTH-1:0];
            op = iop[2:0];
            expect_result;
            #1;
            if (y !== expected_y[WIDTH-1:0] || carry !== expected_carry[0]
                    || zero !== (expected_y == 0)) begin
                $display("FAIL t=%0t op=%0d a=%0d b=%0d y=%0d carry=%b zero=%b expected y=%0d carry=%0d",
                         $time, op, a, b, y, carry, zero, expected_y, expected_carry);
                errors = errors + 1;
            end
            @(negedge clk);
        end
    endtask

    initial begin
        $dumpfile("build/tb_alu.vcd");
        $dumpvars(0, tb_alu);

        @(negedge clk);

        // Every combination of the inputs, one operation at a time.
        for (iop = 0; iop < 8; iop = iop + 1)
            for (ia = 0; ia < RANGE; ia = ia + 1)
                for (ib = 0; ib < RANGE; ib = ib + 1)
                    step;

        if (errors == 0)
            $display("PASS: %0d input combinations", 8 * RANGE * RANGE);
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
