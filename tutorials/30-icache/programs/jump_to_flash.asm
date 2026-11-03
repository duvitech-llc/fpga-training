# The core always starts at 0, in RAM. To run a program from the flash, the
# testbenches put only this in RAM: a jump to the start of the flash.

        lui    t0, 0x40000
        jr     t0
