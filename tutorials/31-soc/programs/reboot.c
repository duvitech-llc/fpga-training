/* The first of two boot images. It prints a line, then jumps back into the boot
 * ROM, at its second entry, to boot the image at flash address 0xC000, which
 * second.c builds. That image is copied over this one, at the same addresses.
 *
 * The cache still holds this image's code. The boot ROM must invalidate it
 * before it jumps, or the second image would run this one's words. */
#include "soc.h"

#define SECOND_IMAGE 0xC000u

/* main sits at 0x200, as in second.c, so the two images have different code at
 * the same address, in cache lines the boot ROM does not use. The boot ROM is
 * cached too, and its 440 bytes take the lines that RAM addresses 0 to 0x1BF
 * would use: code there is thrown out by the boot anyway. */
__attribute__((aligned(512)))
int main(void)
{
    uart_puts("image A: booting image B\n");
    while (!(UART_STATUS & UART_TX_READY))
        ;
    /* Interrupts are off, and the DMA engine is idle, as the boot ROM needs. */
    ((void (*)(uint32_t))BOOT_REBOOT)(SECOND_IMAGE);
    return 1;                                  /* never reached */
}
