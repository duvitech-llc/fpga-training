`timescale 1ns/1ps

module tb_sync_fifo;

    parameter WIDTH = 8;
    parameter DEPTH = 16;

    localparam integer NO_READ = -1;

    reg              clk     = 1'b0;
    reg              rst     = 1'b1;
    reg              wr_en   = 1'b0;
    reg  [WIDTH-1:0] wr_data = 0;
    reg              rd_en   = 1'b0;
    wire             full;
    wire             empty;
    wire [WIDTH-1:0] rd_data;

    reg [WIDTH-1:0] held;

    integer errors = 0;
    integer i;

    sync_fifo #(.WIDTH(WIDTH), .DEPTH(DEPTH)) dut (
        .clk(clk), .rst(rst),
        .wr_en(wr_en), .wr_data(wr_data), .full(full),
        .rd_en(rd_en), .rd_data(rd_data), .empty(empty)
    );

    always #5 clk = ~clk;

    // A different value for each n, so an entry from the wrong place shows up.
    function integer val(input integer n);
        val = n * 3 + 1;
    endfunction

    // Call just after a falling edge, and each call takes one clock cycle.
    // expected_used is the number of entries after the rising edge.
    // expected_read is the value rd_data must show after it, or NO_READ if
    // rd_data must hold. !== also catches a value that is still x or z.
    task step(input r, input w, input integer d, input re,
              input integer expected_used, input integer expected_read);
        begin
            rst     = r;
            wr_en   = w;
            wr_data = d[WIDTH-1:0];
            rd_en   = re;
            held    = rd_data;
            @(negedge clk);
            if (full !== (expected_used == DEPTH)) begin
                $display("FAIL t=%0t full=%b with %0d entries", $time, full, expected_used);
                errors = errors + 1;
            end
            if (empty !== (expected_used == 0)) begin
                $display("FAIL t=%0t empty=%b with %0d entries", $time, empty, expected_used);
                errors = errors + 1;
            end
            if (expected_read == NO_READ) begin
                if (rd_data !== held) begin
                    $display("FAIL t=%0t rd_data=%0h did not hold %0h", $time, rd_data, held);
                    errors = errors + 1;
                end
            end else if (rd_data !== expected_read[WIDTH-1:0]) begin
                $display("FAIL t=%0t rd_data=%0h expected=%0h",
                         $time, rd_data, expected_read[WIDTH-1:0]);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("build/tb_sync_fifo.vcd");
        $dumpvars(0, tb_sync_fifo);

        @(negedge clk);

        //   rst   wr    data  rd    entries read
        step(1'b1, 1'b0, 0,    1'b0, 0,      NO_READ);  // reset empties the FIFO
        step(1'b0, 1'b0, 0,    1'b1, 0,      NO_READ);  // read when empty is ignored

        // Fill it, then try once more. The extra value must never come out.
        for (i = 0; i < DEPTH; i = i + 1)
            step(1'b0, 1'b1, val(i), 1'b0, i + 1, NO_READ);
        step(1'b0, 1'b1, val(100), 1'b0, DEPTH, NO_READ);  // write when full is ignored
        step(1'b0, 1'b0, 0,        1'b0, DEPTH, NO_READ);  // both idle holds

        // Drain it, in order. The pointers are now equal again, one lap later.
        for (i = 0; i < DEPTH; i = i + 1)
            step(1'b0, 1'b0, 0, 1'b1, DEPTH - 1 - i, val(i));
        step(1'b0, 1'b0, 0, 1'b1, 0, NO_READ);  // read when empty keeps rd_data

        // Both at empty: only the write happens.
        step(1'b0, 1'b1, val(30), 1'b1, 1, NO_READ);

        // Both with one entry: the count stays at 1 for two laps of the memory.
        for (i = 0; i < 2 * DEPTH; i = i + 1)
            step(1'b0, 1'b1, val(31 + i), 1'b1, 1, val(30 + i));
        step(1'b0, 1'b0, 0, 1'b1, 0, val(30 + 2 * DEPTH));

        // Fill it again, starting from a different address.
        step(1'b0, 1'b1, val(0), 1'b0, 1, NO_READ);
        step(1'b0, 1'b0, 0,      1'b1, 0, val(0));
        for (i = 0; i < DEPTH; i = i + 1)
            step(1'b0, 1'b1, val(i + 1), 1'b0, i + 1, NO_READ);

        // Both at full: only the read happens, and the write is lost.
        step(1'b0, 1'b1, val(100), 1'b1, DEPTH - 1, val(1));
        // One entry is now free, so the same write works.
        step(1'b0, 1'b1, val(101), 1'b0, DEPTH, NO_READ);
        for (i = 1; i < DEPTH; i = i + 1)
            step(1'b0, 1'b0, 0, 1'b1, DEPTH - i, val(i + 1));
        step(1'b0, 1'b0, 0, 1'b1, 0, val(101));

        // Reset beats both enables and leaves rd_data alone.
        step(1'b0, 1'b1, val(5), 1'b0, 1, NO_READ);
        step(1'b0, 1'b1, val(6), 1'b0, 2, NO_READ);
        step(1'b1, 1'b1, val(7), 1'b1, 0, NO_READ);
        step(1'b0, 1'b0, 0,      1'b1, 0, NO_READ);  // nothing left to read
        step(1'b0, 1'b1, val(8), 1'b0, 1, NO_READ);  // works again after reset
        step(1'b0, 1'b0, 0,      1'b1, 0, val(8));

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
