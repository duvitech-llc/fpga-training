`timescale 1ns/1ps

module tb_seq_detect;

    reg  clk = 1'b0;
    reg  rst = 1'b1;
    reg  en  = 1'b0;
    reg  d   = 1'b0;
    wire match;

    reg     last_match = 1'b0;
    integer errors = 0;

    seq_detect dut (.clk(clk), .rst(rst), .en(en), .d(d), .match(match));

    always #5 clk = ~clk;

    // Call just after a falling edge, and each call takes one clock cycle.
    // match is a Moore output, so changing the inputs must not move it before
    // the rising edge. !== also catches a value that is still x or z.
    task step(input r, input e, input b, input expected_match);
        begin
            rst = r;
            en  = e;
            d   = b;
            #1;
            if (match !== last_match) begin
                $display("FAIL t=%0t rst=%b en=%b d=%b match=%b moved before the clock",
                         $time, r, e, b, match);
                errors = errors + 1;
            end
            @(negedge clk);
            if (match !== expected_match) begin
                $display("FAIL t=%0t rst=%b en=%b d=%b match=%b expected=%b",
                         $time, r, e, b, match, expected_match);
                errors = errors + 1;
            end
            last_match = match;
        end
    endtask

    // Sends the low n bits of pattern, leftmost bit first. Each bit of expected
    // is the value of match after the bit in the same position has been taken.
    task send(input integer n, input [15:0] pattern, input [15:0] expected);
        integer k;
        begin
            for (k = n - 1; k >= 0; k = k - 1)
                step(1'b0, 1'b1, pattern[k], expected[k]);
        end
    endtask

    initial begin
        $dumpfile("build/tb_seq_detect.vcd");
        $dumpvars(0, tb_seq_detect);

        @(negedge clk);

        //   rst   en    d     match
        step(1'b1, 1'b0, 1'b0, 1'b0);  // reset

        $display("-- separated patterns");
        send(8, 16'b1011_0000, 16'b0001_0000);
        send(8, 16'b1011_0000, 16'b0001_0000);

        $display("-- near misses");
        send(8, 16'b1001_0000, 16'b0000_0000);  // 100 is a dead end
        send(8, 16'b1010_0000, 16'b0000_0000);

        $display("-- patterns that overlap or restart");
        send(7, 16'b1011011, 16'b0001001);    // the last 1 of a match starts the next one
        send(4, 16'b0000, 16'b0000);
        send(8, 16'b1011_1011, 16'b0001_0001);  // one match straight after another
        send(4, 16'b0000, 16'b0000);
        send(5, 16'b11011, 16'b00001);          // 11 stays at 1, it does not start again
        send(4, 16'b0000, 16'b0000);
        send(6, 16'b101011, 16'b000001);     // 1010 falls back to 10, not idle
        send(4, 16'b0000, 16'b0000);

        $display("-- hold and reset");
        send(2, 16'b10, 16'b00);
        step(1'b0, 1'b0, 1'b0, 1'b0);  // en low ignores d in the middle of a pattern
        step(1'b0, 1'b0, 1'b1, 1'b0);
        send(2, 16'b11, 16'b01);
        step(1'b0, 1'b0, 1'b0, 1'b1);  // en low holds match
        step(1'b0, 1'b1, 1'b0, 1'b0);  // and the next bit taken clears it
        send(3, 16'b101, 16'b000);
        step(1'b1, 1'b1, 1'b1, 1'b0);  // rst beats en, and forgets the partial match
        send(3, 16'b011, 16'b000);
        send(4, 16'b1011, 16'b0001);
        step(1'b1, 1'b0, 1'b0, 1'b0);  // reset clears a match too

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
