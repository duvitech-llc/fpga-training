"""The reference model for the whole system: Tutorial 21's Iss, unchanged, with a
memory that follows soc_map.vh, and access faults where the bus answers err.

This is Tutorial 28's soc_model.py, for this lesson's map:

  RAM            0x0000_0000 to 0x0000_FFFF  bytes, as in iss.py
  GPIO           0x1000_1000 to 0x1000_1003  one 32-bit register, with byte writes
  counters       0x1000_2000 to 0x1000_2007  what the hardware returned
  cache control  0x1000_7000 to 0x1000_700F  what the hardware returned. Writes
                                             change nothing the program can see
  XIP flash      0x4000_0000 to 0x40FF_FFFF  the flash's bytes. The model's flash
                                             is 64 KiB, so addresses wrap, as the
                                             flash model's do. A write faults
  anything else                              an access fault

There is no cache here. The model is what the program should see, so the
lockstep test shows the cache cannot be seen, except in its timing and in the
counters, which are copied from the bus like the clock counters.

Nothing in this file comes from the RTL. It is written from the table above.
"""

from iss import LOAD_NAMES, MASK, STORE_NAMES, Iss, Retired, fields, immediate, mnemonic

RAM_BYTES = 0x1_0000
GPIO, COUNTERS, CACHECTL = 0x1000_1000, 0x1000_2000, 0x1000_7000
XIP, XIP_BYTES, FLASH_BYTES = 0x4000_0000, 0x100_0000, 0x1_0000

CAUSE_FETCH_FAULT = 1
CAUSE_LOAD_FAULT = 5
CAUSE_STORE_FAULT = 7

FAULT_NAMES = ["FETCH_FAULT", "LOAD_FAULT", "STORE_FAULT"]
OBSERVED = ("counters", "cachectl")


def region(address):
    """Which device owns a byte address, or None."""
    if address < RAM_BYTES:
        return "ram"
    if GPIO <= address < GPIO + 4:
        return "gpio"
    if COUNTERS <= address < COUNTERS + 8:
        return "counters"
    if CACHECTL <= address < CACHECTL + 16:
        return "cachectl"
    if XIP <= address < XIP + XIP_BYTES:
        return "xip"
    return None


class SocMemory:
    def __init__(self, ram=b"", flash=b""):
        self.ram = bytearray(RAM_BYTES)
        self.ram[:len(ram)] = ram
        self.flash = bytearray(b"\xFF" * FLASH_BYTES)
        self.flash[:len(flash)] = flash
        self.gpio = 0
        self.observed = {}          # word address -> the last word the bus returned

    def faults(self, address, count, write):
        """Would this access get err on the bus? The access is aligned."""
        where = region(address)
        if where is None:
            return True
        if where == "xip":
            return write
        return False

    def word(self, address):
        """The 32-bit word that holds this byte address."""
        base = address & ~3
        where = region(address)
        if where == "ram":
            return int.from_bytes(self.ram[base: base + 4], "little")
        if where == "xip":
            offset = (base - XIP) % FLASH_BYTES
            return int.from_bytes(self.flash[offset: offset + 4], "little")
        if where == "gpio":
            return self.gpio
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


class SocIss(Iss):
    """Iss with access faults, from Tutorial 26. Before an instruction runs, it
    asks the memory whether the fetch, or an aligned load or store, would get err.
    If so, it stops with the fault's mcause code, as the system does. Everything
    else is Iss.step."""

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
