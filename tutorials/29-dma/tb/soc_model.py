"""The reference model for the whole system: Tutorial 21's Iss, unchanged, with a
memory that follows soc_map.vh, and access faults where the bus answers err.

Copied from Tutorial 26, with the DMA engine's registers added, and a way for the
lockstep checker to apply the DMA engine's writes.

iss.py's Memory is 64 KiB that repeats through the whole address space. Here the
address decides what is there:

  RAM        0x0000_0000 to 0x0000_FFFF  bytes, as in iss.py
  UART       0x1000_0000 to 0x1000_0007  what the hardware returned, see below
  GPIO       0x1000_1000 to 0x1000_1003  one 32-bit register, with byte writes
  counters   0x1000_2000 to 0x1000_2007  what the hardware returned
  DMA        0x1000_5000 to 0x1000_5013  what the hardware returned. Nothing from
                                         0x1000_5014 to 0x1000_501F: an access fault
  AXI4-Lite  0x2000_0000 to 0x2000_001F  reg0 to reg3, ID at 0x10 that refuses
                                         writes, and nothing from 0x14 up
  anything else                          an access fault

The UART, the counters and the DMA engine's registers change by themselves, with
time, so no model without a clock can know what a read returns. For those three,
the lockstep checker writes each word the bus returned into observed before the
model runs the instruction. Writes to them change nothing here.

The DMA engine also writes memory, at times the model cannot know. The lockstep
checker sees each of those writes on the bus and passes it to dma_write, in bus
order with the core's own accesses. See lockstep.py.

Nothing in this file comes from the RTL. It is written from the table above.
"""

from iss import LOAD_NAMES, MASK, STORE_NAMES, Iss, Retired, fields, immediate, mnemonic

RAM_BYTES = 0x1_0000
UART, GPIO, COUNTERS, AXIL = 0x1000_0000, 0x1000_1000, 0x1000_2000, 0x2000_0000
DMA = 0x1000_5000
AXIL_ID = 0x4158_494C

CAUSE_FETCH_FAULT = 1
CAUSE_LOAD_FAULT = 5
CAUSE_STORE_FAULT = 7

FAULT_NAMES = ["FETCH_FAULT", "LOAD_FAULT", "STORE_FAULT"]


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
    if AXIL <= address < AXIL + 0x20:
        return "axil"
    if DMA <= address < DMA + 0x20:
        return "dma"
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
        if where == "dma" and address - DMA >= 0x14:
            return True                             # no register there
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

    def dma_write(self, word_address, sel, data):
        """A write by the DMA engine, as it went on the bus: the byte address of the
        word, the byte lanes in sel, and the 32-bit data. A write that gets err
        changes nothing, as for the core."""
        for lane in range(4):
            if sel >> lane & 1:
                address = word_address + lane
                if not self.faults(word_address, 4, write=True):
                    self.write(address, 1, (data >> (8 * lane)) & 0xFF)


class SocIss(Iss):
    """Iss with access faults. Before an instruction runs, it asks the memory
    whether the fetch, or an aligned load or store, would get err. If so, it stops
    with the fault's mcause code, as the system does. Everything else is Iss.step.
    A misaligned access still traps as misaligned, since the core never puts it on
    the bus."""

    def step(self):
        if self.stopped:
            raise RuntimeError("the model has trapped, and only a reset leaves that")
        pc = self.pc

        def fault(cause, name, instr=0):
            self.stopped = True
            return Retired(pc=pc, instr=instr, name=name, next_pc=pc, rd=None, rd_value=0,
                           write=None, read=None, trap=cause)

        if self.mem.faults(pc, 4, write=False):
            return fault(CAUSE_FETCH_FAULT, "FETCH_FAULT")

        instr = self.mem.read(pc, 4)
        name = mnemonic(instr)
        f = fields(instr)
        if name in LOAD_NAMES.values() or name in STORE_NAMES.values():
            store = name in STORE_NAMES.values()
            address = (self.x[f["rs1"]] + immediate(instr, "S" if store else "I")) & MASK
            count = {"B": 1, "H": 2, "W": 4}[name[1]]
            if address % count == 0 and self.mem.faults(address, count, write=store):
                if store:
                    return fault(CAUSE_STORE_FAULT, "STORE_FAULT", instr)
                return fault(CAUSE_LOAD_FAULT, "LOAD_FAULT", instr)
        return super().step()
