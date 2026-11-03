`timescale 1ns/1ps

// The top level for the cocotb test: the system, Tutorial 24's flash model with
// 64 KiB, and the pull-up on MISO, as tb_soc.v wires them. The test writes the
// boot ROM and the flash it wants through the simulator before each run.
module soc_top #(
    parameter CLKS_PER_BIT = 16
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        uart_rx,
    output wire        uart_tx,
    input  wire [14:0] hold
);

    wire        trap, retire;
    wire [31:0] trap_cause, gpio_out, retire_pc, retire_instr;
    wire        sclk, mosi, cs_n, flash_miso;

    soc #(.CLKS_PER_BIT(CLKS_PER_BIT), .ROM_INIT("../build/boot.hex")) u_soc (
        .clk(clk), .rst(rst), .uart_rx(uart_rx), .uart_tx(uart_tx), .gpio_out(gpio_out),
        .spi_sclk(sclk), .spi_mosi(mosi), .spi_miso(flash_miso), .spi_cs_n(cs_n),
        .trap(trap), .trap_cause(trap_cause),
        .retire(retire), .retire_pc(retire_pc), .retire_instr(retire_instr),
        .hold(hold)
    );

    spi_flash_model #(
        .MEM_FILE("../build/flash_demo.hex"), .MEM_BYTES(65536)
    ) u_flash (
        .cs_n(cs_n), .sclk(sclk), .mosi(mosi), .miso(flash_miso)
    );

    pullup (flash_miso);

endmodule
