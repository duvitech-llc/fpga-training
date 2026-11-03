`timescale 1ns/1ps

// The top level for the cocotb test: the system, Tutorial 24's flash model with
// 64 KiB, and the pull-up on MISO, as in tb_icache.v. The cache is small, 8
// lines of 4 words, 128 bytes, so that the test's programs do not fit in it and
// lines are replaced all the time.
module cache_top #(
    parameter CACHE_LINES      = 8,
    parameter CACHE_LINE_WORDS = 4
) (
    input  wire       clk,
    input  wire       rst,
    input  wire [4:0] hold,
    input  wire [3:0] ram_wait
);

    wire        trap, retire;
    wire [3:0]  trap_cause;
    wire [31:0] gpio_out, retire_pc, retire_instr;
    wire        sclk, mosi, cs_n, flash_miso;

    soc #(
        .CACHE_LINES(CACHE_LINES), .CACHE_LINE_WORDS(CACHE_LINE_WORDS)
    ) u_soc (
        .clk(clk), .rst(rst), .gpio_out(gpio_out),
        .trap(trap), .trap_cause(trap_cause),
        .retire(retire), .retire_pc(retire_pc), .retire_instr(retire_instr),
        .spi_sclk(sclk), .spi_mosi(mosi), .spi_miso(flash_miso), .spi_cs_n(cs_n),
        .hold(hold), .ram_wait(ram_wait)
    );

    // The test writes the image it wants into u_flash.mem before each run.
    spi_flash_model #(
        .MEM_FILE("../build/flash_tight.hex"), .MEM_BYTES(65536)
    ) u_flash (
        .cs_n(cs_n), .sclk(sclk), .mosi(mosi), .miso(flash_miso)
    );

    pullup (flash_miso);

endmodule
