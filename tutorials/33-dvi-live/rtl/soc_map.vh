// The memory map of soc.v, in one place. soc.v and formal/map_check.v both
// include it, so the proof checks the same map the system uses.
//
// Every device of Tutorials 26 to 30 in one map. Each peripheral starts on a
// 4 KiB boundary. Tutorial 28 put the CRC unit at 0x1000_5000, and Tutorial 29
// put the DMA engine there too. The CRC unit keeps it, because the boot ROM's
// program uses that address, and the DMA engine moves up to 0x1000_6000.
//
//   Slave  Device             Byte addresses              Size        Cached
//   0      RAM                0x0000_0000 to 0x0000_FFFF  64 KiB      yes
//   1      UART               0x1000_0000 to 0x1000_0007  2 words     no
//   2      GPIO               0x1000_1000 to 0x1000_1003  1 word      no
//   3      counters           0x1000_2000 to 0x1000_2007  2 words     no
//   4      AXI4-Lite bridge   0x2000_0000 to 0x2000_001F  8 words     no
//   5      timer              0x1000_3000 to 0x1000_300F  4 words     no
//   6      boot ROM           0x0010_0000 to 0x0010_03FF  1 KiB       yes
//   7      SPI controller     0x1000_4000 to 0x1000_401F  8 words     no
//   8      CRC-32             0x1000_5000 to 0x1000_500F  4 words     no
//   9      DMA registers      0x1000_6000 to 0x1000_601F  8 words     no   (moved from 0x1000_5000)
//   10     cache control      0x1000_7000 to 0x1000_700F  4 words     no
//   11     interrupt control  0x1000_8000 to 0x1000_800F  4 words     no
//   12     XIP flash          0x4000_0000 to 0x40FF_FFFF  16 MiB      yes
//   13     framebuffer RAM    0x0100_0000 to 0x0101_FFFF  128 KiB     no   (Tutorial 33)
//   14     display registers  0x1000_9000 to 0x1000_901F  8 words     no   (Tutorial 33)
//   -      anything else      err, from the interconnect's default responder
//
// Tutorial 31 left the two regions of slaves 13 and 14 free for this lesson.
// The framebuffer is not cached: the core never runs code from it.
//
// Slave 0 is in the lowest 32 bits of each parameter, as wb_interconnect expects.
// Slaves 0 to 5 keep Tutorial 27's numbers, and 6 to 12 Tutorial 31's.
localparam integer SOC_SLAVES = 15;

localparam [32*SOC_SLAVES-1:0] SOC_BASE = {
    32'h1000_9000,   // 14 display registers
    32'h0100_0000,   // 13 framebuffer RAM
    32'h4000_0000,   // 12 XIP flash
    32'h1000_8000,   // 11 interrupt control
    32'h1000_7000,   // 10 cache control
    32'h1000_6000,   //  9 DMA registers
    32'h1000_5000,   //  8 CRC-32
    32'h1000_4000,   //  7 SPI controller
    32'h0010_0000,   //  6 boot ROM
    32'h1000_3000,   //  5 timer
    32'h2000_0000,   //  4 AXI4-Lite bridge
    32'h1000_2000,   //  3 counters
    32'h1000_1000,   //  2 GPIO
    32'h1000_0000,   //  1 UART
    32'h0000_0000    //  0 RAM
};

localparam [32*SOC_SLAVES-1:0] SOC_MASK = {
    32'hFFFF_FFE0,   // 14 display registers: 32 bytes
    32'hFFFE_0000,   // 13 framebuffer RAM: 128 KiB
    32'hFF00_0000,   // 12 XIP flash: 16 MiB
    32'hFFFF_FFF0,   // 11 interrupt control: 16 bytes
    32'hFFFF_FFF0,   // 10 cache control: 16 bytes
    32'hFFFF_FFE0,   //  9 DMA registers: 32 bytes
    32'hFFFF_FFF0,   //  8 CRC-32: 16 bytes
    32'hFFFF_FFE0,   //  7 SPI controller: 32 bytes
    32'hFFFF_FC00,   //  6 boot ROM: 1 KiB
    32'hFFFF_FFF0,   //  5 timer: 16 bytes
    32'hFFFF_FFE0,   //  4 AXI4-Lite bridge: 32 bytes
    32'hFFFF_FFF8,   //  3 counters: 8 bytes
    32'hFFFF_FFFC,   //  2 GPIO: 4 bytes
    32'hFFFF_FFF8,   //  1 UART: 8 bytes
    32'hFFFF_0000    //  0 RAM: 64 KiB
};

localparam [31:0] SOC_AXIL_BASE = 32'h2000_0000;
localparam [31:0] SOC_ROM_BASE  = 32'h0010_0000;
localparam [31:0] SOC_FB_BASE   = 32'h0100_0000;

// The regions the instruction cache may keep: their words change only when a
// program, or the DMA engine, writes them.
localparam [31:0] SOC_RAM_BASE  = 32'h0000_0000;
localparam [31:0] SOC_RAM_MASK  = 32'hFFFF_0000;
localparam [31:0] SOC_ROM_MASK  = 32'hFFFF_FC00;
localparam [31:0] SOC_XIP_BASE  = 32'h4000_0000;
localparam [31:0] SOC_XIP_MASK  = 32'hFF00_0000;

// The slave numbers that soc.v needs by name.
localparam integer SOC_S_SPI     = 7;
localparam integer SOC_S_XIP     = 12;
localparam integer SOC_S_FB      = 13;
localparam integer SOC_S_DISPLAY = 14;
