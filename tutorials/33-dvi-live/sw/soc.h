/* The system's devices and the core's CSRs, for C programs.
 *
 * The addresses are rtl/soc_map.vh's. Each register is a volatile pointer, so the
 * compiler makes exactly the loads and stores the program asks for, in order:
 * reading the UART's data register takes a byte, so a read must never be dropped
 * or repeated.
 */
#ifndef SOC_H
#define SOC_H

#include <stdint.h>

#define REG(address) (*(volatile uint32_t *)(address))

/* UART: Tutorial 19's two registers. */
#define UART_STATUS       REG(0x10000000)
#define UART_DATA         REG(0x10000004)
#define UART_TX_READY     0x1u
#define UART_RX_WAITING   0x2u

/* GPIO: one output register. */
#define GPIO_OUT          REG(0x10001000)

/* Counters: clocks and instructions since reset. */
#define COUNT_CYCLES      REG(0x10002000)
#define COUNT_INSTRET     REG(0x10002004)

/* The machine timer, new in Tutorial 27. */
#define MTIME_LO          REG(0x10003000)
#define MTIME_HI          REG(0x10003004)
#define MTIMECMP_LO       REG(0x10003008)
#define MTIMECMP_HI       REG(0x1000300C)

/* Tutorial 31: the devices of Tutorials 28 to 30, and the interrupt controller.
 * Tutorial 33 adds the display, below the interrupt controller. */

/* SPI controller, Tutorial 28. */
#define SPI_CTRL          REG(0x10004000)
#define SPI_TX            REG(0x10004004)
#define SPI_RX            REG(0x10004008)
#define SPI_STATUS        REG(0x1000400C)
#define SPI_STREAM        REG(0x10004010)
#define SPI_LAST          0x100u          /* TX bit 8: CS rises after this byte */
#define SPI_RX_FULL       0x2u
#define SPI_BUSY          0x4u

/* CRC-32, Tutorial 28. */
#define CRC_CLEAR         REG(0x10005000)
#define CRC_DATA          REG(0x10005004)
#define CRC_RESULT        REG(0x10005008)

/* DMA engine, Tutorial 29, moved from 0x10005000. */
#define DMA_SRC           REG(0x10006000)
#define DMA_DST           REG(0x10006004)
#define DMA_LEN           REG(0x10006008)
#define DMA_CTRL          REG(0x1000600C)
#define DMA_STATUS        REG(0x10006010)
#define DMA_START         0x01u
#define DMA_SRC_FIXED     0x02u
#define DMA_DST_FIXED     0x04u
#define DMA_BYTES         0x08u
#define DMA_PACE          0x10u
#define DMA_BUSY          0x1u
#define DMA_DONE          0x2u
#define DMA_ERROR         0x4u

/* Cache control, Tutorial 30. */
#define CACHE_INVALIDATE  REG(0x10007000)
#define CACHE_HITS        REG(0x10007004)
#define CACHE_MISSES      REG(0x10007008)

/* Interrupt control: PENDING and ENABLE, bit 0 the UART, bit 1 the DMA engine,
 * and from Tutorial 33 bit 2 the display's vertical blank. */
#define INTC_PENDING      REG(0x10008000)
#define INTC_ENABLE       REG(0x10008004)
#define INTC_UART         0x1u
#define INTC_DMA          0x2u
#define INTC_VBLANK       0x4u

/* Tutorial 33: the framebuffer, 128 KiB, and the display controller. A pixel
 * is one byte, RGB332: red in bits 7:5, green in 4:2, blue in 1:0. */
#define FB_BASE           0x01000000u
#define FB_SIZE           0x00020000u
#define DISP_CTRL         REG(0x10009000)
#define DISP_BASE         REG(0x10009004)   /* the framebuffer for the next frame */
#define DISP_CURRENT      REG(0x10009008)   /* the one on the screen now */
#define DISP_STATUS       REG(0x1000900C)
#define DISP_FRAMES       REG(0x10009010)
#define DISP_SIZE         REG(0x10009014)   /* height << 16 | width */
#define DISP_ENABLE       0x1u
#define DISP_VBLANK       0x1u
#define DISP_UNDERRUN     0x2u
#define DISP_BUS_ERROR    0x4u
#define DISP_READING      0x8u
#define RGB332(r, g, b)   ((uint8_t)(((r) << 5) | ((g) << 2) | (b)))   /* r, g 0-7, b 0-3 */

/* The boot ROM, and its second entry: jump there with a flash address in a0. */
#define BOOT_ROM          0x00100000u
#define BOOT_REBOOT       0x00100004u

/* The flash, read in place. The linker script puts .xip.text there, at flash
 * address 0x8000. A function marked XIP runs from the flash, through the cache.
 * noinline keeps GCC from copying it into a caller in RAM. */
#define XIP_BASE          0x40000000u
#define XIP               __attribute__((section(".xip.text"), noinline))

/* Bits of mstatus, mie and mip, and the two interrupt causes, from the privileged spec. */
#define MSTATUS_MIE       0x8u
#define MSTATUS_MPIE      0x80u
#define MIE_MTIE          0x80u
#define MIE_MEIE          0x800u
#define MCAUSE_TIMER      0x80000007u
#define MCAUSE_EXTERNAL   0x8000000Bu

/* The CSR instructions, by name. C has no way to say "csrr", so these use inline
 * assembly. The "memory" clobber stops the compiler moving loads and stores across
 * them: enabling interrupts must come after the variables a handler uses are set. */
#define csr_read(csr) ({ uint32_t value_; \
    __asm__ volatile ("csrr %0, " #csr : "=r"(value_) : : "memory"); value_; })
#define csr_write(csr, value) \
    __asm__ volatile ("csrw " #csr ", %0" : : "r"((uint32_t)(value)) : "memory")
#define csr_set(csr, bits) \
    __asm__ volatile ("csrs " #csr ", %0" : : "r"((uint32_t)(bits)) : "memory")
#define csr_clear(csr, bits) \
    __asm__ volatile ("csrc " #csr ", %0" : : "r"((uint32_t)(bits)) : "memory")

/* mtime is 64 bits, read 32 at a time. If the low half wraps between the two
 * reads, the high half has moved on, so read the high half again and retry. */
static inline uint64_t mtime_read(void)
{
    uint32_t hi, lo;
    do {
        hi = MTIME_HI;
        lo = MTIME_LO;
    } while (MTIME_HI != hi);
    return ((uint64_t)hi << 32) | lo;
}

/* A new mtimecmp, in the order the privileged spec suggests. All ones in the low
 * half first means the 64-bit value is never smaller than both the old and the
 * new one while it is half written, so the timer cannot fire by mistake. */
static inline void mtimecmp_write(uint64_t when)
{
    MTIMECMP_LO = 0xFFFFFFFFu;
    MTIMECMP_HI = (uint32_t)(when >> 32);
    MTIMECMP_LO = (uint32_t)when;
}

/* sw/lib.c */
void uart_putc(char c);
void uart_puts(const char *s);
void uart_putdec(uint32_t n);

#endif
