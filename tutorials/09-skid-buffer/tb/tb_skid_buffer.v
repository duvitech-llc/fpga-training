`timescale 1ns/1ps

module tb_skid_buffer;

    parameter WIDTH = 8;

    localparam integer WORDS = 32;  // words in each full-speed burst
    localparam integer HOLD  = 8;   // clocks in the stall

    reg              clk     = 1'b0;
    reg              rst     = 1'b1;
    reg              s_valid = 1'b0;
    reg  [WIDTH-1:0] s_data  = 0;
    reg              m_ready = 1'b0;
    wire             s_ready;
    wire             m_valid;
    wire [WIDTH-1:0] m_data;

    reg  [WIDTH-1:0] next_in  = 0;  // the next word to offer
    reg  [WIDTH-1:0] next_out = 0;  // the next word expected out

    integer errors   = 0;
    integer sent     = 0;
    integer received = 0;
    integer clocks;
    integer start;
    integer in_before;
    integer out_before;
    integer i;
    real    rate;

    skid_buffer #(.WIDTH(WIDTH)) dut (
        .clk(clk), .rst(rst),
        .s_valid(s_valid), .s_ready(s_ready), .s_data(s_data),
        .m_valid(m_valid), .m_ready(m_ready), .m_data(m_data)
    );

    always #5 clk = ~clk;

    // A buffer that jams would otherwise leave the loops below waiting forever.
    initial begin
        #10000;
        $fatal(1, "FAIL: timed out");
    end

    task fail(input [8*64-1:0] what);
        begin
            $display("FAIL t=%0t %0s", $time, what);
            errors = errors + 1;
        end
    endtask

    // Call just after a falling edge, and each call takes one clock cycle. The
    // outputs are registered, so what is seen here is what the next rising edge
    // samples. Both sides of the transfer are scored here. !== also catches a
    // value that is still x or z.
    task step(input offer, input ready);
        begin
            s_valid = offer;
            s_data  = next_in;
            m_ready = ready;
            if (m_valid === 1'b1 && ready) begin
                if (m_data !== next_out) begin
                    $display("FAIL t=%0t m_data=%0d expected=%0d", $time, m_data, next_out);
                    errors = errors + 1;
                end
                next_out = next_out + 1'b1;
                received = received + 1;
            end
            if (offer && s_ready === 1'b1) begin
                next_in = next_in + 1'b1;
                sent    = sent + 1;
            end
            if (sent - received > 2)
                fail("more than two words inside");
            @(negedge clk);
        end
    endtask

    // Offers words with m_ready high until count more have arrived.
    task burst(input integer count);
        begin
            start  = received;
            clocks = 0;
            while (received < start + count) begin
                step(1'b1, 1'b1);
                if (received > start)
                    clocks = clocks + 1;
            end
            rate = 1.0 * count / clocks;
            $display("  %0d words in %0d clocks: %0.2f words per clock", count, clocks, rate);
            if (clocks != count)
                fail("the burst had a gap");
        end
    endtask

    // Stops offering and collects whatever is still inside.
    task drain;
        begin
            while (m_valid === 1'b1)
                step(1'b0, 1'b1);
            if (sent != received)
                fail("words went missing");
        end
    endtask

    task reset;
        begin
            rst = 1'b1;
            @(negedge clk);
            next_out = next_in;  // reset discards whatever was inside
            sent     = 0;
            received = 0;
            rst      = 1'b0;
            if (m_valid !== 1'b0 || s_ready !== 1'b0)
                fail("reset did not clear the outputs");
            step(1'b0, 1'b0);
        end
    endtask

    initial begin
        $dumpfile("build/tb_skid_buffer.vcd");
        $dumpvars(0, tb_skid_buffer);

        @(negedge clk);
        reset;
        if (s_ready !== 1'b1)
            fail("not ready after reset");

        // m_ready held high: every clock moves a word.
        $display("m_ready held high:");
        burst(WORDS);
        drain;
        if (m_valid !== 1'b0)
            fail("m_valid stayed high with nothing inside");

        // A long stall. m_ready goes low before any word arrives, so the first
        // word fills the output register and the second fills the skid register.
        $display("stalled for %0d clocks:", HOLD);
        in_before  = sent;
        out_before = received;
        step(1'b1, 1'b0);
        step(1'b1, 1'b0);
        if (sent != received + 2)
            fail("two words should be inside");
        if (s_ready !== 1'b0)
            fail("s_ready should fall when both registers are full");

        start = sent;
        for (i = 0; i < HOLD; i = i + 1) begin
            if (m_valid !== 1'b1 || m_data !== next_out)
                fail("the stalled word did not hold still");
            if (s_ready !== 1'b0)
                fail("s_ready rose during the stall");
            step(1'b1, 1'b0);
        end
        $display("  %0d words accepted, %0d delivered, m_data held at %0d",
                 sent - in_before, received - out_before, m_data);
        if (sent != start)
            fail("a word was accepted during the stall");

        // The stall ends, and the output must not pause: the skid word follows
        // straight on, while the input takes one clock to reopen.
        $display("after the stall:");
        burst(WORDS);
        drain;

        // Reset with both registers full must discard both words.
        step(1'b1, 1'b0);
        step(1'b1, 1'b0);
        reset;
        if (m_valid !== 1'b0 || s_ready !== 1'b1)
            fail("words survived a reset");
        for (i = 0; i < 4; i = i + 1)
            step(1'b0, 1'b1);
        if (received != 0)
            fail("a discarded word came out after reset");

        // Still working.
        burst(4);
        drain;

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
