
# getbyte, polling: send a dummy byte, then read STATUS until RX holds the
# answer. Nothing is on the wire while the boot ROM stores the byte. Returns the
# byte in a0.
getbyte:
        sw     zero, SPI_TX(s0)
gwait:  lw     a0, SPI_STATUS(s0)
        andi   a0, a0, RX_FULL
        beqz   a0, gwait
        lw     a0, SPI_RX(s0)
        ret
