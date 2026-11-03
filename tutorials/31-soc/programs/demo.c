/* The system-on-chip demo. The boot ROM has copied this program from the flash
 * into RAM and checked its CRC. Then:
 *
 *   1. Timer interrupts every PERIOD clocks keep a tick count.
 *   2. The DMA engine prints three messages through the UART, one after another,
 *      each started by the DMA interrupt of the one before. Meanwhile the CPU
 *      works out a CRC-32 in software, with a function that runs from the flash,
 *      through the instruction cache.
 *   3. The DMA engine feeds the same bytes to the CRC unit, and the two CRCs
 *      must agree.
 *   4. The SPI controller reads the flash's ID and one word of the code in the
 *      flash, which the XIP slave also reads: the two share the flash.
 *   5. Bytes that arrive on the UART are counted by the UART's interrupt.
 *   6. A report: ticks, clocks and instructions, the cache's hits and misses,
 *      what the DMA engine moved, and the rest. The testbench checks each number
 *      against its own count.
 *
 * Interrupt handlers save every register they use, so they call nothing that
 * is not inlined, as in Tutorial 27. */
#include "soc.h"

#define PERIOD     10000u     /* clocks between timer interrupts */
#define BUF_BYTES  512u       /* the bytes the two CRCs are worked out over */
#define MESSAGES   3u

static const char msg0[] = "DMA: hello from the second bus master.\n";
static const char msg1[] = "DMA: the CPU works out a CRC from flash.\n";
static const char msg2[] = "DMA: last message, then the report.\n";
static const char *const message[MESSAGES] = {msg0, msg1, msg2};
static const uint32_t message_len[MESSAGES] = {sizeof msg0 - 1, sizeof msg1 - 1, sizeof msg2 - 1};

static uint8_t buffer[BUF_BYTES];
static uint64_t deadline;

static volatile uint32_t ticks;
static volatile uint32_t dma_irqs, uart_irqs, rx_bytes;
static volatile uint32_t dma_bytes, dma_copies, dma_errors;
static volatile uint32_t current_len;     /* the length of the copy running now */
static volatile uint32_t next_message;    /* the next one the handler starts */
static volatile uint32_t printing;        /* the messages are still going */
static volatile uint32_t copy_done;       /* the copy to the CRC unit ended */

static inline void dma_start(uint32_t src, uint32_t dst, uint32_t len, uint32_t ctrl)
{
    current_len = len;
    DMA_SRC = src;
    DMA_DST = dst;
    DMA_LEN = len;
    DMA_CTRL = ctrl | DMA_START;
}

/* A message to the UART: a byte at a time, to a fixed address, each byte when
 * the UART's dreq says the transmitter is ready. */
static inline void dma_print(uint32_t index)
{
    dma_start((uint32_t)message[index], (uint32_t)&UART_DATA, message_len[index],
              DMA_BYTES | DMA_DST_FIXED | DMA_PACE);
}

__attribute__((interrupt("machine")))
static void handler(void)
{
    uint32_t cause = csr_read(mcause);

    if (cause == MCAUSE_TIMER) {
        deadline += PERIOD;
        mtimecmp_write(deadline);
        ticks++;
    } else if (cause == MCAUSE_EXTERNAL) {
        uint32_t pending = INTC_PENDING;
        if (pending & INTC_DMA) {
            INTC_PENDING = INTC_DMA;            /* clear it before the next copy */
            dma_irqs++;
            dma_copies++;
            if (DMA_STATUS & DMA_ERROR)
                dma_errors++;
            else
                dma_bytes += current_len;
            if (printing && next_message < MESSAGES) {
                dma_print(next_message);
                next_message++;
            } else if (printing) {
                printing = 0;
            } else {
                copy_done = 1;
            }
        }
        if (pending & INTC_UART) {
            (void)UART_DATA;                    /* taking the byte clears the line */
            rx_bytes++;
            uart_irqs++;
        }
    } else {
        /* An exception. Nothing here should take one: stop at an ebreak that is
         * not _exit's, so the testbench fails. */
        __asm__ volatile ("ebreak");
    }
}

/* CRC-32, bit by bit, as zlib computes it. This one runs from the flash. */
XIP uint32_t crc32_soft(const uint8_t *data, uint32_t count)
{
    uint32_t crc = 0xFFFFFFFFu;

    while (count--) {
        crc ^= *data++;
        for (int bit = 0; bit < 8; bit++)
            crc = (crc >> 1) ^ (0xEDB88320u & -(crc & 1u));
    }
    return ~crc;
}

/* The SPI controller, Tutorial 28. These run from RAM: code that drives the SPI
 * controller must not be fetched from the flash, see the README. */
static uint32_t spi_byte(uint32_t out)
{
    SPI_TX = out;
    while (!(SPI_STATUS & SPI_RX_FULL))
        ;
    return SPI_RX & 0xFFu;
}

static void spi_end(void)
{
    while (SPI_STATUS & SPI_BUSY)
        ;
}

static uint32_t flash_id(void)
{
    uint32_t id;

    spi_byte(0x9F);
    id = spi_byte(0) << 16;
    id |= spi_byte(0) << 8;
    id |= spi_byte(SPI_LAST);
    spi_end();
    return id;
}

static uint32_t flash_word(uint32_t address)
{
    uint32_t word = 0;

    spi_byte(0x03);
    spi_byte((address >> 16) & 0xFFu);
    spi_byte((address >> 8) & 0xFFu);
    spi_byte(address & 0xFFu);
    for (int n = 0; n < 3; n++)
        word |= spi_byte(0) << (8 * n);
    word |= spi_byte(SPI_LAST) << 24;
    spi_end();
    return word;
}

static void puthex(uint32_t n)
{
    for (int shift = 28; shift >= 0; shift -= 4)
        uart_putc("0123456789abcdef"[(n >> shift) & 0xFu]);
}

int main(void)
{
    uint32_t x = 0x2545F491u;
    uint32_t crc_sw, crc_hw, id, word_spi, word_xip, cycles, instret, hits, misses;
    uint32_t xip_flash = (uint32_t)crc32_soft - XIP_BASE;

    uart_puts("SoC demo: booted from flash\n");

    for (uint32_t n = 0; n < BUF_BYTES; n++) {   /* xorshift32 */
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        buffer[n] = (uint8_t)(x >> 24);
    }

    csr_write(mtvec, handler);
    deadline = mtime_read() + PERIOD;
    mtimecmp_write(deadline);
    INTC_ENABLE = INTC_UART | INTC_DMA;
    csr_set(mie, MIE_MTIE | MIE_MEIE);
    csr_set(mstatus, MSTATUS_MIE);

    /* 1 and 2: the DMA engine prints while the CPU computes from the flash. */
    printing = 1;
    next_message = 1;
    dma_print(0);
    crc_sw = crc32_soft(buffer, BUF_BYTES);
    while (printing)
        ;

    /* 3: the DMA engine feeds the CRC unit. */
    CRC_CLEAR = 0;
    dma_start((uint32_t)buffer, (uint32_t)&CRC_DATA, BUF_BYTES, DMA_BYTES | DMA_DST_FIXED);
    while (!copy_done)
        ;
    crc_hw = CRC_RESULT;

    /* 4: the SPI controller, after the XIP slave has used the flash. */
    id = flash_id();
    word_spi = flash_word(xip_flash);
    word_xip = *(volatile uint32_t *)crc32_soft;

    csr_clear(mstatus, MSTATUS_MIE);
    cycles = COUNT_CYCLES;
    instret = COUNT_INSTRET;
    hits = CACHE_HITS;
    misses = CACHE_MISSES;

    uart_puts("report\nticks ");
    uart_putdec(ticks);
    uart_puts("\ncycles ");
    uart_putdec(cycles);
    uart_puts(" instret ");
    uart_putdec(instret);
    uart_puts("\ncache hits ");
    uart_putdec(hits);
    uart_puts(" misses ");
    uart_putdec(misses);
    uart_puts(", ");
    uart_putdec(hits * 1000u / (hits + misses));
    uart_puts(" per mille\ndma ");
    uart_putdec(dma_copies);
    uart_puts(" copies, ");
    uart_putdec(dma_bytes);
    uart_puts(" bytes, ");
    uart_putdec(dma_errors);
    uart_puts(" errors, ");
    uart_putdec(dma_irqs);
    uart_puts(" interrupts\nuart ");
    uart_putdec(rx_bytes);
    uart_puts(" bytes in, ");
    uart_putdec(uart_irqs);
    uart_puts(" interrupts\ncrc software ");
    puthex(crc_sw);
    uart_puts(" hardware ");
    puthex(crc_hw);
    uart_puts("\nflash id ");
    puthex(id);
    uart_puts(", word at ");
    puthex((uint32_t)crc32_soft);
    uart_puts(" by spi ");
    puthex(word_spi);
    uart_puts(" by xip ");
    puthex(word_xip);
    uart_puts("\n");

    return (crc_sw == crc_hw && word_spi == word_xip && dma_errors == 0) ? 0 : 1;
}
