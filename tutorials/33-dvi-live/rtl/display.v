// The display controller: a bus side on the system clock, a pixel side on the
// pixel clock, and Tutorial 10's dual-clock FIFO between them.
//
//          system clock, clk                     |      pixel clock, pclk
//                                                |
//   registers  <-- Wishbone slave                |
//   reader     --> Wishbone master               |
//      |                                         |
//      +-- words --> async_fifo write side ======|====> read side --> display_pixel --> de, sync, RGB
//                                                |                      |
//   sync_2ff x3 <-- vblank, show, underrun <-----|----------------------+
//   enable -------------------------------------|----> sync_2ff
//
// Only these cross between the clocks: the FIFO's two Gray-coded pointers,
// inside async_fifo; four single-bit levels, each through a two-flop
// synchroniser; and the reset, through reset_sync. Simulation does not model metastability, so the
// tests passing here do not prove these crossings safe. They are safe by
// construction, as Tutorials 10 and 13 explain, and only if every crossing
// goes through one of those synchronisers.
//
// The pixel side's reset is rst, through Tutorial 13's reset_sync: it rises
// with rst and falls two pixel clocks after it. So both sides of the FIFO are
// in reset together, as Tutorial 10 requires.
module display #(
    parameter integer H_ACTIVE   = 160,
    parameter integer H_FRONT    = 8,
    parameter integer H_SYNC     = 16,
    parameter integer H_BACK     = 16,
    parameter integer V_ACTIVE   = 120,
    parameter integer V_FRONT    = 2,
    parameter integer V_SYNC     = 3,
    parameter integer V_BACK     = 5,
    parameter [0:0]   H_POL      = 1'b1,
    parameter [0:0]   V_POL      = 1'b1,
    parameter integer FIFO_AW    = 4,
    parameter integer BURST      = 4,
    parameter [31:0]  BASE_RESET = 32'h0100_0000
) (
    input  wire        clk,
    // Synchronous to clk, active high, and the asynchronous input of the pixel
    // side's reset_sync, which is what reset_sync is for.
    /* verilator lint_off SYNCASYNCNET */
    input  wire        rst,
    /* verilator lint_on SYNCASYNCNET */
    input  wire        pclk,
    // Slave: the registers
    input  wire        cyc,
    input  wire        stb,
    input  wire        we,
    input  wire [2:0]  adr,
    input  wire [3:0]  sel,
    input  wire [31:0] dat_w,
    output wire        ack,
    output wire        err,
    output wire        stall,
    output wire [31:0] dat_r,
    input  wire        hold,
    // Master: the reader
    output wire        m_cyc,
    output wire        m_stb,
    output wire        m_we,
    output wire [29:0] m_adr,
    output wire [3:0]  m_sel,
    output wire [31:0] m_dat_w,
    input  wire        m_ack,
    input  wire        m_err,
    input  wire        m_stall,
    input  wire [31:0] m_dat_r,
    // To the interrupt controller, synchronised to clk
    output wire        vblank,
    // The pixel side's reset and its outputs, all on pclk
    output wire        prst,
    output wire        de,
    output wire        hsync,
    output wire        vsync,
    output wire [7:0]  r,
    output wire [7:0]  g,
    output wire [7:0]  b
);

    reset_sync u_prst (.clk(pclk), .arst(rst), .rst(prst));

    wire               fifo_wr, fifo_rd, fifo_empty;
    wire [31:0]        fifo_wr_data, fifo_rd_data;
    wire [FIFO_AW:0]   fifo_wr_used;
    wire               vblank_p, show_p, underrun_p, enable;

    wb_display #(
        .WIDTH(H_ACTIVE), .HEIGHT(V_ACTIVE), .FIFO_AW(FIFO_AW), .BURST(BURST),
        .BASE_RESET(BASE_RESET)
    ) u_bus (
        .clk(clk), .rst(rst),
        .cyc(cyc), .stb(stb), .we(we), .adr(adr), .sel(sel), .dat_w(dat_w),
        .ack(ack), .err(err), .stall(stall), .dat_r(dat_r), .hold(hold),
        .m_cyc(m_cyc), .m_stb(m_stb), .m_we(m_we), .m_adr(m_adr), .m_sel(m_sel),
        .m_dat_w(m_dat_w), .m_ack(m_ack), .m_err(m_err), .m_stall(m_stall), .m_dat_r(m_dat_r),
        .fifo_wr(fifo_wr), .fifo_data(fifo_wr_data), .fifo_used(fifo_wr_used),
        .vblank_p(vblank_p), .show_p(show_p), .underrun_p(underrun_p),
        .enable(enable), .vblank(vblank)
    );

    // full is not needed: the reader starts a burst only when wr_used says
    // there is room for all of it. rd_used is for testbenches to watch.
    wire               fifo_full;
    wire [FIFO_AW:0]   fifo_rd_used;
    wire               unused_fifo = &{1'b0, fifo_full, fifo_rd_used};

    async_fifo #(.WIDTH(32), .ADDR_WIDTH(FIFO_AW)) u_fifo (
        .wr_clk(clk), .wr_rst(rst), .wr_en(fifo_wr), .wr_data(fifo_wr_data),
        .full(fifo_full), .wr_used(fifo_wr_used),
        .rd_clk(pclk), .rd_rst(prst), .rd_en(fifo_rd), .rd_data(fifo_rd_data),
        .empty(fifo_empty), .rd_used(fifo_rd_used)
    );

    display_pixel #(
        .H_ACTIVE(H_ACTIVE), .H_FRONT(H_FRONT), .H_SYNC(H_SYNC), .H_BACK(H_BACK),
        .V_ACTIVE(V_ACTIVE), .V_FRONT(V_FRONT), .V_SYNC(V_SYNC), .V_BACK(V_BACK),
        .H_POL(H_POL), .V_POL(V_POL)
    ) u_pixel (
        .pclk(pclk), .prst(prst), .enable_b(enable),
        .fifo_rd(fifo_rd), .fifo_data(fifo_rd_data), .fifo_empty(fifo_empty),
        .vblank(vblank_p), .show_next(show_p), .underrun(underrun_p),
        .de_o(de), .hsync_o(hsync), .vsync_o(vsync), .r_o(r), .g_o(g), .b_o(b)
    );

endmodule
