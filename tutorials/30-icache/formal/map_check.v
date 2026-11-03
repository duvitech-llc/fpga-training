// Tutorial 22's interconnect with this system's map, for formal verification only.
//
// This is Tutorial 26's map_check.v, for the map in soc_map.vh. The checks are the
// ones already inside wb_interconnect.v, and a second decode of the map, written
// from soc_map.vh's comment: each address must go to the slave named, or to
// nobody.
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
    output wire [4:0]                s_stb,
    output wire                      s_we,
    output wire [29:0]               s_adr,
    output wire [3:0]                s_sel,
    output wire [31:0]               s_dat_w,
    input  wire [4:0]                s_ack,
    input  wire [4:0]                s_err,
    input  wire [4:0]                s_stall,
    input  wire [159:0]              s_dat_r
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

    // The map, as soc_map.vh's comment states it, checked a second way.
    function [5:0] f_dest(input [31:0] a);
        f_dest = (a < 32'h0001_0000)                            ? 6'b000001 :
                 (a >= 32'h1000_1000 && a < 32'h1000_1004)      ? 6'b000010 :
                 (a >= 32'h1000_2000 && a < 32'h1000_2008)      ? 6'b000100 :
                 (a >= 32'h1000_7000 && a < 32'h1000_7010)      ? 6'b001000 :
                 (a >= 32'h4000_0000 && a < 32'h4100_0000)      ? 6'b010000 :
                                                                  6'b100000;
    endfunction

    // A strobe only ever goes to the slave that owns the address, and a request
    // that is taken goes to it, or to nobody if nobody owns it.
    wire [5:0] f_want = f_dest({m_adr, 2'b00});

    always @(*) begin
        assert ((s_stb & ~f_want[4:0]) == 5'd0);
        if (m_cyc && m_stb && !m_stall)
            assert (s_stb == f_want[4:0]);
    end

    // The cacheable regions, as soc.v decodes them, are exactly RAM and the flash.
    wire f_cacheable = (({m_adr, 2'b00} & SOC_RAM_MASK) == SOC_RAM_BASE)
                    || (({m_adr, 2'b00} & SOC_XIP_MASK) == SOC_XIP_BASE);
    always @(*)
        assert (f_cacheable == (f_want[0] || f_want[4]));

    // Each region, and the hole after it, can be reached.
    always @(*) begin
        if (!rst) begin
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0000_3FFF);   // RAM, last word
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0000_4000);   // just past RAM
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0400_0400);   // GPIO
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0400_0801);   // instret
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0400_1C02);   // MISSES
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0400_1C04);   // just past it
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h103F_FFFF);   // last word of flash
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h1040_0000);   // just past it
        end
    end

endmodule
