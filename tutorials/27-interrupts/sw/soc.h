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
