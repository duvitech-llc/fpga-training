`timescale 1ns/1ps

// Boots the whole system from the SPI flash model and runs each program, as a
// board would: nothing is put in the RAM by the testbench. Each run is judged by
// what comes out of the UART, decoded at bit level as in Tutorial 26, by how it
// stopped, and by checks on every clock. Inputs change on the falling edge.
//
// The checks on every clock:
//   - the SPI controller and the XIP slave never both have CS low;
//   - the flash model sees no broken timing rule;
//   - the timer's line equals mtime >= mtimecmp of the clock before;
//   - every cacheable fetch is a hit, with no word fetched behind the cache, or
//     a miss that fetched exactly one line.
//
// demo.c prints a report. Every number in it is checked against the
// testbench's own count, taken at the moment the program read the register, or,
// for the CRC, against a CRC-32 the testbench works out itself.
//
// A program stops at its first EBREAK. Then every slave's hold goes high, so
// the core can do nothing more on the bus while the UART finishes. A C program
// must stop at crt0's _exit, with 0 in a0.
//
// Each run happens twice: mode 0 holds every slave's hold low, mode 1 makes
// every slave stall at random, on about one clock in four. Mode 0's demo is
// also measured: CPI, the hit rate, interrupt latency with the DMA engine busy
// and idle, and what sharing the flash costs.
module tb_soc #(
    parameter CLKS_PER_BIT = 16
);

    localparam integer TIMEOUT    = 2000000;   // clocks for one boot and its program
    localparam integer FRAME      = 10 * CLKS_PER_BIT;
    localparam integer MAX_OUTPUT = 1024;
    localparam [31:0]  ROM_BASE   = 32'h0010_0000;
    localparam [31:0]  XIP_BASE   = 32'h4000_0000;
    localparam integer LINE_WORDS = 4;         // soc.v's default cache

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg uart_rx = 1'b1;
    reg [14:0] hold = 15'd0;

    wire        uart_tx, trap, retire;
    wire [31:0] trap_cause, gpio_out, retire_pc, retire_instr;
    wire        sclk, mosi, cs_n, flash_miso;

    soc #(.CLKS_PER_BIT(CLKS_PER_BIT), .ROM_INIT("build/boot.hex")) dut (
        .clk(clk), .rst(rst), .uart_rx(uart_rx), .uart_tx(uart_tx), .gpio_out(gpio_out),
        .spi_sclk(sclk), .spi_mosi(mosi), .spi_miso(flash_miso), .spi_cs_n(cs_n),
        .trap(trap), .trap_cause(trap_cause),
        .retire(retire), .retire_pc(retire_pc), .retire_instr(retire_instr),
        .hold(hold)
    );

    // Tutorial 24's flash model, unchanged, with 64 KiB. Its file is replaced
    // before every run.
    spi_flash_model #(
        .MEM_FILE("build/flash_demo.hex"), .MEM_BYTES(65536)
    ) u_flash (
        .cs_n(cs_n), .sclk(sclk), .mosi(mosi), .miso(flash_miso)
    );

    // MISO floats while the flash is not driving it. A pull-up holds it high.
    pullup (flash_miso);

    always #5 clk = ~clk;

    integer errors = 0;
    integer mode = 0;
    integer n;
    reg     measuring = 1'b0;      // this run is mode 0's demo: measure it
    reg     waves = 1'b0;          // +waves: record the two windows below

    task fail(input string why);
        begin
            if (errors < 30)
                $display("FAIL t=%0t %0s", $time, why);
            errors = errors + 1;
        end
    endtask

    // ----- Random stalls, the same in both simulators, and the freeze at the end -----

    reg [31:0] random = 32'h2545F491;   // xorshift32
    reg        freeze = 1'b0;

    function [31:0] next_random(input [31:0] r);
        reg [31:0] s;
        begin
            s = r ^ (r << 13);
            s = s ^ (s >> 17);
            next_random = s ^ (s << 5);
        end
    endfunction

    always @(negedge clk) begin
        random = next_random(random);
        if (freeze)
            hold <= 15'h7FFF;
        else
            hold <= (mode == 1) ? (random[14:0] & random[29:15]) : 15'd0;
    end

    // ----- The UART decoder: uart_tx back to bytes, every clock of every bit checked -----

    reg [7:0] out [0:MAX_OUTPUT-1];
    integer   out_count = 0;
    integer   frame_bit = -1;   // -1 is idle, 0 is the start bit, 9 is the stop bit
    integer   bit_clock = 0;
    reg       bit_level = 1'b1;
    reg [7:0] frame_data = 8'd0;

    always @(posedge clk) begin
        if (rst) begin
            frame_bit = -1;
            bit_clock = 0;
        end else if (frame_bit == -1) begin
            if (uart_tx === 1'b0) begin
                frame_bit = 0;
                bit_clock = 1;
                bit_level = 1'b0;
            end
        end else begin
            if (bit_clock == 0)
                bit_level = uart_tx;
            else if (uart_tx !== bit_level)
                fail($sformatf("uart_tx changed inside bit %0d", frame_bit));
            bit_clock = bit_clock + 1;
        end

        if (frame_bit != -1 && bit_clock == CLKS_PER_BIT) begin
            if (frame_bit >= 1 && frame_bit <= 8)
                frame_data[frame_bit - 1] = bit_level;
            if (frame_bit == 9) begin
                if (bit_level !== 1'b1)
                    fail("stop bit on uart_tx is low");
                if (out_count < MAX_OUTPUT)
                    out[out_count] = frame_data;
                out_count = out_count + 1;
                frame_bit = -1;
            end else begin
                frame_bit = frame_bit + 1;
            end
            bit_clock = 0;
        end
    end

    // ----- The UART sender: the program's input, once send_after bytes are out -----

    reg [8*8-1:0] in_text = 0;
    integer       in_len = 0;
    integer       send_after = 0;
    integer       send_pos = 0;
    integer       send_bit = -1;   // -1 idle, 0 start, 1 to 8 data, 9 stop
    integer       send_clock = 0;
    integer       sent = 0;        // bytes sent so far in this run
    integer       gap = 0;         // idle clocks left before the next byte
    reg           sending = 1'b0;

    always @(negedge clk) begin
        if (rst) begin
            uart_rx <= 1'b1;
            send_bit = -1;
            sending = 1'b0;
            sent = 0;
            gap = 0;
        end else if (!sending && sent == 0 && in_len > 0 && out_count >= send_after) begin
            sending = 1'b1;
            send_pos = 0;
            send_bit = 0;
            send_clock = 0;
        end
        if (!rst && sending && gap > 0) begin
            uart_rx <= 1'b1;
            gap = gap - 1;
        end else if (!rst && sending) begin
            if (send_clock == 0)
                uart_rx <= send_bit == 0 ? 1'b0 :
                           send_bit == 9 ? 1'b1 :
                           in_text[8 * (in_len - 1 - send_pos) + (send_bit - 1)];
            send_clock = send_clock + 1;
            if (send_clock == CLKS_PER_BIT) begin
                send_clock = 0;
                send_bit = send_bit + 1;
                if (send_bit == 10) begin
                    sent = sent + 1;
                    send_pos = send_pos + 1;
                    // A gap of four frames between bytes, so each one is its
                    // own interrupt.
                    send_bit = 0;
                    gap = 4 * FRAME;
                    if (send_pos >= in_len)
                        sending = 1'b0;
                end
            end
        end
    end

    // ----- Clocks, instructions and traps -----

    integer clocks = 0;            // since reset, as the cycle counter counts them
    integer retires = 0;           // since reset, as instret counts them
    integer hits = 0, misses = 0, far_words = 0;   // the cache, counted below
    integer retired_rom = 0, retired_ram = 0, retired_xip = 0;
    integer boot_clocks = -1;      // reset to the first fetch at the entry point, 0
    integer boot_retires = 0;
    integer timer_irqs = 0, external_irqs = 0, exceptions = 0;
    reg     stopped = 1'b0;
    reg [31:0] stop_pc, stop_a0, first_exception;

    // What the program saw: the testbench's counts at the edge where the bus
    // took its read of the counters or of the cache's counters. Taken here, at
    // the edge itself, before the counts move on, as the registers do.
    integer snap_cycles = -1, snap_instret = -1, snap_hits = -1, snap_misses = -1;

    always @(posedge clk) begin
        if (!rst && dut.s_cyc && !dut.s_we) begin
            if (dut.s_stb[3] && !dut.s_stall[3]) begin
                if (dut.s_adr[0])
                    snap_instret = retires;
                else
                    snap_cycles = clocks;
            end
            if (dut.s_stb[10] && !dut.s_stall[10]) begin
                if (dut.s_adr[1:0] == 2'd1)
                    snap_hits = hits;
                if (dut.s_adr[1:0] == 2'd2)
                    snap_misses = misses;
            end
        end
        if (rst) begin
            clocks = 0;
            retires = 0;
        end else begin
            clocks = clocks + 1;
            if (retire === 1'b1)
                retires = retires + 1;
        end
    end

    always @(negedge clk) begin
        if (!rst && !stopped) begin
            if (boot_clocks < 0 && dut.mem_valid === 1'b1 && dut.mem_instr === 1'b1
                && dut.mem_addr == 32'd0) begin
                boot_clocks = clocks;
                boot_retires = retires;
            end
            if (retire === 1'b1) begin
                if (retire_pc >= XIP_BASE)
                    retired_xip = retired_xip + 1;
                else if (retire_pc >= ROM_BASE)
                    retired_rom = retired_rom + 1;
                else
                    retired_ram = retired_ram + 1;
            end
            if (trap === 1'b1) begin
                if (trap_cause == 32'h8000_0007)
                    timer_irqs = timer_irqs + 1;
                else if (trap_cause == 32'h8000_000B)
                    external_irqs = external_irqs + 1;
                else if (trap_cause == 32'd3) begin
                    stopped = 1'b1;
                    freeze  = 1'b1;
                    stop_pc = retire_pc;
                    stop_a0 = dut.u_core.u_regs.q[10];
                end else begin
                    if (exceptions == 0)
                        first_exception = trap_cause;
                    exceptions = exceptions + 1;
                end
            end
        end
    end

    // ----- The timer, checked on every clock, as in Tutorial 27 -----

    reg past_due = 1'b0;
    reg past_ok  = 1'b0;

    always @(negedge clk) begin
        if (past_ok && !rst && dut.irq_timer !== past_due)
            fail($sformatf("timer irq is %b, but mtime >= mtimecmp was %b a clock ago",
                           dut.irq_timer, past_due));
        past_due = dut.u_timer.mtime >= dut.u_timer.mtimecmp;
        past_ok  = !rst;
    end

    // ----- The flash: one owner at a time -----

    integer owner_changes = 0, closes = 0, spi_waits = 0, xip_waits = 0;
    integer spi_commands = 0, xip_commands = 0;
    integer violations_seen = 0;
    reg [1:0] owner_q = 2'd0;
    reg spi_cs_q = 1'b1, xip_cs_q = 1'b1;

    always @(negedge clk) begin
        if (!rst) begin
            if (dut.spi_cs_n_c === 1'b0 && dut.xip_cs_n_c === 1'b0)
                fail("the SPI controller and the XIP slave both have CS low");
            if (dut.u_flash_share.owner != owner_q)
                owner_changes = owner_changes + 1;
            if (dut.xip_close === 1'b1)
                closes = closes + 1;
            if (dut.s_cyc && dut.s_stb[7] && !dut.spi_go)
                spi_waits = spi_waits + 1;
            if (dut.s_cyc && dut.s_stb[12] && !dut.xip_go)
                xip_waits = xip_waits + 1;
            if (spi_cs_q && !dut.spi_cs_n_c)
                spi_commands = spi_commands + 1;
            if (xip_cs_q && !dut.xip_cs_n_c)
                xip_commands = xip_commands + 1;
        end
        owner_q  = dut.u_flash_share.owner;
        spi_cs_q = dut.spi_cs_n_c;
        xip_cs_q = dut.xip_cs_n_c;
    end

    // ----- The cache, counted from outside -----

    // A cacheable fetch is a hit if no word was fetched behind the cache while
    // it waited, and a miss otherwise. A miss must fetch exactly one line.
    // hits, misses and far_words are declared with the clocks, above.
    integer xip_hits = 0, xip_misses = 0;

    always @(negedge clk) begin
        if (rst) begin
            far_words = 0;
        end else begin
            if (dut.d_valid === 1'b1 && dut.d_ready === 1'b1 && dut.d_instr === 1'b1)
                far_words = far_words + 1;
            if (dut.mem_valid === 1'b1 && dut.mem_instr === 1'b1
                && (dut.mem_ready === 1'b1 || dut.mem_err === 1'b1)) begin
                if (dut.cacheable && dut.mem_ready) begin
                    if (far_words == 0) begin
                        hits = hits + 1;
                        if (dut.mem_addr >= XIP_BASE)
                            xip_hits = xip_hits + 1;
                    end else begin
                        misses = misses + 1;
                        if (dut.mem_addr >= XIP_BASE)
                            xip_misses = xip_misses + 1;
                        if (far_words != LINE_WORDS)
                            fail($sformatf("a miss at %h fetched %0d words, not %0d",
                                           dut.mem_addr, far_words, LINE_WORDS));
                    end
                end
                far_words = 0;
            end
        end
    end

    // ----- The DMA engine, counted from outside -----

    integer dma_bytes = 0, dma_ends = 0;
    reg dma_end_q = 1'b0;

    always @(negedge clk) begin
        if (!rst) begin
            if (dut.dma_cyc && dut.dma_we && dut.dma_ack)
                dma_bytes = dma_bytes + (dut.u_dma.bytes ? 1 : 4);
            if ((dut.dma_done || dut.dma_error) && !dma_end_q)
                dma_ends = dma_ends + 1;
        end
        dma_end_q = !rst && (dut.dma_done || dut.dma_error);
    end

    // ----- Interrupt latency, with the DMA engine busy and idle -----

    // pending: clocks in which an enabled interrupt was pending with MIE set,
    // up to the clock it was taken. entering: from then to the handler's first
    // retire. Each interrupt goes in one of three classes:
    //   0  the DMA engine was idle all the while
    //   1  the DMA engine was busy at some point, and the cache did not fill a
    //      line from the flash
    //   2  the cache was filling a line from the flash at some point
    integer pending = 0, entering = -1;
    integer cls = 0;               // the class of the interrupt being measured
    integer lat_base = 0;          // 0 for demo.c, 3 for irqload.c
    reg     saw_busy = 1'b0, saw_fill = 1'b0;
    integer lat_count [0:5], lat_min [0:5], lat_max [0:5], lat_sum [0:5];
    integer ent_min [0:5], ent_max [0:5], ent_sum [0:5], ent_count [0:5];

    always @(negedge clk) begin
        if (rst || stopped || !measuring) begin
            pending = 0;
            entering = -1;
        end else begin
            if (dut.u_core.irq_pending === 1'b1) begin
                if (pending == 0) begin
                    saw_busy = 1'b0;
                    saw_fill = 1'b0;
                end
                pending = pending + 1;
            end
            if (pending > 0 || entering >= 0) begin
                if (dut.u_dma.state != 3'd0)
                    saw_busy = 1'b1;
                if (dut.u_icache.state != 0 && dut.d_addr >= XIP_BASE)
                    saw_fill = 1'b1;
            end
            if (entering >= 0)
                entering = entering + 1;
            if (retire === 1'b1 && entering > 0) begin
                ent_count[cls] = ent_count[cls] + 1;
                ent_sum[cls]   = ent_sum[cls] + entering;
                if (entering < ent_min[cls]) ent_min[cls] = entering;
                if (entering > ent_max[cls]) ent_max[cls] = entering;
                entering = -1;
            end
            if (trap === 1'b1 && trap_cause[31]) begin
                cls = lat_base + (saw_fill ? 2 : saw_busy ? 1 : 0);
                lat_count[cls] = lat_count[cls] + 1;
                lat_sum[cls]   = lat_sum[cls] + pending;
                if (pending < lat_min[cls]) lat_min[cls] = pending;
                if (pending > lat_max[cls]) lat_max[cls] = pending;
                pending = 0;
                entering = 0;
            end else if (dut.u_core.irq_pending !== 1'b1) begin
                pending = 0;
            end
        end
    end

    // ----- The waveform: two windows of mode 0's demo -----

    // With +waves, only the scopes the README walks through are recorded, one
    // level each, and only in two windows: 1000 clocks from the end of the DMA
    // engine's first message, and 700 clocks from the first time the XIP slave
    // gives up the flash. Outside them every signal shows as x.
    integer window = 0;            // clocks left in the open window
    reg     w1_done = 1'b0, w2_done = 1'b0;

    always @(negedge clk) begin
        if (waves && measuring && !rst) begin
            if (window > 0) begin
                window = window - 1;
                if (window == 0)
                    $dumpoff;
            end else if (!w1_done && dut.dma_done === 1'b1) begin
                w1_done = 1'b1;
                window = 1000;
                $dumpon;
            end else if (!w2_done && dut.u_flash_share.owner == 2'd2 && dut.s_cyc
                         && dut.s_stb[7]) begin
                w2_done = 1'b1;
                window = 700;
                $dumpon;
            end
        end
    end

    // ----- Running one boot -----

    task run(input string flash, input string text, input integer len, input integer after);
        integer t;
        begin
            @(negedge clk);
            rst = 1'b1;
            $readmemh(flash, u_flash.mem);
            // The RAM holds something at power-up. The boot ROM must not depend on
            // what, so the testbench fills it with zeros, the same in both simulators.
            for (t = 0; t < 16384; t = t + 1)
                dut.u_ram.mem[t] = 32'd0;
            in_text = 0;
            for (t = 0; t < len; t = t + 1)
                in_text[8 * (len - 1 - t) +: 8] = text[t];
            in_len = len;
            send_after = after;
            out_count = 0;
            stopped = 1'b0;
            freeze = 1'b0;
            boot_clocks = -1;
            stop_pc = 32'hx;
            stop_a0 = 32'hx;
            retired_rom = 0;
            retired_ram = 0;
            retired_xip = 0;
            timer_irqs = 0;
            external_irqs = 0;
            exceptions = 0;
            hits = 0;
            misses = 0;
            xip_hits = 0;
            xip_misses = 0;
            dma_bytes = 0;
            dma_ends = 0;
            owner_changes = 0;
            closes = 0;
            spi_waits = 0;
            xip_waits = 0;
            spi_commands = 0;
            xip_commands = 0;
            snap_cycles = -1;
            snap_instret = -1;
            snap_hits = -1;
            snap_misses = -1;
            @(negedge clk);
            @(negedge clk);
            rst = 1'b0;
            t = 0;
            while (!stopped && t < TIMEOUT) begin
                @(negedge clk);
                t = t + 1;
            end
            if (!stopped)
                fail($sformatf("%0s: no EBREAK after %0d clocks, printed \"%0s\"", flash,
                               TIMEOUT, output_text()));
            // Let the UART finish the frame it may be sending.
            repeat (2 * FRAME) @(negedge clk);
            if (u_flash.violations != violations_seen) begin
                fail($sformatf("%0s: the flash flagged %0d violations", flash,
                               u_flash.violations - violations_seen));
                violations_seen = u_flash.violations;
            end
            if (exceptions != 0)
                fail($sformatf("%0s: %0d exceptions, the first with mcause %h", flash,
                               exceptions, first_exception));
        end
    endtask

    // The output as text, with \n for each newline, for messages.
    function automatic string output_text;
        string s;
        integer i;
        begin
            s = "";
            for (i = 0; i < out_count && i < MAX_OUTPUT; i = i + 1)
                if (out[i] == 8'h0A)
                    s = {s, "\\n"};
                else
                    s = $sformatf("%0s%c", s, out[i]);
            output_text = s;
        end
    endfunction

    // Line k of the output, without its newline, or "" if there is none.
    function automatic string line(input integer k);
        string s;
        integer i, at;
        begin
            s = "";
            at = 0;
            for (i = 0; i < out_count && i < MAX_OUTPUT && at <= k; i = i + 1) begin
                if (out[i] == 8'h0A)
                    at = at + 1;
                else if (at == k)
                    s = $sformatf("%0s%c", s, out[i]);
            end
            line = s;
        end
    endfunction

    function automatic integer line_count;
        integer i, c;
        begin
            c = 0;
            for (i = 0; i < out_count && i < MAX_OUTPUT; i = i + 1)
                if (out[i] == 8'h0A)
                    c = c + 1;
            line_count = c;
        end
    endfunction

    // A C program must stop at crt0's _exit, with main's return value, 0, in a0.
    reg [31:0] exit_address [0:0];

    task expect_exit(input string what, input string exit_file);
        begin
            $readmemh(exit_file, exit_address);
            if (stop_pc !== exit_address[0] || stop_a0 !== 32'd0)
                fail($sformatf("%0s stopped at %h with a0 = %h, not at _exit %h with 0", what,
                               stop_pc, stop_a0, exit_address[0]));
        end
    endtask

    task expect_line(input string what, input integer k, input string want);
        begin
            if (line(k) != want)
                fail($sformatf("%0s line %0d is \"%0s\", not \"%0s\"", what, k, line(k), want));
        end
    endtask

    // ----- The CRC-32 the demo must print, worked out here -----

    // demo.c fills 512 bytes from xorshift32, starting at 2545F491, with the top
    // byte of each step, then takes CRC-32 of them, as zlib does.
    function [31:0] demo_crc(input integer count);
        reg [31:0] x, crc;
        integer i, b;
        begin
            x = 32'h2545F491;
            crc = 32'hFFFF_FFFF;
            for (i = 0; i < count; i = i + 1) begin
                x = x ^ (x << 13);
                x = x ^ (x >> 17);
                x = x ^ (x << 5);
                crc = crc ^ {24'd0, x[31:24]};
                for (b = 0; b < 8; b = b + 1)
                    crc = crc[0] ? ((crc >> 1) ^ 32'hEDB8_8320) : (crc >> 1);
            end
            demo_crc = ~crc;
        end
    endfunction

    function [31:0] flash_word(input [31:0] address);
        flash_word = {u_flash.mem[address + 3], u_flash.mem[address + 2],
                      u_flash.mem[address + 1], u_flash.mem[address]};
    endfunction

    // ----- The runs -----

    integer v1, v2, v3, v4, got;
    reg [31:0] h1, h2, h3, h4;

    task run_demo;
        begin
            measuring = (mode == 0);
            run("build/flash_demo.hex", "xyz", 3, 30);
            measuring = 1'b0;
            expect_exit("demo", "build/demo.exit");
            expect_line("demo", 0, "SoC demo: booted from flash");
            expect_line("demo", 1, "DMA: hello from the second bus master.");
            expect_line("demo", 2, "DMA: the CPU works out a CRC from flash.");
            expect_line("demo", 3, "DMA: last message, then the report.");
            expect_line("demo", 4, "report");
            if (line_count() != 12)
                fail($sformatf("demo printed %0d lines, not 12: \"%0s\"", line_count(),
                               output_text()));

            got = $sscanf(line(5), "ticks %d", v1);
            if (got != 1 || v1 != timer_irqs)
                fail($sformatf("demo: \"%0s\", and the core took %0d timer interrupts",
                               line(5), timer_irqs));

            got = $sscanf(line(6), "cycles %d instret %d", v1, v2);
            if (got != 2 || v1 != snap_cycles || v2 != snap_instret)
                fail($sformatf("demo: \"%0s\", and the testbench counted %0d and %0d", line(6),
                               snap_cycles, snap_instret));

            got = $sscanf(line(7), "cache hits %d misses %d, %d per mille", v1, v2, v3);
            if (got != 3 || v1 != snap_hits || v2 != snap_misses
                || v3 != (snap_hits * 1000) / (snap_hits + snap_misses))
                fail($sformatf("demo: \"%0s\", and the testbench counted %0d hits, %0d misses",
                               line(7), snap_hits, snap_misses));

            got = $sscanf(line(8), "dma %d copies, %d bytes, %d errors, %d interrupts", v1, v2,
                          v3, v4);
            if (got != 4 || v1 != dma_ends || v2 != dma_bytes || v3 != 0 || v4 != dma_ends)
                fail($sformatf("demo: \"%0s\", and the DMA engine ended %0d copies, wrote %0d bytes",
                               line(8), dma_ends, dma_bytes));
            if (dma_ends != 4 || dma_bytes != 39 + 41 + 36 + 512)
                fail($sformatf("demo: the DMA engine ended %0d copies and wrote %0d bytes, not 4 and 628",
                               dma_ends, dma_bytes));

            got = $sscanf(line(9), "uart %d bytes in, %d interrupts", v1, v2);
            if (got != 2 || v1 != sent || v2 != sent)
                fail($sformatf("demo: \"%0s\", and the testbench sent %0d bytes", line(9), sent));

            got = $sscanf(line(10), "crc software %h hardware %h", h1, h2);
            if (got != 2 || h1 != demo_crc(512) || h2 != demo_crc(512))
                fail($sformatf("demo: \"%0s\", and the CRC-32 is %h", line(10), demo_crc(512)));

            got = $sscanf(line(11), "flash id %h, word at %h by spi %h by xip %h", h1, h2, h3, h4);
            if (got != 4 || h1 != {8'd0, u_flash.JEDEC_ID} || h2 < XIP_BASE
                || h3 != flash_word(h2 - XIP_BASE) || h4 != h3)
                fail($sformatf("demo: \"%0s\", and the flash has id %h, word %h", line(11),
                               u_flash.JEDEC_ID, flash_word(h2 - XIP_BASE)));

            $display("demo, mode %0d: %0d lines, %0d timer and %0d external interrupts, stopped at %h with a0 = %0d",
                     mode, line_count(), timer_irqs, external_irqs, stop_pc, stop_a0);
            if (mode == 0) begin
                for (n = 0; n < line_count(); n = n + 1)
                    $display("  | %0s", line(n));
                $display("  boot: %0d clocks from reset to the first fetch at 0, %0d instructions",
                         boot_clocks, boot_retires);
                $display("  retired: %0d from the boot ROM, %0d from RAM, %0d from the flash",
                         retired_rom, retired_ram, retired_xip);
                $display("  CPI: %0.2f for the whole run, %0.2f after the boot",
                         1.0 * clocks / retires,
                         1.0 * (clocks - boot_clocks) / (retires - boot_retires));
                $display("  cache: %0d hits, %0d misses, %0.1f%%; from the flash %0d hits, %0d misses",
                         hits, misses, 100.0 * hits / (hits + misses), xip_hits, xip_misses);
                $display("  flash: %0d commands by the SPI controller, %0d by the XIP slave, %0d changes of owner, %0d streams closed",
                         spi_commands, xip_commands, owner_changes, closes);
                $display("  flash: requests waited for the pins %0d clocks at the SPI controller, %0d at the XIP slave",
                         spi_waits, xip_waits);
            end
        end
    endtask

    task run_irqmix;
        begin
            run("build/flash_irqmix.hex", "q", 1, 1);
            expect_exit("irqmix", "build/irqmix.exit");
            expect_line("irqmix", 0, ">pending 3, dma interrupts 1, uart interrupts 1, byte q, masked 1, enabled 2");
            $display("irqmix, mode %0d: printed \"%0s\", %0d external interrupts", mode,
                     output_text(), external_irqs);
        end
    endtask

    task run_irqload;
        begin
            measuring = (mode == 0);
            lat_base = 3;
            run("build/flash_irqload.hex", "", 0, 0);
            measuring = 1'b0;
            lat_base = 0;
            expect_exit("irqload", "build/irqload.exit");
            expect_line("irqload", 0, "idle: 40 ticks");
            got = $sscanf(line(1), "busy: %d ticks while the DMA engine copied 8192 bytes", v1);
            if (got != 1 || v1 + 40 != timer_irqs || line_count() != 2)
                fail($sformatf("irqload printed \"%0s\", and the core took %0d timer interrupts",
                               output_text(), timer_irqs));
            if (dma_bytes != 8192)
                fail($sformatf("irqload: the DMA engine wrote %0d bytes, not 8192", dma_bytes));
            $display("irqload, mode %0d: printed \"%0s\"", mode, output_text());
        end
    endtask

    task run_reboot;
        begin
            run("build/flash_reboot.hex", "", 0, 0);
            expect_exit("reboot", "build/second.exit");
            expect_line("reboot", 0, "image A: booting image B");
            expect_line("reboot", 1, "image B: sum 5050");
            if (line_count() != 2)
                fail($sformatf("reboot printed \"%0s\"", output_text()));
            $display("reboot, mode %0d: printed \"%0s\", stopped at %h", mode, output_text(),
                     stop_pc);
        end
    endtask

    task run_badcrc;
        begin
            run("build/flash_badcrc.hex", "", 0, 0);
            if (output_text() != "boot: bad CRC\\n" || stop_pc < ROM_BASE || stop_pc >= ROM_BASE + 1024)
                fail($sformatf("badcrc printed \"%0s\" and stopped at %h", output_text(), stop_pc));
            if (boot_clocks >= 0)
                fail("the corrupted image was fetched from the entry point");
            $display("badcrc, mode %0d: printed \"%0s\", stopped at %h", mode, output_text(),
                     stop_pc);
        end
    endtask

    task report_latency(input integer b);
        string what;
        begin
            what = b % 3 == 0 ? "the DMA engine idle" :
                   b % 3 == 1 ? "the DMA engine busy" : "a line fill from the flash";
            if (lat_count[b] > 0)
                $display("With %0s: %0d taken. Pending to taken: %0d to %0d clocks, mean %0.2f. Taken to the handler's first retire: %0d to %0d clocks, mean %0.2f",
                         what, lat_count[b], lat_min[b], lat_max[b],
                         1.0 * lat_sum[b] / lat_count[b], ent_min[b], ent_max[b],
                         1.0 * ent_sum[b] / ent_count[b]);
        end
    endtask

    initial begin
        // A waveform only with +waves, as make sim asks. Verilator ignores
        // $dumpoff, so make verilator does not ask.
        if ($test$plusargs("waves")) begin
            waves = 1'b1;
            $dumpfile("build/tb_soc.vcd");
            $dumpvars(1, tb_soc);
            $dumpvars(1, tb_soc.dut);
            $dumpvars(1, tb_soc.dut.u_flash_share);
            $dumpvars(1, tb_soc.dut.u_intc);
            $dumpvars(1, tb_soc.dut.u_dma);
            $dumpoff;
        end

        for (n = 0; n < 6; n = n + 1) begin
            lat_count[n] = 0;
            lat_sum[n] = 0;
            lat_min[n] = 1000000;
            lat_max[n] = 0;
            ent_count[n] = 0;
            ent_sum[n] = 0;
            ent_min[n] = 1000000;
            ent_max[n] = 0;
        end

        for (mode = 0; mode < 2; mode = mode + 1) begin
            $display("=== mode %0d: %0s", mode, mode == 0 ? "no stalls" : "random stalls");
            run_demo;
            run_irqmix;
            run_irqload;
            run_reboot;
            run_badcrc;
        end

        $display("=== interrupt latency in mode 0, demo.c");
        report_latency(0);
        report_latency(1);
        report_latency(2);
        $display("=== interrupt latency in mode 0, irqload.c");
        report_latency(3);
        report_latency(4);
        report_latency(5);

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
