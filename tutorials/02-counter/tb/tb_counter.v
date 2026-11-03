`timescale 1ns/1ps

module tb_counter;

    parameter MOD = 10;

    reg                    clk = 1'b0;
    reg                    rst = 1'b1;
    reg                    en  = 1'b0;
    wire [$clog2(MOD)-1:0] count;
    wire                   wrap;

    integer errors = 0;
    integer i;

    counter #(.MOD(MOD)) dut (.clk(clk), .rst(rst), .en(en), .count(count), .wrap(wrap));

    always #5 clk = ~clk;

    // Call just after a falling edge, and each call takes one clock cycle.
    // wrap is combinational, so it is checked before the rising edge. count is
    // checked after it. !== also catches a value that is still x or z.
    task step(input r, input e, input expected_wrap, input integer expected_count);
        begin
            rst = r;
            en  = e;
            #1;
            if (wrap !== expected_wrap) begin
                $display("FAIL t=%0t rst=%b en=%b wrap=%b expected=%b",
                         $time, r, e, wrap, expected_wrap);
                errors = errors + 1;
            end
            @(negedge clk);
            if (count !== expected_count[$clog2(MOD)-1:0]) begin
                $display("FAIL t=%0t rst=%b en=%b count=%0d expected=%0d",
                         $time, r, e, count, expected_count);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("build/tb_counter.vcd");
        $dumpvars(0, tb_counter);

        @(negedge clk);

        //   rst   en    wrap  expected count
        step(1'b1, 1'b0, 1'b0, 0);  // reset clears count

        // Two full cycles, so the count after a wrap is checked too.
        for (i = 1; i <= 2 * MOD; i = i + 1)
            step(1'b0, 1'b1, (i % MOD) == 0, i % MOD);

        step(1'b0, 1'b1, 1'b0, 1);  // en counts up
        step(1'b0, 1'b0, 1'b0, 1);  // en low holds count
        step(1'b1, 1'b1, 1'b0, 0);  // rst beats en

        for (i = 1; i < MOD; i = i + 1)
            step(1'b0, 1'b1, 1'b0, i);

        step(1'b0, 1'b0, 1'b0, MOD - 1);  // no wrap while holding the last value
        step(1'b1, 1'b1, 1'b0, 0);        // no wrap during reset
        step(1'b0, 1'b1, 1'b0, 1);        // counts again after reset

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
