`timescale 1ps/1ps

module tb_cdc;

    localparam integer SKEW = 200;      // ps between two flops' reset arrivals

    reg  clk_a   = 1'b0;
    reg  clk_b   = 1'b0;
    reg  arst    = 1'b0;
    reg  a_level = 1'b0;
    reg  a_pulse = 1'b0;
    wire rst_a;
    wire rst_b;
    wire b_level;
    wire b_pulse;
    wire b_naive;

    // Half periods in ps. They share no common factor, so the clocks drift past
    // each other.
    integer a_half = 5003;
    integer b_half = 3137;

    integer errors = 0;
    integer rand_state = 1;
    integer sent = 0;           // pulses driven, used only by the clk_a process
    integer got_toggle = 0;     // pulses seen, written only on clk_b
    integer got_naive = 0;
    integer level_changes = 0;
    integer total_lost = 0;
    integer spacing;
    integer min_gap;
    integer edges;
    integer i;

    cdc_top dut (
        .clk_a(clk_a), .clk_b(clk_b), .arst(arst), .a_level(a_level), .a_pulse(a_pulse),
        .rst_a(rst_a), .rst_b(rst_b),
        .b_level(b_level), .b_pulse(b_pulse), .b_naive(b_naive)
    );

    always #a_half clk_a = ~clk_a;
    always #b_half clk_b = ~clk_b;

    // Inputs are driven with <= on the falling edge of clk_a. A rising edge of
    // clk_b can land at the same instant, and <= means that edge always gets the
    // old value, whichever process the simulator runs first.

    // A pulse is counted the way logic in domain b would count it.
    always @(posedge clk_b) begin
        if (b_pulse === 1'b1)
            got_toggle <= got_toggle + 1;
        if (b_naive === 1'b1)
            got_naive <= got_naive + 1;
    end

    // b_level must be a_level from exactly two rising edges of clk_b ago.
    reg level_1 = 1'b0;
    reg level_2 = 1'b0;

    always @(posedge clk_b) begin
        level_1 <= rst_b ? 1'b0 : a_level;
        level_2 <= rst_b ? 1'b0 : level_1;
    end

    always @(negedge clk_b) begin
        if (rst_b === 1'b0 && b_level !== level_2) begin
            $display("FAIL t=%0t b_level=%b expected=%b", $time, b_level, level_2);
            errors = errors + 1;
        end
    end

    function integer next_rand(input integer state);
        next_rand = state * 1103515245 + 12345;
    endfunction

    function integer rand_below(input integer limit);
        begin
            rand_state = next_rand(rand_state);
            rand_below = ((rand_state >> 16) & 32'h7fff) % limit;
        end
    endfunction

    // Long enough for anything on its way to arrive.
    task settle;
        begin
            repeat (6) @(negedge clk_b);
            repeat (6) @(negedge clk_a);
            repeat (6) @(negedge clk_b);
            @(negedge clk_a);
        end
    endtask

    // A long reset: both clocks rise several times while arst is high.
    task reset_long;
        begin
            arst = 1'b1;
            repeat (3) @(negedge clk_a);
            repeat (3) @(negedge clk_b);
            @(negedge clk_a);
            arst <= 1'b0;
            settle;
        end
    endtask

    // Rising edges of each clock, after arst falls, until that domain's reset
    // falls. Call with arst already low.
    task count_release(input integer expected);
        integer a_edges;
        integer b_edges;
        begin
            a_edges = 0;
            b_edges = 0;
            fork
                while (rst_a === 1'b1) begin
                    @(posedge clk_a);
                    #1;
                    a_edges = a_edges + 1;
                end
                while (rst_b === 1'b1) begin
                    @(posedge clk_b);
                    #1;
                    b_edges = b_edges + 1;
                end
            join
            $display("reset released after %0d clk_a edges and %0d clk_b edges", a_edges, b_edges);
            if (a_edges !== expected || b_edges !== expected) begin
                $display("FAIL t=%0t expected %0d edges in each domain", $time, expected);
                errors = errors + 1;
            end
        end
    endtask

    // Call just after a falling edge of clk_a. Takes gap clocks of clk_a. At a gap
    // of 1, a_pulse stays high, and the caller must lower it afterwards.
    task send(input integer gap);
        begin
            a_pulse <= 1'b1;
            sent = sent + 1;
            @(negedge clk_a);
            if (gap > 1) begin
                a_pulse <= 1'b0;
                repeat (gap - 1) @(negedge clk_a);
            end
        end
    endtask

    // Clocks of clk_a in two periods of clk_b, rounded up, and at least 2 so
    // that a_pulse has a low cycle between pulses.
    function integer documented_gap(input integer a_h, input integer b_h);
        begin
            documented_gap = (2 * b_h + a_h - 1) / a_h;
            if (documented_gap < 2)
                documented_gap = 2;
        end
    endfunction

    // One clock ratio: levels first, then pulses at the documented spacing.
    task run(input integer a_h, input integer b_h);
        integer before_toggle;
        integer before_naive;
        integer before_sent;
        begin
            a_half = a_h;
            b_half = b_h;
            reset_long;
            before_toggle = got_toggle;
            before_naive  = got_naive;
            before_sent   = sent;

            // Levels of random length. The checker above runs all the time.
            repeat (200) begin
                a_level <= ~a_level;
                level_changes = level_changes + 1;
                repeat (1 + rand_below(4 * b_h / a_h + 4)) @(negedge clk_a);
            end
            settle;
            if (b_level !== a_level) begin
                $display("FAIL t=%0t b_level=%b settled away from a_level=%b",
                         $time, b_level, a_level);
                errors = errors + 1;
            end

            min_gap = documented_gap(a_h, b_h);
            repeat (200)
                send(min_gap + rand_below(3));
            settle;

            $display("half periods %0d and %0d ps, gap %0d: sent %0d, pulse_sync %0d, naive %0d",
                     a_h, b_h, min_gap, sent - before_sent,
                     got_toggle - before_toggle, got_naive - before_naive);
            if (got_toggle - before_toggle !== sent - before_sent) begin
                $display("FAIL pulse_sync lost pulses above the documented spacing");
                errors = errors + 1;
            end
            total_lost = total_lost + (sent - before_sent) - (got_naive - before_naive);
        end
    endtask

    // A fixed spacing, to find where pulses start to vanish.
    task sweep(input integer gap);
        integer before_toggle;
        integer before_sent;
        integer lost;
        begin
            before_toggle = got_toggle;
            before_sent   = sent;
            repeat (100)
                send(gap);
            a_pulse <= 1'b0;
            settle;
            lost = (sent - before_sent) - (got_toggle - before_toggle);
            $display("gap %2d clk_a clocks: sent %0d, lost %0d", gap, sent - before_sent, lost);
            if (2 * gap * a_half >= 2 * b_half && lost != 0) begin
                $display("FAIL pulses lost at a gap of at least one clk_b period");
                errors = errors + 1;
            end
            if (gap == 1 && lost == 0) begin
                $display("FAIL the sweep never lost a pulse");
                errors = errors + 1;
            end
        end
    endtask

    // Two flops of a one-hot ring whose reset reaches them at different times,
    // as a reset net does on a real device. Bit 1 sees it first.
    reg        ring_raw   = 1'b0;   // released by hand, at any moment
    reg        ring_arst  = 1'b0;   // the same thing, through reset_sync
    reg        ring_safe  = 1'b0;   // chooses which one drives the ring
    wire       ring_sync;
    wire       ring_early = ring_safe ? ring_sync : ring_raw;
    wire       ring_late;
    reg        ring_0;
    reg        ring_1;
    wire [1:0] ring = {ring_1, ring_0};

    reset_sync ring_reset (.clk(clk_a), .arst(ring_arst), .rst(ring_sync));

    assign #SKEW ring_late = ring_early;

    always @(posedge clk_a or posedge ring_early) begin
        if (ring_early)
            ring_1 <= 1'b0;
        else
            ring_1 <= ring_0;
    end

    always @(posedge clk_a or posedge ring_late) begin
        if (ring_late)
            ring_0 <= 1'b1;
        else
            ring_0 <= ring_1;
    end

    initial begin
        $dumpfile("build/tb_cdc.vcd");
        $dumpvars(0, tb_cdc);

        // Power-up. arst rises, and rst follows with no clock edge at all.
        #1;
        arst = 1'b1;
        #1;
        if (rst_a !== 1'b1 || rst_b !== 1'b1) begin
            $display("FAIL rst_a=%b rst_b=%b before any clock edge", rst_a, rst_b);
            errors = errors + 1;
        end
        repeat (3) @(negedge clk_a);
        repeat (3) @(negedge clk_b);
        @(negedge clk_a);

        // Release: each domain leaves on its own second edge.
        arst <= 1'b0;
        #1;
        count_release(2);
        settle;

        // Assert halfway between rising edges of clk_a. rst must rise at once.
        @(negedge clk_a);
        arst = 1'b1;
        #1;
        if (rst_a !== 1'b1 || rst_b !== 1'b1) begin
            $display("FAIL t=%0t rst_a=%b rst_b=%b, assertion waited for a clock",
                     $time, rst_a, rst_b);
            errors = errors + 1;
        end

        // A glitch much shorter than a clock still gives a full reset.
        #100;
        arst = 1'b0;
        #1;
        if (rst_a !== 1'b1 || rst_b !== 1'b1) begin
            $display("FAIL t=%0t a short arst did not hold the resets", $time);
            errors = errors + 1;
        end
        count_release(2);
        settle;

        //  a half  b half
        run(   1009,   7001);  // clk_a about 7 times faster
        run(   3137,   5003);  // clk_a about 1.6 times faster
        run(   5003,   5021);  // nearly equal, so the edges slide past
        run(   5003,   3137);  // clk_b about 1.6 times faster
        run(   7001,   1009);  // clk_b about 7 times faster
        $display("%0d level changes, the naive crossing lost %0d pulses",
                 level_changes, total_lost);
        if (total_lost == 0) begin
            $display("FAIL the naive crossing never lost a pulse");
            errors = errors + 1;
        end

        // Where the limit really is, for ideal flops.
        a_half = 1009;
        b_half = 7001;
        reset_long;
        for (spacing = 1; spacing <= 16; spacing = spacing + 1)
            sweep(spacing);

        // Reset fan-out. The toggle is left high by an odd number of pulses, then
        // arst is too short for slow clk_a to reach an edge. Domain b leaves
        // reset and sees a toggle that clk_a has not cleared yet.
        a_half = 7001;
        b_half = 1009;
        reset_long;
        send(4);
        settle;
        edges = got_toggle;
        @(negedge clk_a);
        arst = 1'b1;
        #100;
        arst = 1'b0;
        settle;
        $display("short reset, toggle high: %0d phantom pulses", got_toggle - edges);
        if (got_toggle == edges) begin
            $display("FAIL expected a short reset to make a phantom pulse");
            errors = errors + 1;
        end

        // The same with a long reset, which covers an edge of each clock.
        send(4);
        settle;
        edges = got_toggle;
        reset_long;
        $display("long reset, toggle high: %0d phantom pulses", got_toggle - edges);
        if (got_toggle != edges) begin
            $display("FAIL a long reset made a phantom pulse");
            errors = errors + 1;
        end

        // Release a reset with skew, just before a rising edge. The two ring
        // flops leave reset on either side of that edge.
        a_half = 5003;
        ring_raw = 1'b1;
        repeat (2) @(negedge clk_a);
        #(a_half - SKEW / 2);
        ring_raw = 1'b0;
        repeat (2) @(negedge clk_a);
        $display("raw release: ring=%b", ring);
        if (ring !== 2'b11) begin
            $display("FAIL expected the raw release to reach the illegal state 11");
            errors = errors + 1;
        end

        // The same skew and the same moment, through reset_sync. The release now
        // comes just after an edge, so both flops have left before the next one.
        ring_arst = 1'b1;
        ring_safe = 1'b1;
        repeat (2) @(negedge clk_a);
        #(a_half - SKEW / 2);
        ring_arst = 1'b0;
        repeat (3) @(negedge clk_a);
        for (i = 0; i < 8; i = i + 1) begin
            @(negedge clk_a);
            if (ring !== 2'b01 && ring !== 2'b10) begin
                $display("FAIL t=%0t ring=%b after a synchronized release", $time, ring);
                errors = errors + 1;
            end
        end
        $display("synchronized release: ring=%b, one bit set for 8 clocks", ring);

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

    initial begin
        #2000000000;
        $fatal(1, "FAIL: timed out");
    end

endmodule
