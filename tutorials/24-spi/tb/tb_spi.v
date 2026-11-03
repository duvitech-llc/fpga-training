`timescale 1ns/1ps

module tb_spi;

    reg        clk = 1'b0;
    reg        rst = 1'b1;
    reg        cpol = 1'b0;
    reg        cpha = 1'b0;
    reg  [7:0] clk_div = 8'd0;
    reg        tx_valid = 1'b0;
    reg  [7:0] tx_data = 8'd0;
    reg        tx_last = 1'b0;
    wire       tx_ready;
    wire       rx_valid;
    wire [7:0] rx_data;
    wire       sclk;
    wire       mosi;
    wire       cs_n;
    wire       flash_miso;

    // MISO comes from the flash, or from MOSI when loop is high.
    reg  loop = 1'b1;
    wire miso = loop ? mosi : flash_miso;

    integer errors = 0;
    integer i;
    integer d;
    integer m;
    integer v_seen;

    spi_master #(.DIV_WIDTH(8)) dut (
        .clk(clk), .rst(rst),
        .cpol(cpol), .cpha(cpha), .clk_div(clk_div),
        .tx_valid(tx_valid), .tx_data(tx_data), .tx_last(tx_last), .tx_ready(tx_ready),
        .rx_valid(rx_valid), .rx_data(rx_data),
        .sclk(sclk), .mosi(mosi), .miso(miso), .cs_n(cs_n)
    );

    // The flash is deselected during the loopback tests.
    wire flash_cs_n = cs_n || loop;
    spi_flash_model flash (.cs_n(flash_cs_n), .sclk(sclk), .mosi(mosi), .miso(flash_miso));

    // The same file the flash loads, to check what comes back.
    reg [7:0] image [0:255];
    initial $readmemh("tb/flash.hex", image);

    always #5 clk = ~clk;

    // Bytes sent and received, and when each one arrived.
    reg [7:0] sent [0:255];
    reg [7:0] got  [0:255];
    integer   got_at [0:255];
    integer   n_sent = 0;
    integer   n_got  = 0;

    always @(negedge clk) begin
        if (rx_valid === 1'b1) begin
            got[n_got]    = rx_data;
            got_at[n_got] = $stime;
            n_got = n_got + 1;
        end
    end

    // Watches the pins, apart from the master: SCLK starts at CPOL and makes
    // 16 edges for each byte of the transaction.
    reg     watch = 1'b0;
    integer pin_edges = 0;
    integer txn_bytes = 0;
    always @(sclk)
        if (cs_n === 1'b0)
            pin_edges = pin_edges + 1;
    always @(negedge cs_n) begin
        pin_edges = 0;
        txn_bytes = 0;
        if (watch && sclk !== cpol) begin
            $display("FAIL t=%0t CS fell with sclk=%b cpol=%b", $time, sclk, cpol);
            errors = errors + 1;
        end
    end
    always @(posedge cs_n) begin
        if (watch && (pin_edges != 16 * txn_bytes || sclk !== cpol)) begin
            $display("FAIL t=%0t CS rose after %0d edges for %0d bytes, sclk=%b",
                     $time, pin_edges, txn_bytes, sclk);
            errors = errors + 1;
        end
    end

    // Call just after a falling edge. Offers one byte and returns on the falling
    // edge after it was accepted, without waiting for it to finish.
    task put(input [7:0] data, input last);
        begin
            tx_valid = 1'b1;
            tx_data  = data;
            tx_last  = last;
            #1;
            while (tx_ready !== 1'b1)
                @(negedge clk);
            sent[n_sent] = data;
            n_sent = n_sent + 1;
            @(negedge clk);
            txn_bytes = txn_bytes + 1;  // CS has fallen by now
            tx_valid = 1'b0;
            tx_data  = ~data;
            tx_last  = 1'b0;
            // A byte is under way: no other may be taken until it ends.
            if (tx_ready !== 1'b0 || cs_n !== 1'b0) begin
                $display("FAIL t=%0t after accept tx_ready=%b cs_n=%b", $time, tx_ready, cs_n);
                errors = errors + 1;
            end
        end
    endtask

    task wait_idle;
        begin
            #1;
            while (!(cs_n === 1'b1 && tx_ready === 1'b1))
                @(negedge clk);
            @(negedge clk);
        end
    endtask

    task clear;
        begin
            n_sent = 0;
            n_got  = 0;
        end
    endtask

    task check_got(input integer index, input [7:0] want);
        begin
            if (index >= n_got || got[index] !== want) begin
                $display("FAIL t=%0t byte %0d got %h expected %h (%0d received)",
                         $time, index, got[index], want, n_got);
                errors = errors + 1;
            end
        end
    endtask

    // One flash command: cmd, then the address bytes if any, then count dummy
    // bytes to clock the answer out, all with CS held low.
    task flash_cmd(input [7:0] cmd, input integer addr_bytes, input [23:0] addr,
                   input integer count);
        integer k;
        begin
            clear;
            put(cmd, count == 0 && addr_bytes == 0);
            for (k = addr_bytes - 1; k >= 0; k = k - 1)
                put(addr[8 * k +: 8], count == 0 && k == 0);
            for (k = 0; k < count; k = k + 1)
                put(8'h00, k == count - 1);
            wait_idle;
        end
    endtask

    task expect_violations(input integer more);
        begin
            if (flash.violations - v_seen < more) begin
                $display("FAIL t=%0t the flash flagged %0d violations, expected at least %0d",
                         $time, flash.violations - v_seen, more);
                errors = errors + 1;
            end
            v_seen = flash.violations;
        end
    endtask

    task show_id(input [8*24-1:0] what);
        begin
            $display("%0s: JEDEC ID read as %h %h %h, flash flagged %0d violations",
                     what, got[1], got[2], got[3], flash.violations - v_seen);
        end
    endtask

    initial begin
        $dumpfile("build/tb_spi.vcd");
        $dumpvars(0, tb_spi);

        repeat (2) @(negedge clk);
        rst = 1'b0;
        watch = 1'b1;
        #1;
        if (cs_n !== 1'b1 || sclk !== 1'b0 || tx_ready !== 1'b1 || rx_valid !== 1'b0) begin
            $display("FAIL after reset cs_n=%b sclk=%b tx_ready=%b rx_valid=%b",
                     cs_n, sclk, tx_ready, rx_valid);
            errors = errors + 1;
        end
        @(negedge clk);

        // ---- Loopback: MISO wired to MOSI, so each byte comes back. ----
        // Two transactions in each mode at four dividers.
        for (m = 0; m < 4; m = m + 1) begin
            for (d = 0; d < 4; d = d + 1) begin
                cpol    = m[1];
                cpha    = m[0];
                clk_div = (d == 3) ? 8'd6 : d[7:0];
                clear;
                put(8'hA5, 1'b0);
                put(8'h3C, 1'b0);
                put(m[7:0] * 8'd16 + d[7:0], 1'b1);
                wait_idle;
                put(8'h81, 1'b1);
                wait_idle;
                for (i = 0; i < n_sent; i = i + 1)
                    check_got(i, sent[i]);
                if (n_got != 4) begin
                    $display("FAIL mode %0d clk_div %0d: %0d bytes received", m, clk_div, n_got);
                    errors = errors + 1;
                end
            end
        end

        // ---- Throughput: 8 bytes back to back in one transaction. ----
        cpol = 1'b0;
        cpha = 1'b0;
        for (d = 0; d < 4; d = d + 1) begin
            clk_div = (8'd1 << d) - 8'd1;
            wait_idle;
            clear;
            for (i = 0; i < 8; i = i + 1)
                put(i[7:0], i == 7);
            wait_idle;
            $display("clk_div=%0d: SCLK %0d ns, %0d clocks per byte",
                     clk_div, 20 * (clk_div + 1), (got_at[7] - got_at[0]) / 70);
            if (got_at[7] - got_at[0] != 70 * (16 * (1 << d) + 1)) begin
                $display("FAIL clk_div %0d: 8 bytes took %0d ns", clk_div, got_at[7] - got_at[0]);
                errors = errors + 1;
            end
        end

        // ---- A new CPOL moves SCLK while CS is high, v_seen the next byte. ----
        clk_div = 8'd3;
        cpol = 1'b1;
        @(negedge clk);
        if (sclk !== 1'b1 || tx_ready !== 1'b0 || cs_n !== 1'b1) begin
            $display("FAIL t=%0t after CPOL change sclk=%b tx_ready=%b", $time, sclk, tx_ready);
            errors = errors + 1;
        end
        repeat (4) @(negedge clk);
        if (tx_ready !== 1'b1) begin
            $display("FAIL t=%0t tx_ready=%b half a period after CPOL change", $time, tx_ready);
            errors = errors + 1;
        end
        cpol = 1'b0;
        wait_idle;

        // ---- The flash, in the two modes it supports. ----
        loop   = 1'b0;
        v_seen = 0;

        cpol = 1'b0; cpha = 1'b0; clk_div = 8'd0;
        flash_cmd(8'h9F, 0, 24'd0, 3);
        show_id("mode 0, clk_div 0");
        check_got(1, 8'h5A); check_got(2, 8'h40); check_got(3, 8'h14);

        cpol = 1'b1; cpha = 1'b1;
        flash_cmd(8'h9F, 0, 24'd0, 3);
        show_id("mode 3, clk_div 0");
        check_got(1, 8'h5A); check_got(2, 8'h40); check_got(3, 8'h14);

        // 0x03 is limited to a 30 ns period, so clk_div 1 (40 ns) is the fastest.
        cpol = 1'b0; cpha = 1'b0; clk_div = 8'd1;
        flash_cmd(8'h03, 3, 24'h000000, 16);
        $write("mode 0, clk_div 1: read 0x000000 as \"");
        for (i = 4; i < 20; i = i + 1)
            $write("%c", got[i]);
        $display("\"");
        for (i = 0; i < 16; i = i + 1)
            check_got(4 + i, image[i]);

        // In mode 3, across the end of the memory, where the address wraps.
        cpol = 1'b1; cpha = 1'b1; clk_div = 8'd2;
        flash_cmd(8'h03, 3, 24'h0000F8, 16);
        for (i = 0; i < 16; i = i + 1)
            check_got(4 + i, image[(248 + i) % 256]);

        // Two commands back to back. CS is high for 20 ns between them.
        cpol = 1'b0; cpha = 1'b0; clk_div = 8'd0;
        flash_cmd(8'h9F, 0, 24'd0, 3);
        check_got(1, 8'h5A);
        flash_cmd(8'h9F, 0, 24'd0, 3);
        check_got(3, 8'h14);

        if (flash.violations != 0) begin
            $display("FAIL the flash flagged %0d violations in correct use", flash.violations);
            errors = errors + 1;
        end
        v_seen = flash.violations;

        // ---- Deliberate mistakes. The flash must flag each one. ----
        $display("--- Deliberate mistakes follow. Each should print FLASH VIOLATION. ---");

        // Too fast for 0x03.
        cpol = 1'b0; cpha = 1'b0; clk_div = 8'd0;
        flash_cmd(8'h03, 3, 24'h000000, 2);
        $display("0x03 at clk_div 0: read %h %h, flash flagged %0d violations",
                 got[4], got[5], flash.violations - v_seen);
        expect_violations(1);

        // The wrong modes. The flash takes mode 1 for mode 0, and mode 2 for mode 3.
        cpol = 1'b0; cpha = 1'b1; clk_div = 8'd1;
        flash_cmd(8'h9F, 0, 24'd0, 3);
        show_id("mode 1, clk_div 1");
        expect_violations(1);

        cpol = 1'b1; cpha = 1'b0;
        flash_cmd(8'h9F, 0, 24'd0, 3);
        show_id("mode 2, clk_div 1");
        expect_violations(1);

        // Reset in the middle of a byte raises CS after 5 bits.
        cpol = 1'b0; cpha = 1'b0; clk_div = 8'd1;
        watch = 1'b0;
        put(8'h9F, 1'b0);
        repeat (2 * 5 * 2 - 1) @(negedge clk);
        rst = 1'b1;
        @(negedge clk);
        rst = 1'b0;
        wait_idle;
        watch = 1'b1;
        $display("reset in the middle of a byte: flash flagged %0d violations",
                 flash.violations - v_seen);
        expect_violations(1);

        // Correct use again: the flash has recovered.
        flash_cmd(8'h9F, 0, 24'd0, 3);
        check_got(1, 8'h5A); check_got(2, 8'h40); check_got(3, 8'h14);
        expect_violations(0);
        if (flash.violations != v_seen) begin
            $display("FAIL the flash flagged a violation after recovering");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
