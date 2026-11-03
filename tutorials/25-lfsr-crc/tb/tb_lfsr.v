`timescale 1ns/1ps

// Measures the period of each LFSR: how many clocks until the state comes back.
// The expected numbers come from the theory in the README, not from the design.
module tb_lfsr;

    reg         clk = 1'b0;
    reg         rst = 1'b1;
    reg         en = 1'b0;
    reg         load = 1'b0;
    reg  [15:0] load16 = 16'd0;
    reg  [3:0]  load4 = 4'd0;

    // Three 4-bit polynomials, each built both ways.
    //   0: x^4 + x + 1                  primitive, so maximal: period 15
    //   1: x^4 + x^3 + x^2 + x + 1      irreducible but not primitive: period 5
    //   2: x^4 + x^2 + 1                (x^2 + x + 1) squared: periods 3 and 6
    localparam [11:0] POLYS = {4'b0101, 4'b1111, 4'b0011};

    wire [15:0] fib16_q;
    wire [15:0] gal16_q;
    wire [3:0]  fib4_q [0:2];
    wire [3:0]  gal4_q [0:2];

    integer errors = 0;
    integer i;
    integer p;
    integer n;
    integer fib_period;
    integer gal_period;
    integer fib_periods [1:15];
    integer gal_periods [1:15];

    lfsr_fib #(.WIDTH(16), .POLY(16'h6801)) fib16 (
        .clk(clk), .rst(rst), .en(en), .load(load), .load_value(load16),
        .q(fib16_q), .out()
    );

    lfsr_galois #(.WIDTH(16), .POLY(16'h6801)) gal16 (
        .clk(clk), .rst(rst), .en(en), .load(load), .load_value(load16),
        .q(gal16_q), .out()
    );

    genvar g;
    generate
        for (g = 0; g < 3; g = g + 1) begin : four_bit
            lfsr_fib #(.WIDTH(4), .POLY(POLYS[4*g +: 4])) fib (
                .clk(clk), .rst(rst), .en(en), .load(load), .load_value(load4),
                .q(fib4_q[g]), .out()
            );
            lfsr_galois #(.WIDTH(4), .POLY(POLYS[4*g +: 4])) gal (
                .clk(clk), .rst(rst), .en(en), .load(load), .load_value(load4),
                .q(gal4_q[g]), .out()
            );
        end
    endgenerate

    always #5 clk = ~clk;

    // Load a seed into every LFSR. Call just after a falling edge.
    task load_seed(input [15:0] seed16, input [3:0] seed4);
        begin
            load   = 1'b1;
            en     = 1'b0;
            load16 = seed16;
            load4  = seed4;
            @(negedge clk);
            load   = 1'b0;
            en     = 1'b1;
        end
    endtask

    // Run the 16-bit pair from seed 1 until both come back to it.
    task measure16;
        begin
            load_seed(16'd1, 4'd1);
            fib_period = 0;
            gal_period = 0;
            n = 0;
            while ((fib_period == 0 || gal_period == 0) && n < 70000) begin
                @(negedge clk);
                n = n + 1;
                if (fib16_q === 16'd0 || gal16_q === 16'd0) begin
                    $display("FAIL t=%0t a 16-bit LFSR reached 0", $time);
                    errors = errors + 1;
                end
                if (fib_period == 0 && fib16_q === 16'd1)
                    fib_period = n;
                if (gal_period == 0 && gal16_q === 16'd1)
                    gal_period = n;
            end
        end
    endtask

    // Run 4-bit LFSR number p from seed until both forms come back to it.
    task measure4(input integer which, input [3:0] seed);
        begin
            load_seed(16'd1, seed);
            fib_period = 0;
            gal_period = 0;
            n = 0;
            while ((fib_period == 0 || gal_period == 0) && n < 20) begin
                @(negedge clk);
                n = n + 1;
                if (fib_period == 0 && fib4_q[which] === seed)
                    fib_period = n;
                if (gal_period == 0 && gal4_q[which] === seed)
                    gal_period = n;
            end
        end
    endtask

    task expect_period(input integer got, input integer want, input [8*8-1:0] form);
        begin
            if (got !== want) begin
                $display("FAIL %0s period=%0d expected=%0d", form, got, want);
                errors = errors + 1;
            end
        end
    endtask

    // x^4 + x + 1 gives 15 for every seed, and x^4 + x^3 + x^2 + x + 1 gives 5.
    // x^2 + x + 1 divides x^4 + x^2 + 1, and its 3 nonzero states have
    // period 3. The other 12 have period 6.
    task check_periods(input integer which, input galois, input [8*8-1:0] form);
        integer k;
        integer got;
        integer count3;
        integer count6;
        begin
            count3 = 0;
            count6 = 0;
            for (k = 1; k < 16; k = k + 1) begin
                got = galois ? gal_periods[k] : fib_periods[k];
                if (got == 3) count3 = count3 + 1;
                if (got == 6) count6 = count6 + 1;
                if (which == 0) expect_period(got, 15, form);
                if (which == 1) expect_period(got, 5, form);
            end
            if (which == 2 && (count3 != 3 || count6 != 12)) begin
                $display("FAIL %0s x^4 + x^2 + 1: %0d seeds of period 3 and %0d of period 6",
                         form, count3, count6);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("build/tb_lfsr.vcd");
        $dumpvars(0, tb_lfsr);

        @(negedge clk);
        rst = 1'b0;

        // Reset loads SEED, which is 1.
        if (fib16_q !== 16'd1 || gal16_q !== 16'd1) begin
            $display("FAIL reset gave fib=%h galois=%h", fib16_q, gal16_q);
            errors = errors + 1;
        end

        // Every nonzero seed of each 4-bit polynomial, in both forms. The two
        // forms hold different states, so one seed can start different cycles.
        for (p = 0; p < 3; p = p + 1) begin
            for (i = 1; i < 16; i = i + 1) begin
                measure4(p, i[3:0]);
                fib_periods[i] = fib_period;
                gal_periods[i] = gal_period;
            end
            $write("POLY=%b fibonacci periods for seeds 1 to 15:", POLYS[4*p +: 4]);
            for (i = 1; i < 16; i = i + 1)
                $write(" %0d", fib_periods[i]);
            $display("");
            $write("POLY=%b galois    periods for seeds 1 to 15:", POLYS[4*p +: 4]);
            for (i = 1; i < 16; i = i + 1)
                $write(" %0d", gal_periods[i]);
            $display("");
            check_periods(p, 1'b0, "fib4");
            check_periods(p, 1'b1, "galois4");
        end

        // All zeros: no tap has a 1 to feed back, so the state never leaves 0.
        load_seed(16'd0, 4'd0);
        repeat (100) @(negedge clk);
        if (fib16_q !== 16'd0 || gal16_q !== 16'd0 || fib4_q[0] !== 4'd0 || gal4_q[0] !== 4'd0) begin
            $display("FAIL all zeros did not stay at 0");
            errors = errors + 1;
        end else begin
            $display("loaded 0: still 0 after 100 clocks");
        end

        // The long run is left out of the waveform, which would be large.
        $dumpoff;
        measure16;
        $display("x^16 + x^14 + x^13 + x^11 + 1: fibonacci period %0d, galois period %0d",
                 fib_period, gal_period);
        expect_period(fib_period, 65535, "fib16");
        expect_period(gal_period, 65535, "galois16");

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
