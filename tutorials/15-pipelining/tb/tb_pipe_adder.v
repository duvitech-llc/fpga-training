`timescale 1ns/1ps

module tb_pipe_adder;

    parameter WIDTH  = 32;      // up to 64, since operands are cut from 64 random bits
    parameter STAGES = 2;
    parameter SIMPLE = 0;       // 1 runs only the weak test from the exercises

    localparam integer BURST = 200;

    reg              clk      = 1'b0;
    reg              rst      = 1'b1;
    reg              in_valid = 1'b0;
    reg  [WIDTH-1:0] a        = 0;
    reg  [WIDTH-1:0] b        = 0;
    wire             out_valid;
    wire [WIDTH-1:0] sum;
    wire             carry;

    // The expected results, delayed by the known latency.
    reg             exp_valid [0:STAGES-1];
    reg [WIDTH:0]   exp_total [0:STAGES-1];

    reg [63:0] rand_a;
    reg [63:0] rand_b;

    integer errors      = 0;
    integer clock_count = 0;
    integer results     = 0;    // results seen since the last clear_counts
    integer first_clock = 0;    // clock of the first of them
    integer last_clock  = 0;    // clock of the last of them
    integer waited;
    integer i;

    pipe_adder #(.WIDTH(WIDTH), .STAGES(STAGES)) dut (
        .clk(clk), .rst(rst), .in_valid(in_valid), .a(a), .b(b),
        .out_valid(out_valid), .sum(sum), .carry(carry)
    );

    always #5 clk = ~clk;

    // Call just after a falling edge, and each call takes one clock cycle.
    // !== also catches a value that is still x or z.
    task step(input r, input v, input [WIDTH-1:0] x, input [WIDTH-1:0] y);
        integer k;
        begin
            rst      = r;
            in_valid = v;
            a        = x;
            b        = y;

            for (k = STAGES - 1; k > 0; k = k - 1) begin
                exp_valid[k] = exp_valid[k-1] && !r;
                exp_total[k] = exp_total[k-1];
            end
            exp_valid[0] = v && !r;
            exp_total[0] = {1'b0, x} + {1'b0, y};

            @(negedge clk);
            clock_count = clock_count + 1;

            if (out_valid !== exp_valid[STAGES-1]) begin
                $display("FAIL t=%0t out_valid=%b expected=%b",
                         $time, out_valid, exp_valid[STAGES-1]);
                errors = errors + 1;
            end
            if (exp_valid[STAGES-1] && {carry, sum} !== exp_total[STAGES-1]) begin
                $display("FAIL t=%0t carry,sum=%h expected=%h",
                         $time, {carry, sum}, exp_total[STAGES-1]);
                errors = errors + 1;
            end

            if (out_valid === 1'b1) begin
                if (results == 0)
                    first_clock = clock_count;
                last_clock = clock_count;
                results    = results + 1;
            end
        end
    endtask

    // New random operands every clock, even when v is low. A bubble must not
    // disturb the real adds around it.
    task random_step(input v);
        begin
            rand_a = {$random, $random};
            rand_b = {$random, $random};
            step(1'b0, v, rand_a[WIDTH-1:0], rand_b[WIDTH-1:0]);
        end
    endtask

    task drain;
        begin
            repeat (STAGES + 1) random_step(1'b0);
        end
    endtask

    task report_rate(input [8*8-1:0] name);
        begin
            $display("%0s: %0d results in %0d clocks",
                     name, results, last_clock - first_clock + 1);
        end
    endtask

    initial begin
        $dumpfile("build/tb_pipe_adder.vcd");
        $dumpvars(0, tb_pipe_adder);

        for (i = 0; i < STAGES; i = i + 1) begin
            exp_valid[i] = 1'b0;
            exp_total[i] = 0;
        end

        @(negedge clk);
        step(1'b1, 1'b0, 0, 0);

        if (SIMPLE != 0) begin
            // A weak test. b never changes, and a is too small for its upper
            // bits to change. Delayed or not, the upper bits look the same.
            for (i = 0; i < BURST; i = i + 1)
                step(1'b0, 1'b1, i[WIDTH-1:0], 1);
            repeat (STAGES) step(1'b0, 1'b0, 0, 1);
        end else begin
            // Carries that cross every stage boundary.
            step(1'b0, 1'b1, {WIDTH{1'b1}}, 1);
            step(1'b0, 1'b1, 1, {WIDTH{1'b1}});
            step(1'b0, 1'b1, {WIDTH{1'b1}}, {WIDTH{1'b1}});
            step(1'b0, 1'b1, 0, 0);
            step(1'b0, 1'b1, {WIDTH{1'b1}}, 0);
            drain;
            results = 0;

            // Latency: one add alone, then count clocks until its result.
            random_step(1'b1);
            waited = 1;
            while (out_valid !== 1'b1 && waited < STAGES + 5) begin
                random_step(1'b0);
                waited = waited + 1;
            end
            $display("latency: %0d clocks", waited);
            if (waited != STAGES) begin
                $display("FAIL latency %0d expected %0d", waited, STAGES);
                errors = errors + 1;
            end
            drain;
            results = 0;

            // Throughput: an add on every clock.
            for (i = 0; i < BURST; i = i + 1)
                random_step(1'b1);
            drain;
            report_rate("full");
            if (results != BURST || last_clock - first_clock + 1 != BURST) begin
                $display("FAIL full rate");
                errors = errors + 1;
            end
            results = 0;

            // Gaps: two adds, then a bubble.
            for (i = 0; i < BURST; i = i + 1)
                random_step(i % 3 != 2);
            drain;
            report_rate("gapped");
            if (results != BURST - BURST / 3) begin
                $display("FAIL gapped rate");
                errors = errors + 1;
            end
            results = 0;

            // A reset drops everything in flight, and an add during reset is ignored.
            repeat (STAGES) random_step(1'b1);
            rand_a = {$random, $random};
            step(1'b1, 1'b1, rand_a[WIDTH-1:0], 1);
            drain;
            results = 0;

            // Everything still works afterwards.
            for (i = 0; i < BURST; i = i + 1)
                random_step(($random & 3) != 0);
            drain;
        end

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
