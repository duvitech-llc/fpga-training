"""The memory of the whole system for the reference model: soc_map.vh's map, with
access faults where the bus answers err.

In Tutorial 26 this file also had SocIss, which stopped the model at an access
fault. In Tutorial 27 an access fault is a trap like any other, and iss.py's Iss
takes it: it asks the memory's faults() before every fetch, load and store.

iss.py's Memory is 64 KiB that repeats through the whole address space. Here the
address decides what is there:

  RAM        0x0000_0000 to 0x0000_FFFF  bytes, as in iss.py
  UART       0x1000_0000 to 0x1000_0007  what the hardware returned, see below
  GPIO       0x1000_1000 to 0x1000_1003  one 32-bit register, with byte writes
  counters   0x1000_2000 to 0x1000_2007  what the hardware returned
  timer      0x1000_3000 to 0x1000_300F  what the hardware returned
  AXI4-Lite  0x2000_0000 to 0x2000_001F  reg0 to reg3, ID at 0x10 that refuses
                                         writes, and nothing from 0x14 up
  anything else                          an access fault

The UART, the counters and the timer change by themselves, with time, so no
model without a clock can know what a read returns. For those three, the
lockstep checker writes each word the bus returned into observed before the
model runs the instruction. Writes to them change nothing here.

Nothing in this file comes from the RTL. It is written from the table above.
"""

from iss import MASK

RAM_BYTES = 0x1_0000
UART, GPIO, COUNTERS, TIMER, AXIL = 0x1000_0000, 0x1000_1000, 0x1000_2000, 0x1000_3000, 0x2000_0000
AXIL_ID = 0x4158_494C

# Devices whose reads the model cannot predict.
OBSERVED = ("uart", "counters", "timer")


def region(address):
    """Which device owns a byte address, or None."""
    if address < RAM_BYTES:
        return "ram"
    if UART <= address < UART + 8:
        return "uart"
    if GPIO <= address < GPIO + 4:
        return "gpio"
    if COUNTERS <= address < COUNTERS + 8:
        return "counters"
    if TIMER <= address < TIMER + 16:
        return "timer"
    if AXIL <= address < AXIL + 0x20:
        return "axil"
    return None


class SocMemory:
    def __init__(self, words=(), data=None):
        self.ram = bytearray(RAM_BYTES)
        for index, word in enumerate(words):
            self.ram[4 * index: 4 * index + 4] = (word & MASK).to_bytes(4, "little")
        for address, word in (data or {}).items():
            self.ram[address: address + 4] = (word & MASK).to_bytes(4, "little")
        self.gpio = 0
        self.axil = [0, 0, 0, 0]
        self.observed = {}          # word address -> the last word the bus returned

    def faults(self, address, count, write):
        """Would this access get err on the bus? The access is aligned."""
        where = region(address)
        if where is None:
            return True
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
        if where == "gpio":
            return self.gpio
        if where == "axil":
            offset = base - AXIL
            return AXIL_ID if offset == 0x10 else self.axil[offset // 4]
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
        if where == "gpio":
            self.gpio = (self.gpio & ~mask & MASK) | data
        elif where == "axil" and address - AXIL < 0x10:
            index = (address - AXIL) // 4
            self.axil[index] = (self.axil[index] & ~mask & MASK) | data
