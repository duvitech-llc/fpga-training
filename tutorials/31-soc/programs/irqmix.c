/* Two devices on one interrupt line, both pending at once.
 *
 * With interrupts off, the program waits for a byte on the UART and leaves it
 * there, so the UART's line is high. Then it runs a short DMA copy, which ends
 * while that line is still high. Only then does it turn interrupts on. The
 * interrupt controller must show both, and the handler must take both: the
 * DMA's end must not be lost just because the shared line was already high.
 *
 * Then ENABLE: a second copy ends with the DMA bit masked, and interrupts go on.
 * No interrupt may be taken while the bit is masked, and exactly one once it is
 * set again. */
#include "soc.h"

static volatile uint32_t dma_irqs, uart_irqs, byte;
static uint32_t source[4] = {0x11111111u, 0x22222222u, 0x33333333u, 0x44444444u};
static uint32_t target[4];

__attribute__((interrupt("machine")))
static void handler(void)
{
    if (csr_read(mcause) != MCAUSE_EXTERNAL)
        __asm__ volatile ("ebreak");          /* nothing else is expected */
    uint32_t pending = INTC_PENDING;
    if (pending & INTC_DMA) {
        INTC_PENDING = INTC_DMA;
        dma_irqs++;
    }
    if (pending & INTC_UART) {
        byte = UART_DATA;
        uart_irqs++;
    }
}

int main(void)
{
    uint32_t pending;

    csr_write(mtvec, handler);
    INTC_ENABLE = INTC_UART | INTC_DMA;
    csr_set(mie, MIE_MEIE);

    uart_putc('>');                            /* the testbench sends one byte */
    while (!(UART_STATUS & UART_RX_WAITING))
        ;
    DMA_SRC = (uint32_t)source;
    DMA_DST = (uint32_t)target;
    DMA_LEN = sizeof source;
    DMA_CTRL = DMA_START;
    while (DMA_STATUS & DMA_BUSY)
        ;
    pending = INTC_PENDING;

    csr_set(mstatus, MSTATUS_MIE);             /* both are taken here */
    for (int n = 0; n < 4; n++)
        __asm__ volatile ("nop");
    csr_clear(mstatus, MSTATUS_MIE);
    uint32_t first = dma_irqs;

    /* ENABLE masks: the DMA engine ends a second copy with its bit masked. */
    uint32_t masked, unmasked;
    INTC_ENABLE = INTC_UART;
    DMA_SRC = (uint32_t)source;                /* the same copy again */
    DMA_DST = (uint32_t)target;
    DMA_LEN = sizeof source;
    DMA_CTRL = DMA_START;
    while (DMA_STATUS & DMA_BUSY)
        ;
    csr_set(mstatus, MSTATUS_MIE);             /* pending, but masked: not taken */
    for (int n = 0; n < 4; n++)
        __asm__ volatile ("nop");
    masked = dma_irqs;
    INTC_ENABLE = INTC_UART | INTC_DMA;        /* now it is taken */
    for (int n = 0; n < 4; n++)
        __asm__ volatile ("nop");
    csr_clear(mstatus, MSTATUS_MIE);
    unmasked = dma_irqs;

    uart_puts("pending ");
    uart_putdec(pending);
    uart_puts(", dma interrupts ");
    uart_putdec(first);
    uart_puts(", uart interrupts ");
    uart_putdec(uart_irqs);
    uart_puts(", byte ");
    uart_putc((char)byte);
    uart_puts(", masked ");
    uart_putdec(masked);
    uart_puts(", enabled ");
    uart_putdec(unmasked);
    uart_puts("\n");
    return (pending == 3 && first == 1 && masked == 1 && unmasked == 2 && uart_irqs == 1 &&
            target[3] == source[3]) ? 0 : 1;
}
