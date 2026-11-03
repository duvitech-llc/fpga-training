// The memory map of soc.v, in one place. soc.v and formal/map_check.v both
// include it, so the proof checks the same map the system uses.
//
// Tutorial 26's map, with three new slaves, 5 to 7:
//
//   Slave  Device             Byte addresses              Size
//   0      RAM                0x0000_0000 to 0x0000_FFFF  64 KiB
//   1      UART               0x1000_0000 to 0x1000_0007  2 words
//   2      GPIO               0x1000_1000 to 0x1000_1003  1 word
//   3      counters           0x1000_2000 to 0x1000_2007  2 words
//   4      AXI4-Lite bridge   0x2000_0000 to 0x2000_001F  8 words, axil_regs uses 5
//   5      boot ROM           0x0010_0000 to 0x0010_03FF  1 KiB, read-only. Reset starts here
//   6      SPI controller     0x1000_4000 to 0x1000_401F  8 words, 5 used
//   7      CRC-32             0x1000_5000 to 0x1000_500F  4 words, 3 used
//   -      anything else      err, from the interconnect's default responder
//
// 0x1000_3000 is left free for Tutorial 27's timer.
//
// Slave 0 is in the lowest 32 bits of each parameter, as wb_interconnect expects.
localparam integer SOC_SLAVES = 8;

localparam [32*SOC_SLAVES-1:0] SOC_BASE = {
    32'h1000_5000,   // 7 CRC-32
    32'h1000_4000,   // 6 SPI controller
    32'h0010_0000,   // 5 boot ROM
    32'h2000_0000,   // 4 AXI4-Lite bridge
    32'h1000_2000,   // 3 counters
    32'h1000_1000,   // 2 GPIO
    32'h1000_0000,   // 1 UART
    32'h0000_0000    // 0 RAM
};

localparam [32*SOC_SLAVES-1:0] SOC_MASK = {
    32'hFFFF_FFF0,   // 7 CRC-32: 16 bytes
    32'hFFFF_FFE0,   // 6 SPI controller: 32 bytes
    32'hFFFF_FC00,   // 5 boot ROM: 1 KiB
    32'hFFFF_FFE0,   // 4 AXI4-Lite bridge: 32 bytes
    32'hFFFF_FFF8,   // 3 counters: 8 bytes
    32'hFFFF_FFFC,   // 2 GPIO: 4 bytes
    32'hFFFF_FFF8,   // 1 UART: 8 bytes
    32'hFFFF_0000    // 0 RAM: 64 KiB
};

localparam [31:0] SOC_AXIL_BASE = 32'h2000_0000;
localparam [31:0] SOC_ROM_BASE  = 32'h0010_0000;
