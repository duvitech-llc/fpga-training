/* Interrupt latency with the DMA engine idle, then busy.
 *
 * The timer interrupts every PERIOD clocks. First the program waits for TICKS of
 * them with the DMA engine idle. Then it starts a long word copy, RAM to RAM, and
 * counts the timer interrupts that come while the copy runs. The testbench
 * measures how long each interrupt waited, both times. The handler, and the
 * loops, run from RAM, through the cache. */
#include "soc.h"

#define PERIOD 300u
#define TICKS  40u
#define COPY   8192u              /* bytes: 2048 word units */

static volatile uint32_t ticks;
static uint64_t deadline;

__attribute__((interrupt("machine")))
static void handler(void)
{
    if (csr_read(mcause) != MCAUSE_TIMER)
        __asm__ volatile ("ebreak");          /* nothing else is expected */
    deadline += PERIOD;
    mtimecmp_write(deadline);
    ticks++;
}

static void timer_on(void)
{
    ticks = 0;
    deadline = mtime_read() + PERIOD;
    mtimecmp_write(deadline);
    csr_set(mstatus, MSTATUS_MIE);
}

static void timer_off(void)
{
    csr_clear(mstatus, MSTATUS_MIE);
    mtimecmp_write(0xFFFFFFFFFFFFFFFFull);
}

int main(void)
{
    uint32_t idle_ticks, busy_ticks;

    csr_write(mtvec, handler);
    csr_set(mie, MIE_MTIE);

    timer_on();
    while (ticks < TICKS)
        ;
    timer_off();
    idle_ticks = ticks;

    DMA_SRC = 0x4000;
    DMA_DST = 0x8000;
    DMA_LEN = COPY;
    DMA_CTRL = DMA_START;
    timer_on();
    while (DMA_STATUS & DMA_BUSY)
        ;
    timer_off();
    busy_ticks = ticks;

    uart_puts("idle: ");
    uart_putdec(idle_ticks);
    uart_puts(" ticks\nbusy: ");
    uart_putdec(busy_ticks);
    uart_puts(" ticks while the DMA engine copied ");
    uart_putdec(COPY);
    uart_puts(" bytes\n");
    return (idle_ticks == TICKS && busy_ticks > 0 && !(DMA_STATUS & DMA_ERROR)) ? 0 : 1;
}
