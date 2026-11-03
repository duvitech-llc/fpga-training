"""The memory of the whole system for the reference model: soc_map.vh's map, with
access faults where the bus answers err.

Tutorial 27's soc_model.py, with the slaves of Tutorials 28 to 30 and the
interrupt controller. iss.py's Iss asks faults() before every fetch, load and
store, and takes an access fault, as the core does.

  RAM        0x0000_0000 to 0x0000_FFFF  bytes
  boot ROM   0x0010_0000 to 0x0010_03FF  words; a write faults
  UART       0x1000_0000 to 0x1000_0007  what the hardware returned
  GPIO       0x1000_1000 to 0x1000_1003  one 32-bit register, with byte writes
  counters   0x1000_2000 to 0x1000_2007  what the hardware returned
  timer      0x1000_3000 to 0x1000_300F  what the hardware returned
  SPI        0x1000_4000 to 0x1000_401F  what the hardware returned; words 5 to 7
                                         fault, and so do writes to RX and STREAM
  CRC-32     0x1000_5000 to 0x1000_500F  worked out here: CLEAR, DATA, then RESULT
                                         is zlib.crc32 of the bytes; word 3 faults,
                                         and so does a write to RESULT
  DMA        0x1000_6000 to 0x1000_601F  what the hardware returned; words 5 to 7 fault
  cache      0x1000_7000 to 0x1000_700F  what the hardware returned; writes ignored
  interrupts 0x1000_8000 to 0x1000_800F  what the hardware returned; words 2 and 3 fault
  AXI4-Lite  0x2000_0000 to 0x2000_001F  reg0 to reg3, ID at 0x10 that refuses
                                         writes, and nothing from 0x14 up
  flash      0x4000_0000 to 0x40FF_FFFF  the flash image's bytes, repeating every
                                         64 KiB as the flash model's do; a write faults
  anything else                          an access fault

The devices marked "what the hardware returned" change by themselves, with time,
or with the DMA engine's work, so no model without a clock can know what a read
returns. The lockstep checker copies each word the bus returned into observed
before the model runs the instruction.

Nothing in this file comes from the RTL. It is written from the table above.
"""

import zlib

from iss import MASK

RAM_BYTES = 0x1_0000
ROM, UART, GPIO, COUNTERS, TIMER = 0x0010_0000, 0x1000_0000, 0x1000_1000, 0x1000_2000, 0x1000_3000
SPI, CRC, DMA, CACHECTL, INTC = 0x1000_4000, 0x1000_5000, 0x1000_6000, 0x1000_7000, 0x1000_8000
AXIL, XIP = 0x2000_0000, 0x4000_0000
AXIL_ID = 0x4158_494C
FLASH_BYTES = 0x1_0000

REGIONS = [  # name, base, size in bytes
    ("ram", 0, RAM_BYTES), ("rom", ROM, 0x400), ("uart", UART, 8), ("gpio", GPIO, 4),
    ("counters", COUNTERS, 8), ("timer", TIMER, 16), ("spi", SPI, 32), ("crc", CRC, 16),
    ("dma", DMA, 32), ("cachectl", CACHECTL, 16), ("intc", INTC, 16), ("axil", AXIL, 32),
    ("xip", XIP, 0x100_0000),
]

# Devices whose reads the model cannot predict.
OBSERVED = ("uart", "counters", "timer", "spi", "dma", "cachectl", "intc")


def region(address):
    """Which device owns a byte address, or None."""
    for name, base, size in REGIONS:
        if base <= address < base + size:
            return name
    return None


class SocMemory:
    def __init__(self, rom_words=(), flash=b""):
        self.ram = bytearray(RAM_BYTES)
        self.rom = list(rom_words) + [0] * (256 - len(rom_words))
        self.flash = bytes(flash) + b"\xFF" * (FLASH_BYTES - len(flash))
        self.gpio = 0
        self.axil = [0, 0, 0, 0]
        self.crc_bytes = bytearray()
        self.observed = {}          # word address -> the last word the bus returned

    def faults(self, address, count, write):
        """Would this access get err on the bus? The access is aligned."""
        where = region(address)
        if where is None:
            return True
        word = (address & 0x1F) // 4
        if where in ("rom", "xip"):
            return write
        if where == "spi":
            return word > 4 or (write and word in (2, 4))
        if where == "crc":
            return word == 3 or (write and word == 2)
        if where == "dma":
            return word > 4
        if where == "intc":
            return word > 1
        if where == "axil":
            offset = address - AXIL
            if offset >= 0x14:
                return True                         # DECERR: nothing there
            if write and offset >= 0x10:
                return True                         # SLVERR: ID refuses writes
        return False

    def word(self, address):
        """The 32-bit word that holds this byte address."""
        base = address & ~3
        where = region(address)
        if where == "ram":
            return int.from_bytes(self.ram[base: base + 4], "little")
        if where == "rom":
            return self.rom[(base - ROM) // 4]
        if where == "xip":
            offset = (base - XIP) % FLASH_BYTES
            return int.from_bytes(self.flash[offset: offset + 4], "little")
        if where == "gpio":
            return self.gpio
        if where == "axil":
            offset = base - AXIL
            return AXIL_ID if offset == 0x10 else self.axil[offset // 4]
        if where == "crc":
            return zlib.crc32(bytes(self.crc_bytes)) if base == CRC + 8 else 0
        return self.observed.get(base, 0)

    def read(self, address, count):
        lanes = self.word(address) >> (8 * (address % 4))
        return lanes & ((1 << (8 * count)) - 1)

    def write(self, address, count, value):
        where = region(address)
        if where == "ram":
            for n in range(count):
                self.ram[address + n] = (value >> (8 * n)) & 0xFF
            return
        mask = ((1 << (8 * count)) - 1) << (8 * (address % 4))
        data = (value << (8 * (address % 4))) & mask
        base = address & ~3
        if where == "gpio":
            self.gpio = (self.gpio & ~mask & MASK) | data
        elif where == "axil" and address - AXIL < 0x10:
            index = (address - AXIL) // 4
            self.axil[index] = (self.axil[index] & ~mask & MASK) | data
        elif where == "crc" and base == CRC:
            self.crc_bytes = bytearray()            # CLEAR
        elif where == "crc" and base == CRC + 4 and mask & 0xFF:
            self.crc_bytes.append(data & 0xFF)      # DATA: byte 0 only

    def dma_write(self, word_address, sel, data):
        """A write by the DMA engine, as it went on the bus: the byte address of the
        word, the byte lanes in sel, and the 32-bit data. A write that gets err
        changes nothing, as for the core. From Tutorial 29's soc_model.py."""
        if self.faults(word_address, 4, write=True):
            return
        if region(word_address) == "crc":
            # One write of the word, as the CRC unit sees it, not one per lane.
            if word_address == CRC:
                self.crc_bytes = bytearray()
            elif word_address == CRC + 4 and sel & 1:
                self.crc_bytes.append(data & 0xFF)
            return
        for lane in range(4):
            if sel >> lane & 1:
                self.write(word_address + lane, 1, (data >> (8 * lane)) & 0xFF)
