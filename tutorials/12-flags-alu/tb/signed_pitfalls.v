// Run with "make pitfalls". Each line prints what Verilog really computes, and
// the run stops if a tool ever gives something other than what the README says.
module signed_pitfalls;

    reg signed [7:0]  s   = -3;
    reg        [7:0]  u   = 2;
    reg        [7:0]  raw = 8'hFD;  // the same bits as s, in an unsigned reg
    reg               sel = 1'b1;
    reg signed [15:0] w;
    reg        [7:0]  y;
    reg               t;

    integer errors = 0;

    task check(input [8*30-1:0] label, input integer got, input integer right, input integer lesson);
        begin
            $display("%s = %0d  (the right answer is %0d)", label, got, right);
            if (got != lesson)
                errors = errors + 1;
        end
    endtask

    initial begin
        // One unsigned operand makes the whole comparison unsigned.
        t = s < u;                     check("s < u",                 t, 1, 0);
        t = s < $signed({1'b0, u});    check("s < $signed({1'b0, u})", t, 1, 1);

        // The same for a sum, and s is zero-extended on the way up to 16 bits.
        w = s + u;                     check("s + u",                 w, -1, 255);
        w = s + $signed({1'b0, u});    check("s + $signed({1'b0, u})", w, -1, -1);

        // 1'b1 is unsigned. A plain 1 is a signed integer.
        w = s + 1'b1;                  check("s + 1'b1",              w, -2, 254);
        w = s + 1;                     check("s + 1",                 w, -2, -2);

        // A part-select is unsigned, even when it selects every bit.
        w = s[7:0];                    check("s[7:0]",                w, -3, 253);

        // >>> only copies the sign bit if the expression is signed.
        y = raw >>> 1;                 check("raw >>> 1",             y, 254, 126);
        y = $signed(raw) >>> 1;        check("$signed(raw) >>> 1",    y, 254, 254);

        // The other branch of a ?: is part of the same expression.
        y = sel ? $signed(raw) >>> 1 : raw;
        check("sel ? $signed(raw) >>> 1 : raw", y, 254, 126);

        if (errors != 0)
            $fatal(1, "FAIL: %0d lines differ from the README", errors);
        $finish;
    end

endmodule
