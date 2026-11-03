/* Counts timer interrupts. The handler moves mtimecmp on by PERIOD clocks each
 * time, so the timer fires every PERIOD clocks, and main spins until TICKS of them
 * have happened. Then it prints how many times its own loop ran, and how late the
 * handler read mtime after each deadline, at least and at most.
 *
 * The handler is C, with GCC's interrupt attribute. That makes GCC save every
 * register the handler uses, not only the ones a normal function must keep, and
 * return with mret instead of ret. It must call no function that is not inlined:
 * then it would have to save every caller-saved register, whether used or not. */
#include "soc.h"

#define PERIOD 2000u
#define TICKS  10u

static volatile uint32_t ticks;
static uint64_t deadline;          /* when the timer is due next */
static uint32_t late_min = 0xFFFFFFFFu, late_max;

__attribute__((interrupt("machine")))
static void handler(void)
{
    /* Only the timer is enabled, and nothing in this program should trap, so the
     * cause is not checked: see echo.c for a handler that does. */
    uint32_t late = MTIME_LO - (uint32_t)deadline;

    if (late < late_min)
        late_min = late;
    if (late > late_max)
        late_max = late;
    deadline += PERIOD;
    mtimecmp_write(deadline);      /* also clears MTIP: mtime < mtimecmp again */
    ticks++;
}

int main(void)
{
    uint32_t spins = 0;

    csr_write(mtvec, handler);
    deadline = mtime_read() + PERIOD;
    mtimecmp_write(deadline);
    csr_set(mie, MIE_MTIE);
    csr_set(mstatus, MSTATUS_MIE);

    while (ticks < TICKS)
        spins++;

    csr_clear(mstatus, MSTATUS_MIE);
    uart_putdec(ticks);
    uart_puts(" ticks, ");
    uart_putdec(spins);
    uart_puts(" spins, handler read mtime ");
    uart_putdec(late_min);
    uart_puts(" to ");
    uart_putdec(late_max);
    uart_puts(" clocks after the deadline\n");
    return ticks == TICKS ? 0 : 1;
}
