`timescale 1ns/1ps

module tb_uart;

    parameter CLKS_PER_BIT = 16;

    reg        clk = 1'b0;
    reg        rst = 1'b1;
    reg        tx_valid = 1'b0;
    reg  [7:0] tx_data = 8'd0;
    wire       tx_ready;
    wire       tx;
    wire       rx_valid;
    wire [7:0] rx_data;
    wire       rx_error;

    // The receiver listens to the transmitter, or to rx_drive when loop is low.
    reg  loop     = 1'b1;
    reg  rx_drive = 1'b1;
    wire line     = loop ? tx : rx_drive;

    integer errors = 0;
    integer i;

    uart #(.CLKS_PER_BIT(CLKS_PER_BIT)) dut (
        .clk(clk), .rst(rst),
        .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready), .tx(tx),
        .rx(line), .rx_valid(rx_valid), .rx_data(rx_data), .rx_error(rx_error)
    );

    always #5 clk = ~clk;

    // Bytes on their way to the receiver, in order, and the results so far.
    reg [7:0] pending [0:1023];
    integer   head = 0;
    integer   tail = 0;
    integer   framing_errors = 0;

    always @(negedge clk) begin
        if (rx_valid === 1'b1) begin
            if (head == tail || rx_data !== pending[head]) begin
                $display("FAIL t=%0t rx_data=%h expected=%h pending=%0d",
                         $time, rx_data, pending[head], tail - head);
                errors = errors + 1;
            end
            head = head + 1;
        end
        if (rx_error === 1'b1)
            framing_errors = framing_errors + 1;
    end

    task expect_quiet(input integer expected_framing_errors);
        begin
            if (head != tail || framing_errors != expected_framing_errors) begin
                $display("FAIL t=%0t pending=%0d framing_errors=%0d expected=%0d",
                         $time, tail - head, framing_errors, expected_framing_errors);
                errors = errors + 1;
            end
        end
    endtask

    // Like send_tx, but the next byte is offered as soon as this one has been
    // taken, so it waits through a whole frame with tx_valid high. The frame on
    // the line must not change, and tx_ready must stay low until it ends.
    task send_tx_then_offer(input [7:0] data, input [7:0] next);
        reg [9:0] frame;
        integer   b, c;
        begin
            frame    = {1'b1, data, 1'b0};
            tx_valid = 1'b1;
            tx_data  = data;
            #1;
            while (tx_ready !== 1'b1)
                @(negedge clk);
            pending[tail] = data;
            tail = tail + 1;
            @(negedge clk);
            tx_data = next;
            for (b = 0; b < 10; b = b + 1) begin
                for (c = 0; c < CLKS_PER_BIT; c = c + 1) begin
                    if (tx !== frame[b] || tx_ready !== 1'b0) begin
                        $display("FAIL t=%0t busy, bit %0d clock %0d tx=%b tx_ready=%b expected tx=%b",
                                 $time, b, c, tx, tx_ready, frame[b]);
                        errors = errors + 1;
                    end
                    @(negedge clk);
                end
            end
        end
    endtask

    // Call just after a falling edge. Sends one byte through the transmitter and
    // checks the line on every clock of the frame, so the bit order and the
    // length of each bit are tested as well as the loopback.
    task send_tx(input [7:0] data);
        reg [9:0] frame;
        integer   b, c;
        begin
            frame    = {1'b1, data, 1'b0};
            tx_valid = 1'b1;
            tx_data  = data;
            #1;
            while (tx_ready !== 1'b1)
                @(negedge clk);
            pending[tail] = data;
            tail = tail + 1;
            @(negedge clk);
            // The transmitter has its own copy now.
            tx_valid = 1'b0;
            tx_data  = ~data;
            for (b = 0; b < 10; b = b + 1) begin
                for (c = 0; c < CLKS_PER_BIT; c = c + 1) begin
                    if (tx !== frame[b] || tx_ready !== 1'b0) begin
                        $display("FAIL t=%0t bit %0d clock %0d tx=%b tx_ready=%b expected tx=%b",
                                 $time, b, c, tx, tx_ready, frame[b]);
                        errors = errors + 1;
                    end
                    @(negedge clk);
                end
            end
            if (tx !== 1'b1 || tx_ready !== 1'b1) begin
                $display("FAIL t=%0t after frame tx=%b tx_ready=%b", $time, tx, tx_ready);
                errors = errors + 1;
            end
        end
    endtask

    // Holds the line at one level. Call just after a falling edge.
    task drive_line(input level, input integer clocks);
        begin
            rx_drive = level;
            repeat (clocks) @(negedge clk);
        end
    endtask

    // Drives one frame straight into the receiver, with a choice of stop bit.
    task send_rx(input [7:0] data, input stop);
        reg [9:0] frame;
        integer   b;
        begin
            frame = {stop, data, 1'b0};
            for (b = 0; b < 10; b = b + 1)
                drive_line(frame[b], CLKS_PER_BIT);
        end
    endtask

    initial begin
        $dumpfile("build/tb_uart.vcd");
        $dumpvars(0, tb_uart);

        repeat (2) @(negedge clk);
        rst = 1'b0;
        #1;
        if (tx !== 1'b1 || tx_ready !== 1'b1 || rx_valid !== 1'b0 || rx_error !== 1'b0) begin
            $display("FAIL after reset tx=%b tx_ready=%b rx_valid=%b rx_error=%b",
                     tx, tx_ready, rx_valid, rx_error);
            errors = errors + 1;
        end

        // Loopback: every byte value, back to back.
        send_tx(8'hA5);
        for (i = 0; i < 256; i = i + 1)
            send_tx(i[7:0]);
        repeat (2 * CLKS_PER_BIT) @(negedge clk);
        expect_quiet(0);

        // A byte offered while the transmitter is busy has to wait.
        send_tx_then_offer(8'hC3, 8'h3C);
        send_tx(8'h3C);
        tx_valid = 1'b0;
        repeat (2 * CLKS_PER_BIT) @(negedge clk);
        expect_quiet(0);

        // Reset in the middle of a frame stops it, and nothing arrives.
        tx_valid = 1'b1;
        tx_data  = 8'h00;
        @(negedge clk);
        tx_valid = 1'b0;
        repeat (4 * CLKS_PER_BIT) @(negedge clk);
        rst = 1'b1;
        @(negedge clk);
        rst = 1'b0;
        #1;
        if (tx !== 1'b1 || tx_ready !== 1'b1) begin
            $display("FAIL t=%0t after mid-frame reset tx=%b tx_ready=%b", $time, tx, tx_ready);
            errors = errors + 1;
        end
        @(negedge clk);
        repeat (12 * CLKS_PER_BIT) @(negedge clk);
        expect_quiet(0);

        // The receiver alone. A low stop bit is a framing error, and rx_data
        // keeps its last good value.
        loop = 1'b0;
        pending[tail] = 8'h3C;
        tail = tail + 1;
        send_rx(8'h3C, 1'b1);
        send_rx(8'h96, 1'b0);
        drive_line(1'b1, 2 * CLKS_PER_BIT);
        expect_quiet(1);
        if (rx_data !== 8'h3C) begin
            $display("FAIL t=%0t rx_data=%h changed by a framing error", $time, rx_data);
            errors = errors + 1;
        end

        // The next frame after an error is received normally.
        pending[tail] = 8'h5A;
        tail = tail + 1;
        send_rx(8'h5A, 1'b1);
        drive_line(1'b1, CLKS_PER_BIT);
        expect_quiet(1);

        // A low pulse much shorter than half a bit is not a start bit.
        drive_line(1'b0, 1);
        drive_line(1'b1, 12 * CLKS_PER_BIT);
        expect_quiet(1);

        // A line held low gives one error, not one per ten bits.
        drive_line(1'b0, 40 * CLKS_PER_BIT);
        drive_line(1'b1, 2 * CLKS_PER_BIT);
        expect_quiet(2);

        pending[tail] = 8'hC3;
        tail = tail + 1;
        send_rx(8'hC3, 1'b1);
        drive_line(1'b1, CLKS_PER_BIT);
        expect_quiet(2);

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
