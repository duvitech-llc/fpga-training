`timescale 1ns/1ps

module tb_chain;

    reg  clk = 1'b0;
    reg  d   = 1'b0;
    wire a;
    wire b;
    wire c;

    integer errors = 0;
    integer i;

    // One pulse on d, then what each stage should hold after each rising edge.
    reg [5:0] pulse      = 6'b000001;
    reg [5:0] expected_a = 6'b000001;
    reg [5:0] expected_b = 6'b000010;
    reg [5:0] expected_c = 6'b000100;

    chain dut (.clk(clk), .d(d), .a(a), .b(b), .c(c));

    always #5 clk = ~clk;

    initial begin
        $dumpfile("build/tb_chain.vcd");
        $dumpvars(0, tb_chain);

        // The chain has no reset, so flush the x out of it first.
        repeat (4) @(negedge clk);

        for (i = 0; i < 6; i = i + 1) begin
            d = pulse[i];
            @(negedge clk);
            $display("clock %0d: d=%b a=%b b=%b c=%b", i, d, a, b, c);
            if (a !== expected_a[i] || b !== expected_b[i] || c !== expected_c[i])
                errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
