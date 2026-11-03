/* The first C program of the course. Prints one line and returns 0, which crt0
 * hands to the testbench in a0 at its ebreak. */
#include "soc.h"

int main(void)
{
    uart_puts("Hello from C\n");
    return 0;
}
