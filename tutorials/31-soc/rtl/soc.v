// A small system-on-chip: everything from Tutorials 26 to 30 in one system.
//
//   rv32i --native--> icache --native--> rv_wb_bridge --cpu_*--> +------------+
//   +CSRs               ^  |                                     | wb_arbiter |--m_*--> wb_interconnect
//     ^  ^              |  +-- hit, miss --> wb_cachectl         | (Tut. 29)  |          |
//     |  |              +----- invalidate <- wb_cachectl         |            |          +--> wb_ram          RAM, 64 KiB
//     |  |                                 wb_dma master -dma_*->+------------+          +--> wb_uart  -------------+ irq
//     |  |                                                                               +--> wb_gpio                 |
//     |  |                                                                               +--> wb_counters             |
//     |  |                                                                               +--> wb_axil_bridge --> axil_regs
//     |  +-- irq_timer <------------------------------------------------- wb_timer <-----+                           |
//     |                                                                                  +--> wb_rom          boot ROM
//     |                                                       flash_share <-- wb_gate <--+--> wb_spi  --+             |
//     |                                                        |  ^  ^                   +--> wb_crc    |             |
//     |                                                        |  |  +--- wb_gate <------+--> wb_xip  --+--> pins     |
//     |                                                        |  +----------------------+--> wb_dma (registers)      |
//     |                                                        +--> SPI flash pins       +--> wb_cachectl             |
//     +-- irq_external <-------------------------------------------- wb_intc <------------+    <-- dma done/error, uart irq
//
// The core is Tutorial 27's, with machine mode, traps and interrupts. Tutorial
// 30's cache sits between it and Tutorial 26's bridge. Tutorial 29's arbiter
// shares the bus between the core and the DMA engine. The memory map is in
// soc_map.vh. Reset starts at the boot ROM, which copies the program from the
// flash into RAM, as in Tutorial 28.
//
// Bus errors become traps, as in Tutorial 27: the bridge's mem_err goes to the
// core, through the cache, which takes an access fault, mcause 1, 5 or 7. An err
// to the DMA engine sets its ERROR bit instead.
//
// Interrupts: the timer's line goes straight to MTIP. The UART's and the DMA
// engine's share MEIP, through wb_intc.
//
// The flash: wb_spi and wb_xip each have an SPI master. flash_share gives the
// pins to one at a time, and holds back the other's requests until then.
//
// For Tutorial 33: a display controller that reads a framebuffer is a third bus
// master. It would be master 2 of wb_arbiter, which Tutorial 29 proved with
// three masters. soc_map.vh leaves its regions free.
module soc #(
    parameter        CLKS_PER_BIT     = 16,
    parameter        INIT             = "",   // the RAM, for $readmemh, or "" for none
    parameter        ROM_INIT         = "",   // the boot ROM, for $readmemh
    parameter        CACHE_LINES      = 64,
    parameter        CACHE_LINE_WORDS = 4,
    parameter [7:0]  XIP_DIV          = 8'd1  // SCLK is clk / (2 * (XIP_DIV + 1))
) (
    input  wire        clk,
    input  wire        rst,        // synchronous, active high
    input  wire        uart_rx,    // asynchronous: the UART synchronizes it
    output wire        uart_tx,
    output wire [31:0] gpio_out,
    // The SPI flash
    output wire        spi_sclk,
    output wire        spi_mosi,
    input  wire        spi_miso,
    output wire        spi_cs_n,
    // The core's, passed on for testbenches
    output wire        trap,       // high in the clock a trap is taken
    output wire [31:0] trap_cause, // its mcause
    output wire        retire,
    output wire [31:0] retire_pc,
    output wire [31:0] retire_instr,
    // For testing only: each bit makes one slave stall on this clock. 0 RAM,
    // 1 UART, 2 GPIO, 3 counters, 6 to 4 axil_regs' hold, 7 timer, 8 boot ROM,
    // 9 SPI, 10 CRC, 11 DMA registers, 12 cache control, 13 XIP, 14 interrupt
    // control. Tie to 0.
    input  wire [14:0] hold
);

`include "soc_map.vh"

    // ----- The core, Tutorial 27's -----

    wire        mem_valid, mem_instr, mem_ready, mem_err;
    wire [31:0] mem_addr, mem_wdata, mem_rdata;
    wire [3:0]  mem_wstrb;
    wire        irq_timer, irq_external;

    rv32i #(.RESET_ADDR(SOC_ROM_BASE)) u_core (
        .clk(clk), .rst(rst),
        .mem_valid(mem_valid), .mem_instr(mem_instr), .mem_ready(mem_ready),
        .mem_err(mem_err),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),
        .irq_timer(irq_timer), .irq_external(irq_external),
        .trap(trap), .trap_cause(trap_cause),
        .retire(retire), .retire_pc(retire_pc), .retire_instr(retire_instr)
    );

    // ----- The instruction cache, Tutorial 30's -----

    // RAM, the boot ROM and the flash: their words change only when written.
    wire cacheable = (mem_addr & SOC_RAM_MASK) == SOC_RAM_BASE
                  || (mem_addr & SOC_ROM_MASK) == SOC_ROM_BASE
                  || (mem_addr & SOC_XIP_MASK) == SOC_XIP_BASE;

    wire        d_valid, d_instr, d_ready, d_err;
    wire [31:0] d_addr, d_wdata, d_rdata;
    wire [3:0]  d_wstrb;
    wire        invalidate, cache_hit, cache_miss;

    // rv_wb_bridge has no use for d_instr: Wishbone does not tell fetches apart.
    wire        unused_d_instr = &{1'b0, d_instr};

    icache #(.LINES(CACHE_LINES), .LINE_WORDS(CACHE_LINE_WORDS)) u_icache (
        .clk(clk), .rst(rst),
        .mem_valid(mem_valid), .mem_instr(mem_instr), .mem_ready(mem_ready),
        .mem_err(mem_err), .mem_addr(mem_addr), .mem_wdata(mem_wdata),
        .mem_wstrb(mem_wstrb), .mem_rdata(mem_rdata),
        .cacheable(cacheable), .invalidate(invalidate),
        .d_valid(d_valid), .d_instr(d_instr), .d_ready(d_ready), .d_err(d_err),
        .d_addr(d_addr), .d_wdata(d_wdata), .d_wstrb(d_wstrb), .d_rdata(d_rdata),
        .hit(cache_hit), .miss(cache_miss)
    );

    // ----- Master 0: the core, through Tutorial 26's bridge -----

    wire        cpu_cyc, cpu_stb, cpu_we, cpu_ack, cpu_err, cpu_stall;
    wire [29:0] cpu_adr;
    wire [3:0]  cpu_sel;
    wire [31:0] cpu_dat_w, bus_dat_r;

    rv_wb_bridge u_bridge (
        .clk(clk), .rst(rst),
        .mem_valid(d_valid), .mem_ready(d_ready), .mem_err(d_err),
        .mem_addr(d_addr), .mem_wdata(d_wdata), .mem_wstrb(d_wstrb),
        .mem_rdata(d_rdata),
        .cyc(cpu_cyc), .stb(cpu_stb), .we(cpu_we), .adr(cpu_adr), .sel(cpu_sel),
        .dat_w(cpu_dat_w), .ack(cpu_ack), .err(cpu_err), .stall(cpu_stall), .dat_r(bus_dat_r)
    );

    // ----- The interconnect's slave side, used by the DMA engine's registers -----

    wire                     s_cyc, s_we;
    wire [SOC_SLAVES-1:0]    s_stb, s_ack, s_err, s_stall;
    wire [3:0]               s_sel;
    wire [31:0]              s_dat_w;
    wire [32*SOC_SLAVES-1:0] s_dat_r;
    // Each slave decodes only the low bits it needs. The interconnect has checked the rest.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [29:0]              s_adr;
    /* verilator lint_on UNUSEDSIGNAL */

    // ----- Master 1: the DMA engine, Tutorial 29's -----

    wire        dma_cyc, dma_stb, dma_we, dma_ack, dma_err, dma_stall;
    wire [29:0] dma_adr;
    wire [3:0]  dma_sel;
    wire [31:0] dma_dat_w;
    wire        dma_busy, dma_done, dma_error;
    wire        uart_tx_ready, uart_irq;

    wb_dma u_dma (
        .clk(clk), .rst(rst),
        .s_cyc(s_cyc), .s_stb(s_stb[9]), .s_we(s_we), .s_adr(s_adr[2:0]), .s_sel(s_sel),
        .s_dat_w(s_dat_w), .s_ack(s_ack[9]), .s_err(s_err[9]), .s_stall(s_stall[9]),
        .s_dat_r(s_dat_r[9*32 +: 32]), .hold(hold[11]),
        .m_cyc(dma_cyc), .m_stb(dma_stb), .m_we(dma_we), .m_adr(dma_adr), .m_sel(dma_sel),
        .m_dat_w(dma_dat_w), .m_ack(dma_ack), .m_err(dma_err), .m_stall(dma_stall),
        .m_dat_r(bus_dat_r),
        .dreq(uart_tx_ready),
        .busy(dma_busy), .done(dma_done), .error(dma_error)
    );

    // busy is STATUS bit 0, read over the bus. Nothing else here needs the wire.
    wire unused_dma_busy = &{1'b0, dma_busy};

    // ----- The arbiter: master 0 the core, master 1 the DMA engine -----

    wire        m_cyc, m_stb, m_we, m_ack, m_err, m_stall;
    wire [29:0] m_adr;
    wire [3:0]  m_sel;
    wire [31:0] m_dat_w, m_dat_r;

    wb_arbiter #(.N(2)) u_arbiter (
        .clk(clk), .rst(rst),
        .m_cyc({dma_cyc, cpu_cyc}), .m_stb({dma_stb, cpu_stb}), .m_we({dma_we, cpu_we}),
        .m_adr({dma_adr, cpu_adr}), .m_sel({dma_sel, cpu_sel}), .m_dat_w({dma_dat_w, cpu_dat_w}),
        .m_ack({dma_ack, cpu_ack}), .m_err({dma_err, cpu_err}), .m_stall({dma_stall, cpu_stall}),
        .m_dat_r(bus_dat_r),
        .s_cyc(m_cyc), .s_stb(m_stb), .s_we(m_we), .s_adr(m_adr), .s_sel(m_sel),
        .s_dat_w(m_dat_w), .s_ack(m_ack), .s_err(m_err), .s_stall(m_stall), .s_dat_r(m_dat_r)
    );

    // ----- The interconnect -----

    wb_interconnect #(
        .N(SOC_SLAVES), .BASE(SOC_BASE), .MASK(SOC_MASK)
    ) u_interconnect (
        .clk(clk), .rst(rst),
        .m_cyc(m_cyc), .m_stb(m_stb), .m_we(m_we), .m_adr(m_adr), .m_sel(m_sel),
        .m_dat_w(m_dat_w), .m_ack(m_ack), .m_err(m_err), .m_stall(m_stall), .m_dat_r(m_dat_r),
        .s_cyc(s_cyc), .s_stb(s_stb), .s_we(s_we), .s_adr(s_adr), .s_sel(s_sel),
        .s_dat_w(s_dat_w), .s_ack(s_ack), .s_err(s_err), .s_stall(s_stall), .s_dat_r(s_dat_r)
    );

    // ----- Slaves 0 to 5, as in Tutorial 27 -----

    wb_ram #(.AW(14), .INIT(INIT)) u_ram (
        .clk(clk), .rst(rst),
        .cyc(s_cyc), .stb(s_stb[0]), .we(s_we), .adr(s_adr[13:0]), .sel(s_sel),
        .dat_w(s_dat_w), .ack(s_ack[0]), .err(s_err[0]), .stall(s_stall[0]),
        .dat_r(s_dat_r[0*32 +: 32]), .hold(hold[0])
    );

    wb_uart #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart (
        .clk(clk), .rst(rst),
        .cyc(s_cyc), .stb(s_stb[1]), .we(s_we), .adr(s_adr[0]), .sel(s_sel),
        .dat_w(s_dat_w), .ack(s_ack[1]), .err(s_err[1]), .stall(s_stall[1]),
        .dat_r(s_dat_r[1*32 +: 32]), .hold(hold[1]),
        .tx(uart_tx), .rx(uart_rx), .irq(uart_irq), .tx_ready(uart_tx_ready)
    );

    wb_gpio u_gpio (
        .clk(clk), .rst(rst),
        .cyc(s_cyc), .stb(s_stb[2]), .we(s_we), .sel(s_sel),
        .dat_w(s_dat_w), .ack(s_ack[2]), .err(s_err[2]), .stall(s_stall[2]),
        .dat_r(s_dat_r[2*32 +: 32]), .hold(hold[2]),
        .gpio_out(gpio_out)
    );

    wb_counters u_counters (
        .clk(clk), .rst(rst),
        .cyc(s_cyc), .stb(s_stb[3]), .we(s_we), .adr(s_adr[0]),
        .ack(s_ack[3]), .err(s_err[3]), .stall(s_stall[3]),
        .dat_r(s_dat_r[3*32 +: 32]), .hold(hold[3]),
        .retire(retire)
    );

    wire        awvalid, awready, wvalid, wready, bvalid, bready;
    wire        arvalid, arready, rvalid, rready;
    wire [31:0] awaddr, wdata, araddr, rdata;
    wire [3:0]  wstrb;
    wire [2:0]  awprot, arprot;
    wire [1:0]  bresp, rresp;

    wb_axil_bridge u_axil_bridge (
        .clk(clk), .rst(rst),
        .cyc(s_cyc), .stb(s_stb[4]), .we(s_we), .adr(s_adr), .sel(s_sel),
        .dat_w(s_dat_w), .ack(s_ack[4]), .err(s_err[4]), .stall(s_stall[4]),
        .dat_r(s_dat_r[4*32 +: 32]),
        .awvalid(awvalid), .awready(awready), .awaddr(awaddr), .awprot(awprot),
        .wvalid(wvalid), .wready(wready), .wdata(wdata), .wstrb(wstrb),
        .bvalid(bvalid), .bready(bready), .bresp(bresp),
        .arvalid(arvalid), .arready(arready), .araddr(araddr), .arprot(arprot),
        .rvalid(rvalid), .rready(rready), .rdata(rdata), .rresp(rresp)
    );

    axil_regs #(.BASE(SOC_AXIL_BASE)) u_axil_regs (
        .clk(clk), .rst(rst),
        .awvalid(awvalid), .awready(awready), .awaddr(awaddr), .awprot(awprot),
        .wvalid(wvalid), .wready(wready), .wdata(wdata), .wstrb(wstrb),
        .bvalid(bvalid), .bready(bready), .bresp(bresp),
        .arvalid(arvalid), .arready(arready), .araddr(araddr), .arprot(arprot),
        .rvalid(rvalid), .rready(rready), .rdata(rdata), .rresp(rresp),
        .hold(hold[6:4])
    );

    wb_timer u_timer (
        .clk(clk), .rst(rst),
        .cyc(s_cyc), .stb(s_stb[5]), .we(s_we), .adr(s_adr[1:0]), .sel(s_sel),
        .dat_w(s_dat_w), .ack(s_ack[5]), .err(s_err[5]), .stall(s_stall[5]),
        .dat_r(s_dat_r[5*32 +: 32]), .hold(hold[7]),
        .irq(irq_timer)
    );

    // ----- Slaves 6 to 8, from Tutorial 28 -----

    wb_rom #(.AW(8), .INIT(ROM_INIT)) u_rom (
        .clk(clk), .rst(rst),
        .cyc(s_cyc), .stb(s_stb[6]), .we(s_we), .adr(s_adr[7:0]),
        .ack(s_ack[6]), .err(s_err[6]), .stall(s_stall[6]),
        .dat_r(s_dat_r[6*32 +: 32]), .hold(hold[8])
    );

    // The SPI controller and the XIP slave, each behind a gate that holds its
    // requests back until it owns the flash's pins.
    wire spi_go, xip_go, xip_close, spi_busy;
    wire spi_cyc, spi_stb, spi_stall;
    wire xip_cyc, xip_stb, xip_stall, xip_ack;
    wire spi_sclk_c, spi_mosi_c, spi_cs_n_c;
    wire xip_sclk_c, xip_mosi_c, xip_cs_n_c;
    wire spi_ack_w, spi_err_w, xip_err_w;

    wb_gate u_spi_gate (
        .go(spi_go),
        .m_cyc(s_cyc), .m_stb(s_stb[SOC_S_SPI]), .m_stall(s_stall[SOC_S_SPI]),
        .m_ack(s_ack[SOC_S_SPI]), .m_err(s_err[SOC_S_SPI]),
        .s_cyc(spi_cyc), .s_stb(spi_stb), .s_stall(spi_stall),
        .s_ack(spi_ack_w), .s_err(spi_err_w)
    );


    wb_spi u_spi (
        .clk(clk), .rst(rst),
        .cyc(spi_cyc), .stb(spi_stb), .we(s_we), .adr(s_adr[2:0]), .sel(s_sel),
        .dat_w(s_dat_w), .ack(spi_ack_w), .err(spi_err_w), .stall(spi_stall),
        .dat_r(s_dat_r[SOC_S_SPI*32 +: 32]), .hold(hold[9]),
        .sclk(spi_sclk_c), .mosi(spi_mosi_c), .miso(spi_miso), .cs_n(spi_cs_n_c),
        .busy(spi_busy)
    );

    wb_crc u_crc (
        .clk(clk), .rst(rst),
        .cyc(s_cyc), .stb(s_stb[8]), .we(s_we), .adr(s_adr[1:0]), .sel(s_sel),
        .dat_w(s_dat_w), .ack(s_ack[8]), .err(s_err[8]), .stall(s_stall[8]),
        .dat_r(s_dat_r[8*32 +: 32]), .hold(hold[10])
    );

    // ----- Slaves 10 and 12, from Tutorial 30 -----

    wb_cachectl u_cachectl (
        .clk(clk), .rst(rst),
        .cyc(s_cyc), .stb(s_stb[10]), .we(s_we), .adr(s_adr[1:0]),
        .ack(s_ack[10]), .err(s_err[10]), .stall(s_stall[10]),
        .dat_r(s_dat_r[10*32 +: 32]), .hold(hold[12]),
        .invalidate(invalidate), .hit(cache_hit), .miss(cache_miss)
    );


    wb_gate u_xip_gate (
        .go(xip_go),
        .m_cyc(s_cyc), .m_stb(s_stb[SOC_S_XIP]), .m_stall(s_stall[SOC_S_XIP]),
        .m_ack(s_ack[SOC_S_XIP]), .m_err(s_err[SOC_S_XIP]),
        .s_cyc(xip_cyc), .s_stb(xip_stb), .s_stall(xip_stall),
        .s_ack(xip_ack), .s_err(xip_err_w)
    );

    wb_xip #(.STREAM(1), .DIV(XIP_DIV)) u_xip (
        .clk(clk), .rst(rst || xip_close),
        .cyc(xip_cyc), .stb(xip_stb), .we(s_we), .adr(s_adr[21:0]),
        .ack(xip_ack), .err(xip_err_w), .stall(xip_stall),
        .dat_r(s_dat_r[SOC_S_XIP*32 +: 32]), .hold(hold[13]),
        .sclk(xip_sclk_c), .mosi(xip_mosi_c), .miso(spi_miso), .cs_n(xip_cs_n_c)
    );

    // ----- The flash's owner, new -----

    flash_share u_flash_share (
        .clk(clk), .rst(rst),
        .spi_req(s_cyc && s_stb[SOC_S_SPI]), .xip_req(s_cyc && s_stb[SOC_S_XIP]),
        .spi_busy(spi_busy), .xip_ack(xip_ack),
        .spi_sclk(spi_sclk_c), .spi_mosi(spi_mosi_c), .spi_cs_n(spi_cs_n_c),
        .xip_sclk(xip_sclk_c), .xip_mosi(xip_mosi_c), .xip_cs_n(xip_cs_n_c),
        .spi_go(spi_go), .xip_go(xip_go), .xip_close(xip_close),
        .flash_sclk(spi_sclk), .flash_mosi(spi_mosi), .flash_cs_n(spi_cs_n)
    );

    // ----- Slave 11: the interrupt controller, new -----

    wb_intc u_intc (
        .clk(clk), .rst(rst),
        .cyc(s_cyc), .stb(s_stb[11]), .we(s_we), .adr(s_adr[1:0]), .sel(s_sel),
        .dat_w(s_dat_w), .ack(s_ack[11]), .err(s_err[11]), .stall(s_stall[11]),
        .dat_r(s_dat_r[11*32 +: 32]), .hold(hold[14]),
        .uart_irq(uart_irq), .dma_done(dma_done), .dma_error(dma_error),
        .irq(irq_external)
    );

endmodule
