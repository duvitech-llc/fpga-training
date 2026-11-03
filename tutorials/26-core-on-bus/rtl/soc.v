// Tutorial 21's RV32I core on Tutorial 22's Wishbone bus, with a RAM, the UART,
// a GPIO register, two counters, and Tutorial 23's AXI4-Lite register block
// behind a bridge. The memory map is in soc_map.vh.
//
//   rv32i --native--> rv_wb_bridge --Wishbone--> wb_interconnect --> wb_ram
//                                                                --> wb_uart
//                                                                --> wb_gpio
//                                                                --> wb_counters
//                                                                --> wb_axil_bridge --AXI4-Lite--> axil_regs
//
// Bus errors. An access that gets err, from the default responder or from a
// slave, is an access fault. The core is Tutorial 21's, unchanged, and has no
// input for one. So the bridge never finishes the transfer, the core waits with
// the instruction unfinished, and this module raises trap with the mcause code:
//    1  instruction access fault: a fetch got err
//    5  load access fault
//    7  store access fault
// The core's own traps come out on the same two outputs, with their own codes.
// Either way, nothing the instruction would have changed has changed, and only
// reset leaves the trap.
module soc #(
    parameter CLKS_PER_BIT = 16,
    parameter INIT         = ""    // the program, for $readmemh into the RAM
) (
    input  wire        clk,
    input  wire        rst,        // synchronous, active high
    input  wire        uart_rx,    // asynchronous: the UART synchronizes it
    output wire        uart_tx,
    output wire [31:0] gpio_out,
    output wire        trap,       // high from a trap until reset
    output wire [3:0]  trap_cause, // why, as an mcause code
    output wire        retire,     // the core's, passed on for testbenches
    output wire [31:0] retire_pc,
    output wire [31:0] retire_instr,
    // For testing only: each bit makes one slave stall on this clock. 0 RAM,
    // 1 UART, 2 GPIO, 3 counters, and 6 to 4 are axil_regs' hold. Tie to 0.
    input  wire [6:0]  hold
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

    rv32i u_core (
        .clk(clk), .rst(rst),
        .mem_valid(mem_valid), .mem_instr(mem_instr), .mem_ready(mem_ready),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),
        .trap(core_trap), .trap_cause(core_cause),
        .retire(retire), .retire_pc(retire_pc), .retire_instr(retire_instr)
    );

    // ----- Access faults -----

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

    // ----- The bridge to Wishbone -----

    wire        m_cyc, m_stb, m_we, m_ack, m_err, m_stall;
    wire [29:0] m_adr;
    wire [3:0]  m_sel;
    wire [31:0] m_dat_w, m_dat_r;

    rv_wb_bridge u_bridge (
        .clk(clk), .rst(rst),
        .mem_valid(mem_valid), .mem_ready(mem_ready), .mem_err(mem_err),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),
        .cyc(m_cyc), .stb(m_stb), .we(m_we), .adr(m_adr), .sel(m_sel), .dat_w(m_dat_w),
        .ack(m_ack), .err(m_err), .stall(m_stall), .dat_r(m_dat_r)
    );

    // ----- The interconnect -----

    wire                    s_cyc, s_we;
    wire [SOC_SLAVES-1:0]   s_stb, s_ack, s_err, s_stall;
    wire [3:0]              s_sel;
    wire [31:0]             s_dat_w;
    wire [32*SOC_SLAVES-1:0] s_dat_r;
    // Each slave decodes only the low bits it needs. The interconnect has checked the rest.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [29:0]             s_adr;
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
        .tx(uart_tx), .rx(uart_rx)
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

    // ----- The AXI4-Lite side -----

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

endmodule
