/* The little that the programs here need from a C library, written out, since
 * there is none: -nostdlib leaves libc out. */
#include "soc.h"

/* Waits for the transmitter, then sends one byte. A byte written while the
 * transmitter is busy is lost, as in Tutorial 19. */
void uart_putc(char c)
{
    while (!(UART_STATUS & UART_TX_READY))
        ;
    UART_DATA = (uint8_t)c;
}

void uart_puts(const char *s)
{
    while (*s)
        uart_putc(*s++);
}

/* n in decimal. RV32I has no divide, so n % 10 and n / 10 become calls to
 * __umodsi3 and __udivsi3 in libgcc, which the Makefile links in. */
void uart_putdec(uint32_t n)
{
    char digits[10];
    int count = 0;

    do {
        digits[count++] = (char)('0' + n % 10);
        n /= 10;
    } while (n);
    while (count)
        uart_putc(digits[--count]);
}
