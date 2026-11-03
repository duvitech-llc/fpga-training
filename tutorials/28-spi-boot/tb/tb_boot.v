`timescale 1ns/1ps

// Boots the system from the SPI flash model, and judges each boot by what comes
// out: the bytes on uart_tx, decoded at bit level as in Tutorial 26, how it
// stopped, and whether the flash model saw a broken rule. Inputs change on the
// falling edge.
//
// Each run loads a boot ROM and a flash image with $readmemh, holds reset, and
// runs until the system traps. The ROMs and images come from make: one ROM per
// SPI divider and per way of reading (rom/getbyte_stream.asm or
// rom/getbyte_poll.asm), and one image per payload or fault (tools/mkflash.py).
//
// Part 1 runs every check twice. Mode 0 holds every slave's hold input low.
// Mode 1 drives them from a pseudo-random sequence, so every slave stalls at
// random. Part 2 times boots in mode 0: clocks from the end of reset to the
// first fetch from the entry point, for each divider, both ROMs, and two sizes
// of payload.
module tb_boot #(
    parameter CLKS_PER_BIT = 16
);

    localparam integer TIMEOUT    = 3000000;   // clocks for one boot and its program
    localparam integer FRAME      = 10 * CLKS_PER_BIT;
    localparam integer MAX_OUTPUT = 256;
    localparam [31:0]  ROM_BASE   = 32'h0010_0000;
    localparam [31:0]  ROM_END    = 32'h0010_0400;
    localparam [31:0]  ENTRY      = 32'h0000_1000;   // mkflash.py's default

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg uart_rx = 1'b1;
    reg [9:0] hold = 10'd0;

    wire        uart_tx, trap, retire;
    wire [3:0]  trap_cause;
    wire [31:0] gpio_out, retire_pc, retire_instr;
    wire        sclk, mosi, cs_n, flash_miso;

    soc #(.CLKS_PER_BIT(CLKS_PER_BIT)) dut (
        .clk(clk), .rst(rst), .uart_rx(uart_rx), .uart_tx(uart_tx), .gpio_out(gpio_out),
        .trap(trap), .trap_cause(trap_cause),
        .retire(retire), .retire_pc(retire_pc), .retire_instr(retire_instr),
        .spi_sclk(sclk), .spi_mosi(mosi), .spi_miso(flash_miso), .spi_cs_n(cs_n),
        .hold(hold)
    );

    // Tutorial 24's flash model, unchanged, with 64 KiB in place of 256 bytes.
    // Its file is replaced before every boot.
    spi_flash_model #(
        .MEM_FILE("build/flash_hello.hex"), .MEM_BYTES(65536)
    ) u_flash (
        .cs_n(cs_n), .sclk(sclk), .mosi(mosi), .miso(flash_miso)
    );

    // MISO floats while the flash is not driving it. On a board a pull-up
    // holds it high, so the bytes that come back during a command are FF.
    pullup (flash_miso);

    always #5 clk = ~clk;

    integer errors = 0;
    integer mode = 0;
    integer n;

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
        // Each slave stalls on about one clock in four.
        hold <= (mode == 1) ? (random[9:0] & random[19:10]) : 10'd0;
    end

    // ----- The UART decoder, from Tutorial 26 -----

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
            else if (uart_tx !== bit_level) begin
                $display("FAIL t=%0t uart_tx changed inside bit %0d", $time, frame_bit);
                errors = errors + 1;
            end
            bit_clock = bit_clock + 1;
        end

        if (frame_bit != -1 && bit_clock == CLKS_PER_BIT) begin
            if (frame_bit >= 1 && frame_bit <= 8)
                frame_data[frame_bit - 1] = bit_level;
            if (frame_bit == 9) begin
                if (bit_level !== 1'b1) begin
                    $display("FAIL t=%0t stop bit on uart_tx is low", $time);
                    errors = errors + 1;
                end
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

    // ----- Boot time: clocks from the end of reset to the first fetch of ENTRY -----

    integer clocks_since_reset = 0;
    integer boot_clocks = -1;           // -1: not booted yet
    integer spi_bytes = 0;              // bytes on the wire, counted from SCLK edges
    integer sclk_edges = 0;
    reg     sclk_q = 1'b0;

    always @(posedge clk) begin
        if (rst) begin
            clocks_since_reset = 0;
            boot_clocks = -1;
            sclk_edges = 0;
        end else begin
            clocks_since_reset = clocks_since_reset + 1;
            if (boot_clocks < 0 && dut.mem_valid === 1'b1 && dut.mem_instr === 1'b1
                && dut.mem_addr == ENTRY)
                boot_clocks = clocks_since_reset;
            if (cs_n === 1'b0 && sclk !== sclk_q)
                sclk_edges = sclk_edges + 1;
        end
        sclk_q = sclk;
    end

    // ----- Running one boot -----

    integer violations_seen = 0;

    task boot(input [8*40-1:0] rom, input [8*40-1:0] flash);
        integer clocks;
        begin
            @(negedge clk);
            rst = 1'b1;
            $readmemh(rom, dut.u_rom.mem);
            $readmemh(flash, u_flash.mem);
            out_count = 0;
            @(negedge clk);
            @(negedge clk);
            rst = 1'b0;
            clocks = 0;
            while (trap !== 1'b1 && clocks < TIMEOUT) begin
                @(negedge clk);
                clocks = clocks + 1;
            end
            if (trap !== 1'b1) begin
                $display("FAIL %0s with %0s: no trap after %0d clocks", rom, flash, TIMEOUT);
                errors = errors + 1;
            end
            // Let the UART finish the frame it may be sending.
            repeat (2 * FRAME) @(negedge clk);
            spi_bytes = sclk_edges / 16;
            if (u_flash.violations != violations_seen) begin
                $display("FAIL %0s with %0s: the flash flagged %0d violations", rom, flash,
                         u_flash.violations - violations_seen);
                errors = errors + 1;
                violations_seen = u_flash.violations;
            end
        end
    endtask

    // The output as text, for messages.
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

    // Did the boot print exactly want, and nothing else?
    function automatic printed(input string want);
        integer j;
        begin
            printed = (out_count == want.len());
            for (j = 0; j < want.len() && printed; j = j + 1)
                if (out[j] != want[j])
                    printed = 1'b0;
        end
    endfunction

    // Checks one boot: the text, the trap cause, and where it stopped. where is
    // 0 for RAM, the payload's own ebreak or fault, and 1 for the boot ROM's halt.
    task check(input string what, input string want, input [3:0] cause, input integer where);
        reg in_rom;
        begin
            in_rom = retire_pc >= ROM_BASE && retire_pc < ROM_END;
            if (!printed(want)) begin
                $display("FAIL %0s printed \"%0s\"", what, output_text());
                errors = errors + 1;
            end
            if (trap !== 1'b1 || trap_cause !== cause) begin
                $display("FAIL %0s stopped with trap=%b cause=%0d, not cause %0d", what, trap,
                         trap_cause, cause);
                errors = errors + 1;
            end
            if (in_rom != (where == 1)) begin
                $display("FAIL %0s stopped at pc %h, %0s", what, retire_pc,
                         where == 1 ? "not in the boot ROM" : "in the boot ROM");
                errors = errors + 1;
            end
            $display("%-26s mode %0d: printed \"%0s\", trap cause %0d at pc %h", what, mode,
                     output_text(), trap_cause, retire_pc);
        end
    endtask

    task run_checks;
        begin
            boot("build/rom_stream_d1.hex", "build/flash_hello.hex");
            check("hello, streaming", "Hello from flash!\n", 4'd3, 0);
            if (mode == 0)
                $display("  booted in %0d clocks, %0d bytes on the SPI wire", boot_clocks, spi_bytes);
            // The waveform keeps only this first boot, which keeps the file small.
            $dumpoff;

            boot("build/rom_poll_d1.hex", "build/flash_hello.hex");
            check("hello, polling", "Hello from flash!\n", 4'd3, 0);

            boot("build/rom_stream_d1.hex", "build/flash_bitflip.hex");
            check("one bit flipped", "boot: bad CRC\n", 4'd3, 1);
            if (boot_clocks >= 0) begin
                $display("FAIL the corrupted image was fetched from the entry point");
                errors = errors + 1;
            end

            boot("build/rom_stream_d1.hex", "build/flash_magic.hex");
            check("bad magic", "boot: bad magic\n", 4'd3, 1);

            boot("build/rom_stream_d1.hex", "build/flash_length.hex");
            check("bad length", "boot: bad length\n", 4'd3, 1);

            boot("build/rom_poll_d1.hex", "build/flash_bitflip.hex");
            check("one bit flipped, polling", "boot: bad CRC\n", 4'd3, 1);

            boot("build/rom_stream_d1.hex", "build/flash_again.hex");
            check("boot twice", "Hello again!\nHello again!\n", 4'd3, 0);
            if (gpio_out !== 32'd2) begin
                $display("FAIL boot twice left gpio_out at %h, not 2", gpio_out);
                errors = errors + 1;
            end

            boot("build/rom_stream_d1.hex", "build/flash_romwrite.hex");
            check("store to the boot ROM", "write to the boot ROM\n", 4'd7, 0);
            if (retire_instr !== 32'h000E_2023) begin
                $display("FAIL the store fault was at instr %h, not 000e2023", retire_instr);
                errors = errors + 1;
            end
        end
    endtask

    // ----- Part 2: boot time against the divider -----

    localparam integer NDIVS = 4;
    integer divs [0:NDIVS-1];
    integer small_bytes, big_bytes;

    function integer payload_length(input integer dummy);
        payload_length = {u_flash.mem[7], u_flash.mem[6], u_flash.mem[5], u_flash.mem[4]};
    endfunction

    task time_boots;
        integer d, way, clocks_small, clocks_big, wire_small, wire_big;
        reg [8*40-1:0] rom;
        begin
            $display("Boot time: clocks from the end of reset to the first fetch of the payload");
            $display("  divider  SCLK      ROM        %0d-byte payload  %0d-byte payload  clocks per byte",
                     small_bytes, big_bytes);
            for (d = 0; d < NDIVS; d = d + 1)
                for (way = 0; way < 2; way = way + 1) begin
                    if (way == 0)
                        $sformat(rom, "build/rom_stream_d%0d.hex", divs[d]);
                    else
                        $sformat(rom, "build/rom_poll_d%0d.hex", divs[d]);
                    boot(rom, "build/flash_hello.hex");
                    check(way == 0 ? "hello, streaming" : "hello, polling",
                          "Hello from flash!\n", 4'd3, 0);
                    clocks_small = boot_clocks;
                    wire_small = spi_bytes;
                    boot(rom, "build/flash_big.hex");
                    check(way == 0 ? "big, streaming" : "big, polling",
                          "Hello from flash!\n", 4'd3, 0);
                    clocks_big = boot_clocks;
                    wire_big = spi_bytes;
                    $display("RESULT div %2d  clk/%-3d  %0s  %8d clocks  %8d clocks  %6.2f  (%0d and %0d bytes on the wire)",
                             divs[d], 2 * (divs[d] + 1), way == 0 ? "streaming" : "polling  ",
                             clocks_small, clocks_big, 1.0 * (clocks_big - clocks_small) / (big_bytes - small_bytes),
                             wire_small, wire_big);
                end
        end
    endtask

    initial begin
        // A waveform only when asked for with +waves, as make sim does. It keeps
        // only the first boot, and only the signals the README walks through,
        // one level each. Verilator ignores $dumpoff, and recorded every boot,
        // 2.5 GB, so make verilator does not ask.
        if ($test$plusargs("waves")) begin
            $dumpfile("build/tb_boot.vcd");
            $dumpvars(1, tb_boot);
            $dumpvars(1, tb_boot.dut);
            $dumpvars(1, tb_boot.dut.u_spi);
        end

        divs[0] = 1;
        divs[1] = 3;
        divs[2] = 7;
        divs[3] = 15;

        for (mode = 0; mode < 2; mode = mode + 1) begin
            $display("=== mode %0d: %0s", mode, mode == 0 ? "no stalls" : "random stalls");
            run_checks;
        end

        mode = 0;
        $readmemh("build/flash_hello.hex", u_flash.mem);
        small_bytes = payload_length(0);
        $readmemh("build/flash_big.hex", u_flash.mem);
        big_bytes = payload_length(0);
        time_boots;

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
