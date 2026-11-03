// Tutorial 26's system, cut down to what this lesson measures, with an
// instruction cache and a flash the core can run from:
//
//   rv32i --native--> icache --native--> rv_wb_bridge --Wishbone--> wb_interconnect --> wb_ram
//                       ^                                                           --> wb_gpio
//                       |  invalidate, hit, miss                                    --> wb_counters
//                       +---------------------------------------------------------- --> wb_cachectl
//                                                                                   --> wb_xip --> SPI flash
//
// The core is Tutorial 21's, unchanged. RESET_ADDR says where it starts: 0 for a
// program in RAM, SOC_XIP_BASE for one in flash. The memory map is in soc_map.vh.
//
// CACHE_LINES 0 leaves the cache out, and the core talks to the bridge directly,
// as in Tutorial 26.
//
// Bus errors become traps, exactly as in Tutorial 26:
//    1  instruction access fault: a fetch got err
//    5  load access fault
//    7  store access fault
module soc #(
    parameter        INIT             = "",       // for $readmemh into the RAM, or "" for none
    parameter [31:0] RESET_ADDR       = 32'h0000_0000,
    parameter        CACHE_LINES      = 64,       // 0: no cache
    parameter        CACHE_LINE_WORDS = 4,
    parameter        XIP_STREAM       = 1,        // keep the flash's read open for the next word
    parameter [7:0]  XIP_DIV          = 8'd1      // SCLK is clk / (2 * (XIP_DIV + 1))
) (
    input  wire        clk,
    input  wire        rst,        // synchronous, active high
    output wire [31:0] gpio_out,
    output wire        trap,       // high from a trap until reset
    output wire [3:0]  trap_cause, // why, as an mcause code
    output wire        retire,     // the core's, passed on for testbenches
    output wire [31:0] retire_pc,
    output wire [31:0] retire_instr,
    // The SPI flash
    output wire        spi_sclk,
    output wire        spi_mosi,
    input  wire        spi_miso,
    output wire        spi_cs_n,
    // For testing only. Each hold bit makes one slave stall on this clock: 0 RAM,
    // 1 GPIO, 2 counters, 3 cache control, 4 XIP. ram_wait makes every RAM
    // access wait that many clocks more. Tie both to 0.
    input  wire [4:0]  hold,
    input  wire [3:0]  ram_wait
);

`include "soc_map.vh"

    localparam [3:0] CAUSE_FETCH_FAULT = 4'd1;
    localparam [3:0] CAUSE_LOAD_FAULT  = 4'd5;
    localparam [3:0] CAUSE_STORE_FAULT = 4'd7;

    // ----- The core -----

    wire        mem_valid, mem_instr, mem_ready, mem_err;
    wire [31:0] mem_addr, mem_wdata, mem_rdata;
    wire [3:0]  mem_wstrb;
    wire        core_trap;
    wire [3:0]  core_cause;

    rv32i #(.RESET_ADDR(RESET_ADDR)) u_core (
        .clk(clk), .rst(rst),
        .mem_valid(mem_valid), .mem_instr(mem_instr), .mem_ready(mem_ready),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),
        .trap(core_trap), .trap_cause(core_cause),
        .retire(retire), .retire_pc(retire_pc), .retire_instr(retire_instr)
    );

    // ----- Access faults, as in Tutorial 26 -----

    reg       fault;
    reg [3:0] fault_cause;

    always @(posedge clk) begin
        if (rst) begin
            fault       <= 1'b0;
            fault_cause <= 4'd0;
        end else if (mem_err && !fault) begin
            fault       <= 1'b1;
            fault_cause <= mem_instr            ? CAUSE_FETCH_FAULT :
                           mem_wstrb != 4'd0    ? CAUSE_STORE_FAULT :
                                                  CAUSE_LOAD_FAULT;
        end
    end

    assign trap       = core_trap || fault;
    assign trap_cause = fault ? fault_cause : core_cause;

    // ----- The instruction cache -----

    // The cache may keep words from RAM and from the flash, nothing else.
    wire cacheable = (mem_addr & SOC_RAM_MASK) == SOC_RAM_BASE
                  || (mem_addr & SOC_XIP_MASK) == SOC_XIP_BASE;

    wire        d_valid, d_instr, d_ready, d_err;
    wire [31:0] d_addr, d_wdata, d_rdata;
    wire [3:0]  d_wstrb;
    wire        invalidate, cache_hit, cache_miss;

    // rv_wb_bridge has no use for mem_instr: Wishbone does not tell fetches apart.
    wire        unused_d_instr = &{1'b0, d_instr};

    generate
        if (CACHE_LINES != 0) begin : g_cache
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
        end else begin : g_no_cache
            assign d_valid    = mem_valid;
            assign d_instr    = mem_instr;
            assign d_addr     = mem_addr;
            assign d_wdata    = mem_wdata;
            assign d_wstrb    = mem_wstrb;
            assign mem_ready  = d_ready;
            assign mem_err    = d_err;
            assign mem_rdata  = d_rdata;
            assign cache_hit  = 1'b0;
            assign cache_miss = 1'b0;
            wire unused_no_cache = &{1'b0, cacheable, invalidate};
        end
    endgenerate

    // ----- The bridge to Wishbone, Tutorial 26's -----

    wire        m_cyc, m_stb, m_we, m_ack, m_err, m_stall;
    wire [29:0] m_adr;
    wire [3:0]  m_sel;
    wire [31:0] m_dat_w, m_dat_r;

    rv_wb_bridge u_bridge (
        .clk(clk), .rst(rst),
        .mem_valid(d_valid), .mem_ready(d_ready), .mem_err(d_err),
        .mem_addr(d_addr), .mem_wdata(d_wdata), .mem_wstrb(d_wstrb),
        .mem_rdata(d_rdata),
        .cyc(m_cyc), .stb(m_stb), .we(m_we), .adr(m_adr), .sel(m_sel), .dat_w(m_dat_w),
        .ack(m_ack), .err(m_err), .stall(m_stall), .dat_r(m_dat_r)
    );

    // ----- The interconnect -----

    wire                     s_cyc, s_we;
    wire [SOC_SLAVES-1:0]    s_stb, s_ack, s_err, s_stall;
    wire [3:0]               s_sel;
    wire [31:0]              s_dat_w;
    wire [32*SOC_SLAVES-1:0] s_dat_r;
    // Each slave decodes only the low bits it needs. The interconnect has checked the rest.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [29:0]              s_adr;
    /* verilator lint_on UNUSEDSIGNAL */

    wb_interconnect #(
        .N(SOC_SLAVES), .BASE(SOC_BASE), .MASK(SOC_MASK)
    ) u_interconnect (
        .clk(clk), .rst(rst),
        .m_cyc(m_cyc), .m_stb(m_stb), .m_we(m_we), .m_adr(m_adr), .m_sel(m_sel),
        .m_dat_w(m_dat_w), .m_ack(m_ack), .m_err(m_err), .m_stall(m_stall), .m_dat_r(m_dat_r),
        .s_cyc(s_cyc), .s_stb(s_stb), .s_we(s_we), .s_adr(s_adr), .s_sel(s_sel),
        .s_dat_w(s_dat_w), .s_ack(s_ack), .s_err(s_err), .s_stall(s_stall), .s_dat_r(s_dat_r)
    );

    // ----- The slaves -----

    // Slow RAM, for measuring: each request waits ram_wait clocks before the RAM
    // takes it, on top of the clock the RAM itself takes to answer.
    reg [3:0] ram_waited;
    wire      ram_request = s_cyc && s_stb[0];

    always @(posedge clk) begin
        if (rst || !ram_request)
            ram_waited <= 4'd0;
        else if (ram_waited != 4'hF)
            ram_waited <= ram_waited + 4'd1;
    end

    wb_ram #(.AW(14), .INIT(INIT)) u_ram (
        .clk(clk), .rst(rst),
        .cyc(s_cyc), .stb(s_stb[0]), .we(s_we), .adr(s_adr[13:0]), .sel(s_sel),
        .dat_w(s_dat_w), .ack(s_ack[0]), .err(s_err[0]), .stall(s_stall[0]),
        .dat_r(s_dat_r[0*32 +: 32]), .hold(hold[0] || ram_waited < ram_wait)
    );

    wb_gpio u_gpio (
        .clk(clk), .rst(rst),
        .cyc(s_cyc), .stb(s_stb[1]), .we(s_we), .sel(s_sel),
        .dat_w(s_dat_w), .ack(s_ack[1]), .err(s_err[1]), .stall(s_stall[1]),
        .dat_r(s_dat_r[1*32 +: 32]), .hold(hold[1]),
        .gpio_out(gpio_out)
    );

    wb_counters u_counters (
        .clk(clk), .rst(rst),
        .cyc(s_cyc), .stb(s_stb[2]), .we(s_we), .adr(s_adr[0]),
        .ack(s_ack[2]), .err(s_err[2]), .stall(s_stall[2]),
        .dat_r(s_dat_r[2*32 +: 32]), .hold(hold[2]),
        .retire(retire)
    );

    wb_cachectl u_cachectl (
        .clk(clk), .rst(rst),
        .cyc(s_cyc), .stb(s_stb[3]), .we(s_we), .adr(s_adr[1:0]),
        .ack(s_ack[3]), .err(s_err[3]), .stall(s_stall[3]),
        .dat_r(s_dat_r[3*32 +: 32]), .hold(hold[3]),
        .invalidate(invalidate), .hit(cache_hit), .miss(cache_miss)
    );

    wb_xip #(.STREAM(XIP_STREAM), .DIV(XIP_DIV)) u_xip (
        .clk(clk), .rst(rst),
        .cyc(s_cyc), .stb(s_stb[4]), .we(s_we), .adr(s_adr[21:0]),
        .ack(s_ack[4]), .err(s_err[4]), .stall(s_stall[4]),
        .dat_r(s_dat_r[4*32 +: 32]), .hold(hold[4]),
        .sclk(spi_sclk), .mosi(spi_mosi), .miso(spi_miso), .cs_n(spi_cs_n)
    );

endmodule
