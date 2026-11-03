// Tutorial 22's interconnect with this system's map, for formal verification only.
//
// Tutorial 28's map_check.v and Tutorial 30's, merged and extended to the final
// map: thirteen slaves. It gives the interconnect soc_map.vh, the same file
// soc.v uses, and leaves every port free. The checks are the ones already inside
// wb_interconnect.v: a bus checker on the master port and on each slave port,
// the links between them, and the assertion that no two regions overlap. Then a
// second decode, written from the table in soc_map.vh's comment, must agree with
// the interconnect, and the cacheable regions must be exactly RAM, the boot ROM
// and the flash.
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
    output wire [12:0]               s_stb,
    output wire                      s_we,
    output wire [29:0]               s_adr,
    output wire [3:0]                s_sel,
    output wire [31:0]               s_dat_w,
    input  wire [12:0]               s_ack,
    input  wire [12:0]               s_err,
    input  wire [12:0]               s_stall,
    input  wire [415:0]              s_dat_r
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
    // these byte addresses must go to the slave named, or to nobody, bit 13.
    function [13:0] f_dest(input [31:0] a);
        f_dest = (a < 32'h0001_0000)                            ? 14'd1 << 0 :
                 (a >= 32'h1000_0000 && a < 32'h1000_0008)      ? 14'd1 << 1 :
                 (a >= 32'h1000_1000 && a < 32'h1000_1004)      ? 14'd1 << 2 :
                 (a >= 32'h1000_2000 && a < 32'h1000_2008)      ? 14'd1 << 3 :
                 (a >= 32'h2000_0000 && a < 32'h2000_0020)      ? 14'd1 << 4 :
                 (a >= 32'h1000_3000 && a < 32'h1000_3010)      ? 14'd1 << 5 :
                 (a >= 32'h0010_0000 && a < 32'h0010_0400)      ? 14'd1 << 6 :
                 (a >= 32'h1000_4000 && a < 32'h1000_4020)      ? 14'd1 << 7 :
                 (a >= 32'h1000_5000 && a < 32'h1000_5010)      ? 14'd1 << 8 :
                 (a >= 32'h1000_6000 && a < 32'h1000_6020)      ? 14'd1 << 9 :
                 (a >= 32'h1000_7000 && a < 32'h1000_7010)      ? 14'd1 << 10 :
                 (a >= 32'h1000_8000 && a < 32'h1000_8010)      ? 14'd1 << 11 :
                 (a >= 32'h4000_0000 && a < 32'h4100_0000)      ? 14'd1 << 12 :
                                                                  14'd1 << 13;
    endfunction

    // A strobe only ever goes to the slave that owns the address, and a request
    // that is taken goes to it, or to nobody if nobody owns it.
    wire [13:0] f_want = f_dest({m_adr, 2'b00});

    always @(*) begin
        assert ((s_stb & ~f_want[12:0]) == 13'd0);
        if (m_cyc && m_stb && !m_stall)
            assert (s_stb == f_want[12:0]);
    end

    // Every peripheral starts on a 4 KiB boundary. The memories, RAM, the boot
    // ROM and the flash, start on bigger ones.
    integer f_i;
    always @(*)
        for (f_i = 0; f_i < SOC_SLAVES; f_i = f_i + 1)
            assert (SOC_BASE[32*f_i +: 12] == 12'h000);

    // The cacheable regions, as soc.v decodes them, are exactly RAM, the boot ROM
    // and the flash.
    wire [31:0] f_byte = {m_adr, 2'b00};
    wire f_cacheable = ((f_byte & SOC_RAM_MASK) == SOC_RAM_BASE)
                    || ((f_byte & SOC_ROM_MASK) == SOC_ROM_BASE)
                    || ((f_byte & SOC_XIP_MASK) == SOC_XIP_BASE);
    always @(*)
        assert (f_cacheable == (f_want[0] || f_want[6] || f_want[12]));

    // The regions left for Tutorial 33 belong to nobody yet.
    always @(*) begin
        if (f_byte >= 32'h0100_0000 && f_byte < 32'h0102_0000)
            assert (f_want[13]);
        if (f_byte >= 32'h1000_9000 && f_byte < 32'h1000_A000)
            assert (f_want[13]);
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
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0800_0007);   // last AXI4-Lite word
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0800_0008);   // just past it
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0400_0C03);   // mtimecmp high
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0400_0C04);   // just past the timer
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0004_00FF);   // boot ROM, last word
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0004_0100);   // just past it
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0400_1004);   // SPI STREAM
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0400_1008);   // just past SPI
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0400_1402);   // CRC RESULT
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0400_1404);   // just past CRC
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0400_1804);   // DMA STATUS
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0400_1808);   // just past DMA
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0400_1C02);   // MISSES
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0400_1C04);   // just past it
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0400_2001);   // interrupt ENABLE
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0400_2004);   // just past it
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0400_2400);   // 0x1000_9000, free
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h103F_FFFF);   // last word of flash
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h1040_0000);   // just past it
            cover (m_cyc && m_stb && !m_stall && m_adr == 30'h0040_0000);   // 0x0100_0000, free
        end
    end

endmodule
