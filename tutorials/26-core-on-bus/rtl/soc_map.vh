// The memory map of soc.v, in one place. soc.v and formal/map_check.v both
// include it, so the proof checks the same map the system uses.
//
//   Slave  Device             Byte addresses              Size
//   0      RAM                0x0000_0000 to 0x0000_FFFF  64 KiB
//   1      UART               0x1000_0000 to 0x1000_0007  2 words
//   2      GPIO               0x1000_1000 to 0x1000_1003  1 word
//   3      counters           0x1000_2000 to 0x1000_2007  2 words
//   4      AXI4-Lite bridge   0x2000_0000 to 0x2000_001F  8 words, axil_regs uses 5
//   -      anything else      err, from the interconnect's default responder
//
// Slave 0 is in the lowest 32 bits of each parameter, as wb_interconnect expects.
localparam integer SOC_SLAVES = 5;

localparam [32*SOC_SLAVES-1:0] SOC_BASE = {
    32'h2000_0000,   // 4 AXI4-Lite bridge
    32'h1000_2000,   // 3 counters
    32'h1000_1000,   // 2 GPIO
    32'h1000_0000,   // 1 UART
    32'h0000_0000    // 0 RAM
};

localparam [32*SOC_SLAVES-1:0] SOC_MASK = {
    32'hFFFF_FFE0,   // 4 AXI4-Lite bridge: 32 bytes
    32'hFFFF_FFF8,   // 3 counters: 8 bytes
    32'hFFFF_FFFC,   // 2 GPIO: 4 bytes
    32'hFFFF_FFF8,   // 1 UART: 8 bytes
    32'hFFFF_0000    // 0 RAM: 64 KiB
};

localparam [31:0] SOC_AXIL_BASE = 32'h2000_0000;
