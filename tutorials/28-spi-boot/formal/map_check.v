// Tutorial 22's interconnect with this system's map, for formal verification only.
//
// Tutorial 26's map_check.v, with the three new slaves. It gives the
// interconnect soc_map.vh, the same file soc.v uses, and leaves every port
// free. The checks are the ones already inside wb_interconnect.v: a bus checker
// on the master port and on each slave port, the links between them, and the
// assertion that no two regions overlap. Then a second decode, written from the
// table in soc_map.vh's comment, must agree with the interconnect.
module map_check (
    input  wire                      clk,
    input  wire                      rst,
    input  wire                      m_cyc,
    input  wire                      m_stb,
    input  wire                      m_we,
    input  wire [29:0]               m_adr,
    input  wire [3:0]                m_sel,
    input  wire [31:0]               m_dat_w,
    output wire                      m_ack,
    output wire                      m_err,
    output wire                      m_stall,
    output wire [31:0]               m_dat_r,
    output wire                      s_cyc,
    output wire [7:0]                s_stb,
    output wire                      s_we,
    output wire [29:0]               s_adr,
    output wire [3:0]                s_sel,
    output wire [31:0]               s_dat_w,
    input  wire [7:0]                s_ack,
    input  wire [7:0]                s_err,
    input  wire [7:0]                s_stall,
    input  wire [255:0]              s_dat_r
);

`include "soc_map.vh"

    wb_interconnect #(
        .N(SOC_SLAVES), .BASE(SOC_BASE), .MASK(SOC_MASK)
    ) u_interconnect (
        .clk(clk), .rst(rst),
        .m_cyc(m_cyc), .m_stb(m_stb), .m_we(m_we), .m_adr(m_adr), .m_sel(m_sel),
        .m_dat_w(m_dat_w), .m_ack(m_ack), .m_err(m_err), .m_stall(m_stall), .m_dat_r(m_dat_r),
        .s_cyc(s_cyc), .s_stb(s_stb), .s_we(s_we), .s_adr(s_adr), .s_sel(s_sel),
        .s_dat_w(s_dat_w), .s_ack(s_ack), .s_err(s_err), .s_stall(s_stall), .s_dat_r(s_dat_r)
    );

    // The map, as soc_map.vh's comment states it, checked a second way: each of
    // these byte addresses must go to the slave named, or to nobody.
    function [8:0] f_dest(input [31:0] a);
        f_dest = (a < 32'h0001_0000)                            ? 9'b000000001 :
                 (a >= 32'h1000_0000 && a < 32'h1000_0008)      ? 9'b000000010 :
                 (a >= 32'h1000_1000 && a < 32'h1000_1004)      ? 9'b000000100 :
                 (a >= 32'h1000_2000 && a < 32'h1000_2008)      ? 9'b000001000 :
                 (a >= 32'h2000_0000 && a < 32'h2000_0020)      ? 9'b000010000 :
                 (a >= 32'h0010_0000 && a < 32'h0010_0400)      ? 9'b000100000 :
                 (a >= 32'h1000_4000 && a < 32'h1000_4020)      ? 9'b001000000 :
                 (a >= 32'h1000_5000 && a < 32'h1000_5010)      ? 9'b010000000 :
                                                                  9'b100000000;
    endfunction

    // A strobe only ever goes to the slave that owns the address, and a request
    // that is taken goes to it, or to nobody if nobody owns it.
    wire [8:0] f_want = f_dest({m_adr, 2'b00});

    always @(*) begin
        assert ((s_stb & ~f_want[7:0]) == 8'd0);
        if (m_cyc && m_stb && !m_stall)
            assert (s_stb == f_want[7:0]);
    end

    // Each region, and the hole after it, can be reached.
    always @(*) begin
        if (!rst) begin
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0000_3FFF);   // RAM, last word
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0000_4000);   // just past RAM
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0400_0001);   // UART data
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0400_0002);   // just past the UART
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0400_0400);   // GPIO
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0400_0801);   // instret
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0400_0C00);   // 0x1000_3000, free
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0800_0007);   // last AXI4-Lite word
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0800_0008);   // just past it
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0004_0000);   // boot ROM, first word
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0004_00FF);   // boot ROM, last word
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0004_0100);   // just past it
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0400_1004);   // SPI STREAM
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0400_1008);   // just past SPI
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0400_1402);   // CRC RESULT
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0400_1404);   // just past CRC
        end
    end

endmodule
