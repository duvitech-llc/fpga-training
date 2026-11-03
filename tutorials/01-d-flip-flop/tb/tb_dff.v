`timescale 1ns/1ps

module tb_dff;

    reg  clk = 1'b0;
    reg  rst = 1'b1;
    reg  en  = 1'b0;
    reg  d   = 1'b0;
    wire q;

    integer errors = 0;

    dff dut (.clk(clk), .rst(rst), .en(en), .d(d), .q(q));

    always #5 clk = ~clk;

    // Inputs change on the falling edge so they are stable at the rising edge.
    // !== also catches a q that is still x or z.
    task step(input r, input e, input data, input expected);
        begin
            @(negedge clk);
            rst = r;
            en  = e;
            d   = data;
            @(negedge clk);
            if (q !== expected) begin
                $display("FAIL t=%0t rst=%b en=%b d=%b q=%b expected=%b",
                         $time, r, e, data, q, expected);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("build/tb_dff.vcd");
        $dumpvars(0, tb_dff);

        //   rst   en    d     expected q
        step(1'b1, 1'b0, 1'b0, 1'b0);  // reset clears q
        step(1'b0, 1'b1, 1'b1, 1'b1);  // en loads d
        step(1'b0, 1'b1, 1'b0, 1'b0);
        step(1'b0, 1'b1, 1'b1, 1'b1);
        step(1'b0, 1'b0, 1'b0, 1'b1);  // en low holds q
        step(1'b0, 1'b0, 1'b1, 1'b1);
        step(1'b1, 1'b1, 1'b1, 1'b0);  // rst beats en
        step(1'b0, 1'b0, 1'b1, 1'b0);  // hold after reset

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
