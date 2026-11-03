/* The second boot image, at flash address 0xC000. reboot.c boots it. It runs
 * from the same RAM addresses as the first image did. */
#include "soc.h"

static uint32_t sum(uint32_t n)
{
    uint32_t total = 0;

    while (n)
        total += n--;
    return total;
}

/* At 0x200, where reboot.c's main is: see there. */
__attribute__((aligned(512)))
int main(void)
{
    uart_puts("image B: sum ");
    uart_putdec(sum(100));
    uart_puts("\n");
    return 0;
}
