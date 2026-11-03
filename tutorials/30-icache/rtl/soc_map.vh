// The memory map of soc.v, in one place. soc.v and formal/map_check.v both
// include it, so the proof checks the same map the system uses.
//
//   Slave  Device             Byte addresses              Size        Cached
//   0      RAM                0x0000_0000 to 0x0000_FFFF  64 KiB      yes
//   1      GPIO               0x1000_1000 to 0x1000_1003  1 word      no
//   2      counters           0x1000_2000 to 0x1000_2007  2 words     no
//   3      cache control      0x1000_7000 to 0x1000_700F  4 words     no
//   4      XIP flash          0x4000_0000 to 0x40FF_FFFF  16 MiB      yes
//   -      anything else      err, from the interconnect's default responder
//
// GPIO and the counters are where Tutorial 26 put them. 0x1000_3000 to
// 0x1000_6FFF are left to Tutorials 27 to 29, and 0x2000_0000 to Tutorial 26's
// AXI4-Lite bridge, which this lesson does not need.
//
// Only RAM and the flash are cacheable: their words do not change unless the
// program writes them. A peripheral's register can change on every read.
//
// Slave 0 is in the lowest 32 bits of each parameter, as wb_interconnect expects.
localparam integer SOC_SLAVES = 5;

localparam [32*SOC_SLAVES-1:0] SOC_BASE = {
    32'h4000_0000,   // 4 XIP flash
    32'h1000_7000,   // 3 cache control
    32'h1000_2000,   // 2 counters
    32'h1000_1000,   // 1 GPIO
    32'h0000_0000    // 0 RAM
};

localparam [32*SOC_SLAVES-1:0] SOC_MASK = {
    32'hFF00_0000,   // 4 XIP flash: 16 MiB
    32'hFFFF_FFF0,   // 3 cache control: 16 bytes
    32'hFFFF_FFF8,   // 2 counters: 8 bytes
    32'hFFFF_FFFC,   // 1 GPIO: 4 bytes
    32'hFFFF_0000    // 0 RAM: 64 KiB
};

localparam [31:0] SOC_RAM_BASE = 32'h0000_0000;
localparam [31:0] SOC_RAM_MASK = 32'hFFFF_0000;
localparam [31:0] SOC_XIP_BASE = 32'h4000_0000;
localparam [31:0] SOC_XIP_MASK = 32'hFF00_0000;
