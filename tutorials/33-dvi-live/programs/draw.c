/* Draws an animated picture into the framebuffer, one scene a frame.
 *
 * Two framebuffers, so the screen never shows a picture half drawn: the program
 * draws scene n into the one not on the screen, the back buffer, then writes its
 * address to DISP_BASE. The display takes BASE at the start of the next
 * vertical blank, and from then on the old front buffer is free to draw into.
 * The vertical blank interrupt counts the blanks; main waits on that count and
 * on DISP_CURRENT to know the swap has happened.
 *
 * tools/scene.py draws the same scenes in Python, and the testbench compares
 * the frames it decodes from the DVI wires with them. Change one, change both.
 */
#include "soc.h"
#include "font.h"

#define W        160
#define H        120
#define FB0      ((uint8_t *)FB_BASE)
#define FB1      ((uint8_t *)(FB_BASE + 0x5000u))   /* 20480 bytes on: room for 19200 */

static volatile uint32_t vblanks;

__attribute__((interrupt("machine")))
static void handler(void)
{
    if (csr_read(mcause) != MCAUSE_EXTERNAL)
        __asm__ volatile ("ebreak");          /* nothing else is expected */
    if (INTC_PENDING & INTC_VBLANK) {
        INTC_PENDING = INTC_VBLANK;
        vblanks++;
        GPIO_OUT = vblanks;                   /* for the testbench to check */
    }
}

/* Rows y0 to y1 - 1 in one colour, a word (four pixels) at a time. */
static void fill_rows(uint8_t *fb, int y0, int y1, uint8_t colour)
{
    uint32_t word = colour * 0x01010101u;
    uint32_t *p = (uint32_t *)(fb + y0 * W);
    uint32_t *end = (uint32_t *)(fb + y1 * W);
    while (p < end) {
        p[0] = word;
        p[1] = word;
        p[2] = word;
        p[3] = word;
        p += 4;
    }
}

static void rect(uint8_t *fb, int x, int y, int w, int h, uint8_t colour)
{
    for (int j = y; j < y + h; j++)
        for (int i = x; i < x + w; i++)
            fb[j * W + i] = colour;
}

/* Text from the 5x7 font, each font pixel drawn scale by scale, 6 * scale
 * pixels a character. */
static void text(uint8_t *fb, int x, int y, const char *s, int scale, uint8_t colour)
{
    for (; *s; s++, x += 6 * scale) {
        int code = *s;
        if (code < FONT_FIRST || code > FONT_LAST)
            continue;
        for (int row = 0; row < 7; row++) {
            int bits = font[code - FONT_FIRST][row];
            for (int col = 0; col < 5; col++)
                if (bits & (0x10 >> col))
                    rect(fb, x + col * scale, y + row * scale, scale, scale, colour);
        }
    }
}

/* t folded into 0..m and back, a bounce. */
static int bounce(uint32_t t, int m)
{
    int r = (int)(t % (uint32_t)(2 * m));
    return r > m ? 2 * m - r : r;
}

static const uint8_t bars[8] = {
    RGB332(7, 7, 3), RGB332(7, 7, 0), RGB332(0, 7, 3), RGB332(0, 7, 0),
    RGB332(7, 0, 3), RGB332(7, 0, 0), RGB332(0, 0, 3), RGB332(0, 0, 0),
};

static void draw(uint8_t *fb, uint32_t n)
{
    char label[16] = "FRAME ";
    char digits[10];
    int count = 0, k = 6;

    /* Four bands of blue, darkest at the top. */
    for (int band = 0; band < 4; band++)
        fill_rows(fb, band * 30, band * 30 + 30, RGB332(0, 0, band));
    /* Colour bars along the top. */
    for (int b = 0; b < 8; b++)
        rect(fb, b * 20, 0, 20, 10, bars[b]);
    /* A square that bounces around the middle. */
    rect(fb, bounce(n * 7, W - 20), 46 + bounce(n * 3, 50), 20, 20, RGB332(7, 3, 0));
    text(fb, 2, 14, "DVI LIVE VIEW", 2, RGB332(7, 7, 0));
    text(fb, 47, 32, "TUTORIAL 33", 1, RGB332(7, 7, 3));
    /* "FRAME n", n in decimal. */
    do {
        digits[count++] = (char)('0' + n % 10);
        n /= 10;
    } while (n);
    while (count)
        label[k++] = digits[--count];
    label[k] = 0;
    text(fb, 4, 110, label, 1, RGB332(7, 7, 3));
}

int main(void)
{
    uint8_t *back = FB0, *front = FB1, *spare;

    if (DISP_SIZE != ((H << 16) | W))
        return 1;

    csr_write(mtvec, handler);
    INTC_ENABLE = INTC_VBLANK;
    csr_set(mie, MIE_MEIE);
    csr_set(mstatus, MSTATUS_MIE);

    for (uint32_t n = 0;; n++) {
        draw(back, n);
        /* The stores to the framebuffer are plain C stores. Without this
         * barrier the compiler may move some of them after the volatile store
         * to DISP_BASE below, and the picture could be shown unfinished. */
        __asm__ volatile ("" : : : "memory");
        DISP_BASE = (uint32_t)back;
        DISP_CTRL = DISP_ENABLE;
        /* Wait for the swap: CURRENT takes BASE at the next vertical blank.
         * One interrupt may still arrive from a blank that began before BASE
         * was written, but a second with no swap means something is wrong. */
        uint32_t seen = vblanks;
        while (DISP_CURRENT != (uint32_t)back)
            if (vblanks - seen > 1)
                return 2;
        spare = front;
        front = back;
        back = spare;
    }
}
