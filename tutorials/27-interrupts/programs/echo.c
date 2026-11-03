/* Echoes what arrives on the UART, with the external interrupt doing the reading.
 *
 * The handler takes each byte as it arrives and puts it in a ring buffer. main
 * takes bytes out of the buffer and sends them back, until a newline. Sending is
 * still polled: the transmitter has no interrupt in this system.
 *
 * The program prints ">" when it is ready. The testbench sends its line then. */
#include "soc.h"

#define SIZE 16u                    /* a power of 2, so % is a mask */

static volatile uint8_t buffer[SIZE];
static volatile uint32_t head;      /* written only by the handler */
static volatile uint32_t tail;      /* written only by main */
static volatile uint32_t unexpected;

__attribute__((interrupt("machine")))
static void handler(void)
{
    uint32_t cause = csr_read(mcause);

    if (cause != MCAUSE_EXTERNAL) {
        /* Nothing else is enabled, and nothing should trap. Mark it, and turn
         * interrupts off for good, so mret does not come straight back here. */
        unexpected = cause;
        csr_clear(mie, MIE_MEIE | MIE_MTIE);
        return;
    }
    /* Reading the data register takes the byte, and the UART lowers its line. */
    buffer[head % SIZE] = (uint8_t)UART_DATA;
    head++;
}

int main(void)
{
    uint32_t count = 0;
    char c;

    csr_write(mtvec, handler);
    csr_set(mie, MIE_MEIE);
    csr_set(mstatus, MSTATUS_MIE);
    uart_putc('>');

    do {
        while (tail == head && !unexpected)
            ;
        if (unexpected)
            return 2;
        c = (char)buffer[tail % SIZE];
        tail++;
        uart_putc(c);
        count++;
    } while (c != '\n');

    csr_clear(mstatus, MSTATUS_MIE);
    uart_putdec(count);
    uart_puts(" bytes echoed\n");
    return 0;
}
