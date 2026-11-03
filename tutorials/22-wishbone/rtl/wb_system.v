// The whole lesson on one bus: a scripted master, the interconnect, and two
// register-file slaves. The testbenches drive this, and it is what gets synthesized.
//
//   0x1000_0000 to 0x1000_000F  slave 0: 4 registers, ack 1 clock after the request
//   0x2000_0000 to 0x2000_000F  slave 1: 4 registers, ack 3 clocks after the request
//   anything else               err, from the interconnect's default responder
//
// Addresses are byte addresses. cmd_adr is the word address, bits [31:2].
module wb_system (
    input  wire        clk,
    input  wire        rst,            // synchronous, active high
    input  wire        one_at_a_time,  // the master waits for each answer
    input  wire        hold0,          // slave 0 is busy: see wb_regfile
    input  wire        hold1,          // slave 1 is busy
    input  wire        cmd_valid,
    output wire        cmd_ready,
    input  wire        cmd_we,
    input  wire [29:0] cmd_adr,
    input  wire [3:0]  cmd_sel,
    input  wire [31:0] cmd_dat,
    output wire        rsp_valid,
    output wire        rsp_err,
    output wire [31:0] rsp_dat
);

    // The master's side of the interconnect
    wire        m_cyc, m_stb, m_we, m_ack, m_err, m_stall;
    wire [29:0] m_adr;
    wire [3:0]  m_sel;
    wire [31:0] m_dat_w, m_dat_r;

    // The slaves' side
    wire        s_cyc, s_we;
    wire [1:0]  s_stb, s_ack, s_err, s_stall;
    wire [3:0]  s_sel;
    wire [31:0] s_dat_w;
    wire [63:0] s_dat_r;
    // Each slave decodes only the low bits. The interconnect has checked the rest.
    /* verilator lint_off UNUSEDSIGNAL */
    wire [29:0] s_adr;
    /* verilator lint_on UNUSEDSIGNAL */

    wb_master u_master (
        .clk(clk), .rst(rst), .one_at_a_time(one_at_a_time),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_we(cmd_we),
        .cmd_adr(cmd_adr), .cmd_sel(cmd_sel), .cmd_dat(cmd_dat),
        .rsp_valid(rsp_valid), .rsp_err(rsp_err), .rsp_dat(rsp_dat),
        .cyc(m_cyc), .stb(m_stb), .we(m_we), .adr(m_adr), .sel(m_sel), .dat_w(m_dat_w),
        .ack(m_ack), .err(m_err), .stall(m_stall), .dat_r(m_dat_r)
    );

    wb_interconnect #(
        .N(2),
        .BASE({32'h2000_0000, 32'h1000_0000}),
        .MASK({32'hFFFF_FFF0, 32'hFFFF_FFF0})
    ) u_interconnect (
        .clk(clk), .rst(rst),
        .m_cyc(m_cyc), .m_stb(m_stb), .m_we(m_we), .m_adr(m_adr), .m_sel(m_sel),
        .m_dat_w(m_dat_w), .m_ack(m_ack), .m_err(m_err), .m_stall(m_stall), .m_dat_r(m_dat_r),
        .s_cyc(s_cyc), .s_stb(s_stb), .s_we(s_we), .s_adr(s_adr), .s_sel(s_sel),
        .s_dat_w(s_dat_w), .s_ack(s_ack), .s_err(s_err), .s_stall(s_stall), .s_dat_r(s_dat_r)
    );

    wb_regfile #(.AW(2), .LATENCY(1)) u_slave0 (
        .clk(clk), .rst(rst),
        .cyc(s_cyc), .stb(s_stb[0]), .we(s_we), .adr(s_adr[1:0]), .sel(s_sel),
        .dat_w(s_dat_w), .ack(s_ack[0]), .err(s_err[0]), .stall(s_stall[0]),
        .dat_r(s_dat_r[31:0]), .hold(hold0)
    );

    wb_regfile #(.AW(2), .LATENCY(3)) u_slave1 (
        .clk(clk), .rst(rst),
        .cyc(s_cyc), .stb(s_stb[1]), .we(s_we), .adr(s_adr[1:0]), .sel(s_sel),
        .dat_w(s_dat_w), .ack(s_ack[1]), .err(s_err[1]), .stall(s_stall[1]),
        .dat_r(s_dat_r[63:32]), .hold(hold1)
    );

endmodule
