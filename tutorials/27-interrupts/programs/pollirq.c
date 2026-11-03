/* Polling against interrupts: how many CPU clocks does it cost to receive N bytes
 * from the UART each way? Timed with the counters peripheral.
 *
 * 1. Polled. The program prints ">", and the testbench sends N bytes, one after
 *    another at the line's speed. The program reads the status register until a
 *    byte is waiting, takes it, and goes back to reading. Every clock from the
 *    prompt to the last byte is spent waiting.
 * 2. Interrupts. A loop that only counts runs for WINDOW clocks, first with
 *    nothing else happening, then again after another ">", while the same N bytes
 *    arrive and the handler takes each one. The loop runs fewer times the second
 *    time, and the difference is what the bytes cost: entering the handler, the
 *    handler, and returning from it.
 *
 * Both take the same bytes, in the same time. What differs is what the CPU could
 * do meanwhile. */
#include "soc.h"

#define N      16u
#define WINDOW 4000u                /* clocks: longer than N bytes take to arrive */

static const char expected[N + 1] = "abcdefghijklmnop";

static volatile uint8_t got[N];
static volatile uint32_t received;
static volatile uint32_t unexpected;

__attribute__((interrupt("machine")))
static void handler(void)
{
    uint32_t cause = csr_read(mcause);

    if (cause != MCAUSE_EXTERNAL) {
        unexpected = cause;
        csr_clear(mie, MIE_MEIE | MIE_MTIE);
        return;
    }
    uint8_t c = (uint8_t)UART_DATA;
    if (received < N)
        got[received] = c;
    received++;
}

/* How many times a loop can go round in window clocks. noinline, so both
 * measurements run the very same instructions. */
__attribute__((noinline))
static uint32_t loops_in(uint32_t window)
{
    uint32_t start = COUNT_CYCLES;
    uint32_t loops = 0;

    while (COUNT_CYCLES - start < window)
        loops++;
    return loops;
}

static int got_expected(void)
{
    for (uint32_t i = 0; i < N; i++)
        if (got[i] != (uint8_t)expected[i])
            return 0;
    return 1;
}

int main(void)
{
    uint32_t start, polled, polls = 0, alone, busy, stolen;

    /* 1. Polled */
    uart_putc('>');
    start = COUNT_CYCLES;
    for (uint32_t i = 0; i < N; i++) {
        while (!(UART_STATUS & UART_RX_WAITING))
            polls++;
        got[i] = (uint8_t)UART_DATA;
    }
    polled = COUNT_CYCLES - start;
    if (!got_expected())
        return 1;

    uart_puts("\npolled: ");
    uart_putdec(N);
    uart_puts(" bytes in ");
    uart_putdec(polled);
    uart_puts(" clocks, all of them waiting, ");
    uart_putdec(polls);
    uart_puts(" status reads found nothing\n");

    /* 2. Interrupts */
    for (uint32_t i = 0; i < N; i++)
        got[i] = 0;
    alone = loops_in(WINDOW);

    csr_write(mtvec, handler);
    csr_set(mie, MIE_MEIE);
    csr_set(mstatus, MSTATUS_MIE);
    uart_putc('>');
    busy = loops_in(WINDOW);
    csr_clear(mstatus, MSTATUS_MIE);
    if (unexpected || received != N || !got_expected())
        return 2;

    /* The loop's clocks per round, WINDOW / alone, times the rounds it lost. */
    stolen = WINDOW - busy * WINDOW / alone;
    uart_puts("\ninterrupts: the loop ran ");
    uart_putdec(alone);
    uart_puts(" times alone and ");
    uart_putdec(busy);
    uart_puts(" times while ");
    uart_putdec(N);
    uart_puts(" bytes came in: they took ");
    uart_putdec(stolen);
    uart_puts(" of ");
    uart_putdec(WINDOW);
    uart_puts(" clocks, ");
    uart_putdec(stolen / N);
    uart_puts(" each\n");
    return 0;
}
