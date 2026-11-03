
# getbyte, streaming: one load from STREAM. The SPI slave stalls the load until
# the byte is in, and starts the next byte as it answers, so that byte is on
# the wire while the boot ROM stores this one. Returns the byte in a0.
getbyte:
        lw     a0, SPI_STREAM(s0)
        ret
