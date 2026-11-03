`timescale 1ns/1ps

// Runs each program on the whole system, from RAM and from the XIP flash, and
// judges it by how it stopped, by gpio_out for selfmod.asm, and by counting what
// the cache did. Inputs change on the falling edge.
//
// Each run loads RAM and the flash model with $readmemh, holds reset, and runs
// until the system traps. A program in RAM starts at 0. For a program in flash,
// RAM holds only jump_to_flash.asm, which jumps to 0x4000_0000.
//
// The window. Counting starts on the clock the core first asks for the
// program's first word, so the jump from RAM is not counted, and stops when the
// system traps. In the window the testbench counts clocks, instructions, and
// every fetch: a cacheable fetch is a hit if no word was fetched on the far side
// of the cache while it waited, and a miss otherwise. A miss must fetch exactly
// CACHE_LINE_WORDS words. The cache's own counters, in wb_cachectl, must agree.
//
// Part 1 times every program from three places: RAM with no wait, RAM with
// three wait states, and the flash. It prints one RESULT line for each. Part 2
// runs the same again with every slave stalling at random, about one clock in
// four, and checks only the results. +measure skips part 2: make measure uses
// it to time other sizes of cache.
module tb_icache #(
    parameter CACHE_LINES      = 64,
    parameter CACHE_LINE_WORDS = 4,
    parameter XIP_STREAM       = 1
);

    localparam integer TIMEOUT  = 3000000;
    localparam [31:0]  XIP_BASE = 32'h4000_0000;
    localparam [0:0]   CACHED   = CACHE_LINES != 0;

    reg       clk = 1'b0;
    reg       rst = 1'b1;
    reg [4:0] hold = 5'd0;
    reg [3:0] ram_wait = 4'd0;

    wire        trap, retire;
    wire [3:0]  trap_cause;
    wire [31:0] gpio_out, retire_pc, retire_instr;
    wire        sclk, mosi, cs_n, flash_miso;

    soc #(
        .CACHE_LINES(CACHE_LINES), .CACHE_LINE_WORDS(CACHE_LINE_WORDS), .XIP_STREAM(XIP_STREAM)
    ) dut (
        .clk(clk), .rst(rst), .gpio_out(gpio_out),
        .trap(trap), .trap_cause(trap_cause),
        .retire(retire), .retire_pc(retire_pc), .retire_instr(retire_instr),
        .spi_sclk(sclk), .spi_mosi(mosi), .spi_miso(flash_miso), .spi_cs_n(cs_n),
        .hold(hold), .ram_wait(ram_wait)
    );

    // Tutorial 24's flash model, unchanged, with 64 KiB in place of 256 bytes.
    // Its file is replaced before every run.
    spi_flash_model #(
        .MEM_FILE("build/flash_tight.hex"), .MEM_BYTES(65536)
    ) u_flash (
        .cs_n(cs_n), .sclk(sclk), .mosi(mosi), .miso(flash_miso)
    );

    // MISO floats while the flash is not driving it. On a board a pull-up holds it.
    pullup (flash_miso);

    always #5 clk = ~clk;

    integer errors = 0;
    integer mode = 0;

    // ----- Random stalls, the same in both simulators -----

    reg [31:0] random = 32'h2545F491;   // xorshift32

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
        hold <= (mode == 1) ? (random[4:0] & random[9:5]) : 5'd0;
    end

    // ----- Counting, in the window -----

    reg [31:0] entry;             // the program's first word
    reg        started = 1'b0;    // the window has opened in this run
    reg        counting = 1'b0;
    integer    clocks, instrs, fetches, hits, misses, far_words, far_clocks, waiting;
    reg [31:0] hw_hits, hw_misses;

    always @(posedge clk) begin
        if (rst) begin
            counting = 1'b0;
        end else begin
            if (!started && dut.mem_valid === 1'b1 && dut.mem_instr === 1'b1
                && dut.mem_addr == entry) begin
                started    = 1'b1;
                counting   = 1'b1;
                clocks     = 0;
                instrs     = 0;
                fetches    = 0;
                hits       = 0;
                misses     = 0;
                far_words  = 0;
                far_clocks = 0;
                waiting    = 0;
                hw_hits    = dut.u_cachectl.hits;
                hw_misses  = dut.u_cachectl.misses;
            end
            if (counting && trap === 1'b1) begin
                counting  = 1'b0;
                hw_hits   = dut.u_cachectl.hits - hw_hits;
                hw_misses = dut.u_cachectl.misses - hw_misses;
            end
            if (counting) begin
                clocks = clocks + 1;
                if (retire === 1'b1)
                    instrs = instrs + 1;
                // Fetches on the far side of the cache, from RAM or the flash.
                if (dut.d_valid === 1'b1 && dut.d_instr === 1'b1)
                    far_clocks = far_clocks + 1;
                if (dut.d_valid === 1'b1 && dut.d_ready === 1'b1 && dut.d_instr === 1'b1) begin
                    far_words = far_words + 1;
                    waiting   = waiting + 1;
                end
                // A fetch the core finishes.
                if (dut.mem_valid === 1'b1 && dut.mem_ready === 1'b1 && dut.mem_instr === 1'b1) begin
                    fetches = fetches + 1;
                    if (CACHED && dut.cacheable === 1'b1) begin
                        if (waiting == 0) begin
                            hits = hits + 1;
                        end else begin
                            misses = misses + 1;
                            if (waiting != CACHE_LINE_WORDS) begin
                                $display("FAIL t=%0t a miss at %h fetched %0d words, not %0d",
                                         $time, dut.mem_addr, waiting, CACHE_LINE_WORDS);
                                errors = errors + 1;
                            end
                        end
                    end
                    waiting = 0;
                end
            end
        end
    end

    // ----- Running one program -----

    integer violations_seen = 0;

    task run(input [8*40-1:0] ram_file, input [8*40-1:0] flash_file, input [31:0] start_at,
             input [3:0] waits);
        integer n;
        begin
            @(negedge clk);
            rst      = 1'b1;
            ram_wait = waits;
            entry    = start_at;
            started  = 1'b0;
            $readmemh(ram_file, dut.u_ram.mem);
            $readmemh(flash_file, u_flash.mem);
            @(negedge clk);
            @(negedge clk);
            rst = 1'b0;
            n = 0;
            while (trap !== 1'b1 && n < TIMEOUT) begin
                @(negedge clk);
                n = n + 1;
            end
            if (trap !== 1'b1) begin
                $display("FAIL %0s: no trap after %0d clocks", ram_file, TIMEOUT);
                errors = errors + 1;
            end
            @(negedge clk);
            if (u_flash.violations != violations_seen) begin
                $display("FAIL %0s: the flash flagged %0d violations", flash_file,
                         u_flash.violations - violations_seen);
                errors = errors + 1;
                violations_seen = u_flash.violations;
            end
        end
    endtask

    // Runs one program from one place, checks how it ended, and prints a line.
    // where: 0 RAM with no wait, 1 RAM with three waits, 2 the flash.
    task run_program(input [8*10-1:0] name, input integer where);
        reg [8*40-1:0] ram_file, flash_file;
        reg [31:0]     want_gpio;
        string         extra;
        begin
            $sformat(flash_file, "build/flash_%0s.hex", name);
            if (where == 2)
                ram_file = "build/jump_to_flash.hex";
            else
                $sformat(ram_file, "build/%0s.hex", name);
            run(ram_file, flash_file, where == 2 ? XIP_BASE : 32'd0, where == 1 ? 4'd3 : 4'd0);

            if (trap !== 1'b1 || trap_cause !== 4'd3) begin
                $display("FAIL %0s from %0s: stopped with cause %0d at pc %h, not ebreak",
                         name, where == 2 ? "flash" : "RAM", trap_cause, retire_pc);
                errors = errors + 1;
            end
            if (name == "selfmod") begin
                want_gpio = CACHED ? 32'h0002_0101 : 32'h0002_0201;
                if (gpio_out !== want_gpio) begin
                    $display("FAIL selfmod left gpio_out at %h, not %h", gpio_out, want_gpio);
                    errors = errors + 1;
                end
            end
            if (CACHED && (hw_hits != hits || hw_misses != misses)) begin
                $display("FAIL %0s: the cache counted %0d hits and %0d misses, the testbench %0d and %0d",
                         name, hw_hits, hw_misses, hits, misses);
                errors = errors + 1;
            end
            if (!started || instrs == 0) begin
                $display("FAIL %0s: the program's first word was never fetched", name);
                errors = errors + 1;
            end
            extra = "";
            if (name == "selfmod")
                extra = $sformatf("  gpio %h", gpio_out);
            if (mode == 0)
                $display("RESULT %0d x %0d %0s  %-8s %-5s %8d clocks %5d instrs  CPI %7.2f  hits %5d misses %4d  hit rate %6.2f%%  far words %5d  clocks/word %6.2f%0s",
                         CACHE_LINES, CACHE_LINE_WORDS, XIP_STREAM ? "stream" : "single",
                         name, where == 0 ? "ram0" : where == 1 ? "ram3" : "xip",
                         clocks, instrs, 1.0 * clocks / instrs, hits, misses,
                         (hits + misses != 0) ? 100.0 * hits / (hits + misses) : 0.0,
                         far_words, (far_words != 0) ? 1.0 * far_clocks / far_words : 0.0, extra);
            else
                $display("mode 1  %-8s %-5s  ended with cause %0d at pc %h%0s", name,
                         where == 2 ? "flash" : "RAM", trap_cause, retire_pc, extra);
        end
    endtask

    task all_programs(input integer first, input integer last, input integer step);
        integer where;
        begin
            for (where = first; where <= last; where = where + step) begin
                run_program("tight", where);
                if (where == 2 && mode == 0)
                    $dumpoff;          // the waveform keeps only the first run
                run_program("straight", where);
                run_program("bigloop", where);
                run_program("selfmod", where);
            end
        end
    endtask

    initial begin
        // A waveform only when asked for with +waves, as make sim does. It keeps
        // only the first run, tight.asm from the flash, and only the signals the
        // README walks through, one level each. Verilator ignores $dumpoff, so
        // make verilator does not ask.
        if ($test$plusargs("waves")) begin
            $dumpfile("build/tb_icache.vcd");
            $dumpvars(1, tb_icache);
            $dumpvars(1, tb_icache.dut);
            if (CACHED)
                $dumpvars(1, tb_icache.dut.g_cache.u_icache);
        end

        $display("=== %0d lines of %0d words, flash reads %0s", CACHE_LINES, CACHE_LINE_WORDS,
                 XIP_STREAM ? "streamed" : "one word per command");
        mode = 0;
        // The flash first, so that the waveform is tight.asm from the flash.
        all_programs(2, 2, 1);
        all_programs(0, 1, 1);

        if (!$test$plusargs("measure")) begin
            $display("=== mode 1: every slave stalls at random");
            mode = 1;
            all_programs(0, 2, 2);
            mode = 0;
        end

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
