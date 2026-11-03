`timescale 1ns/1ps

module tb_shift_reg;

    parameter WIDTH = 8;

    reg              clk = 1'b0;
    reg              rst = 1'b1;
    reg              load = 1'b0;
    reg              en = 1'b0;
    reg  [WIDTH-1:0] parallel_in = {WIDTH{1'b0}};
    reg              serial_in = 1'b0;
    wire             serial_out;
    wire [WIDTH-1:0] q;
    wire [WIDTH-1:0] rx_q;

    reg  [WIDTH-1:0] pattern;
    reg  [WIDTH-1:0] expected;

    integer errors = 0;
    integer i;

    shift_reg #(.WIDTH(WIDTH)) dut (
        .clk(clk), .rst(rst), .load(load), .en(en), .parallel_in(parallel_in),
        .serial_in(serial_in), .serial_out(serial_out), .q(q)
    );

    // A second shift register on the far end of a one-wire link.
    shift_reg #(.WIDTH(WIDTH)) rx (
        .clk(clk), .rst(rst), .load(1'b0), .en(en), .parallel_in({WIDTH{1'b0}}),
        .serial_in(serial_out), .serial_out(), .q(rx_q)
    );

    always #5 clk = ~clk;

    // Call just after a falling edge, and each call takes one clock cycle.
    // The result stays in expected. !== also catches a value that is still x or z.
    task step(input r, input l, input e, input s, input [WIDTH-1:0] p,
              input [WIDTH-1:0] next);
        begin
            rst         = r;
            load        = l;
            en          = e;
            serial_in   = s;
            parallel_in = p;
            expected    = next;
            @(negedge clk);
            if (q !== expected) begin
                $display("FAIL t=%0t rst=%b load=%b en=%b q=%b expected=%b",
                         $time, r, l, e, q, expected);
                errors = errors + 1;
            end
            if (serial_out !== expected[WIDTH-1]) begin
                $display("FAIL t=%0t serial_out=%b expected=%b",
                         $time, serial_out, expected[WIDTH-1]);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("build/tb_shift_reg.vcd");
        $dumpvars(0, tb_shift_reg);

        // Not symmetrical, so a reversed bit order cannot pass by luck.
        for (i = 0; i < WIDTH; i = i + 1)
            pattern[i] = (i % 3) == 0;

        @(negedge clk);

        //   rst   load  en    ser   parallel  expected q
        step(1'b1, 1'b0, 1'b0, 1'b0, pattern,  {WIDTH{1'b0}});  // reset clears q
        step(1'b0, 1'b1, 1'b0, 1'b1, pattern,  pattern);        // load copies parallel_in

        // Send pattern to rx, MSB first, while shifting its opposite into q.
        for (i = WIDTH - 1; i >= 0; i = i - 1)
            step(1'b0, 1'b0, 1'b1, !pattern[i], ~pattern,
                 {expected[WIDTH-2:0], !pattern[i]});

        if (rx_q !== pattern) begin
            $display("FAIL t=%0t rx_q=%b expected=%b", $time, rx_q, pattern);
            errors = errors + 1;
        end

        step(1'b0, 1'b0, 1'b0, 1'b1, pattern,  expected);       // en low holds q
        step(1'b0, 1'b1, 1'b1, 1'b1, pattern,  pattern);        // load beats en
        step(1'b0, 1'b1, 1'b1, 1'b0, ~pattern, ~pattern);       // load beats en, other bits
        step(1'b1, 1'b1, 1'b1, 1'b1, pattern,  {WIDTH{1'b0}});  // rst beats load and en
        step(1'b0, 1'b1, 1'b0, 1'b0, pattern,  pattern);        // load works after reset
        step(1'b1, 1'b0, 1'b1, 1'b1, pattern,  {WIDTH{1'b0}});  // rst beats en
        step(1'b0, 1'b0, 1'b1, 1'b1, pattern,
             {expected[WIDTH-2:0], 1'b1});                      // shifts after reset

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
