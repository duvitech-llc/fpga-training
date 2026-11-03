# FPGA Training

Tutorials and documentation for learning digital design in Verilog. Designs are
taught and verified in simulation, so no FPGA board is needed.

## Tutorials

| # | Tutorial                                       | Topics                           |
| - | ---------------------------------------------- | -------------------------------- |
| 1 | [D flip-flop](tutorials/01-d-flip-flop/README.md) | A tour of every tool in the environment |
| 2 | [Counter](tutorials/02-counter/README.md) | Vectors, parameters, combinational outputs and formal assumptions |
| 3 | [Shift register](tutorials/03-shift-register/README.md) | Concatenation, part-selects, serial and parallel, blocking vs nonblocking |
| 4 | [ALU](tutorials/04-alu/README.md) | Combinational always blocks, `case`, default assignments, inferred latches |
| 5 | [Sequence detector](tutorials/05-sequence-detector/README.md) | Finite state machines, state encoding, `cover` and vacuous proofs |
| 6 | [Synchronous RAM](tutorials/06-sync-ram/README.md) | Arrays, read-during-write, block RAM inference, symbolic formal |
| 7 | [Synchronous FIFO](tutorials/07-sync-fifo/README.md) | Pointers, full and empty, read latency, ordering proofs |
| 8 | [Arbiter](tutorials/08-arbiter/README.md) | One-hot, fixed vs round-robin priority, starvation, fairness proofs |
| 9 | [Skid buffer](tutorials/09-skid-buffer/README.md) | Valid/ready handshakes, backpressure, input assumptions |
| 10 | [Asynchronous FIFO](tutorials/10-async-fifo/README.md) | Gray code, two-flop synchronizers, multiclock formal, limits of simulation |
| 11 | [Register file](tutorials/11-register-file/README.md) | `generate`, hierarchy, register file with two read ports |
| 12 | [ALU with status flags](tutorials/12-flags-alu/README.md) | Two's complement, carry and overflow, Verilog signed pitfalls |
| 13 | [Clock crossings and resets](tutorials/13-cdc-reset/README.md) | Level and pulse synchronizers, reset synchronizers |
| 14 | [UART](tutorials/14-uart/README.md) | Serial transmit and receive, mid-bit sampling, clock tolerance |
| 15 | [Pipelining](tutorials/15-pipelining/README.md) | Critical paths, latency vs throughput, valid bits, alignment |
| 16 | [Instruction set and assembler](tutorials/16-instruction-set/README.md) | Instruction set design, decoder, two-pass Python assembler |
| 17 | [The CPU](tutorials/17-cpu/README.md) | Datapath and control, fetch-decode-execute, the stack in hardware |
| 18 | [Checking the CPU](tutorials/18-cpu-verification/README.md) | Reference model, lockstep, coverage, per-instruction proofs |
| 19 | [The computer](tutorials/19-computer/README.md) | Memory-mapped I/O, a program printing through the UART |
| 20 | [The pipelined CPU](tutorials/20-pipelined-cpu/README.md) | Five-stage pipeline, hazards, forwarding, stalls, flushing |
| 21 | [A RISC-V core](tutorials/21-riscv-core/README.md) | RV32I, a multi-cycle core with PicoRV32's memory interface, an instruction set simulator, lockstep |
| 22 | [Wishbone bus](tutorials/22-wishbone/README.md) | Wishbone B4 pipelined, an interconnect, address decoding, a protocol checker |
| 23 | [AXI4-Lite](tutorials/23-axi4-lite/README.md) | Five channels, independent handshakes, a protocol checker, comparison with Wishbone |
| 24 | [SPI controller](tutorials/24-spi/README.md) | SPI modes, clock division, a flash model |
| 25 | [LFSRs and CRCs](tutorials/25-lfsr-crc/README.md) | Linear feedback shift registers, CRC-32 a byte at a time |
| 26 | [The core on the bus](tutorials/26-core-on-bus/README.md) | A bus bridge, memory-mapped peripherals, programs in assembly |
| 27 | [Timer and interrupts](tutorials/27-interrupts/README.md) | Machine mode, CSRs, traps, a timer, programs in C |
| 28 | [Booting from SPI flash](tutorials/28-spi-boot/README.md) | A boot ROM, loading and checking a program image |
| 29 | [DMA and a second bus master](tutorials/29-dma/README.md) | A DMA engine, bus arbitration between masters |
| 30 | [Instruction cache](tutorials/30-icache/README.md) | A direct-mapped cache, execute in place from flash, hit rates |
| 31 | [A small system-on-chip](tutorials/31-soc/README.md) | Integration, a memory map, sharing the flash pins, an interrupt controller |
| 32 | [Video timing and a test pattern](tutorials/32-video-timing/README.md) | VGA timing, colour bars, frames written to PNG |
| 33 | [DVI/HDMI output and a live view](tutorials/33-dvi-live/README.md) | TMDS encoding and DC balance, a framebuffer, a second clock domain, a live view of the simulated screen |

## Environment

All tools run in a Docker container, and you use them through VS Code in your
web browser. The only requirements are:

- **To run the container:** Docker with the Compose plugin
- **To use it:** a web browser

The image targets x64. On an Apple Silicon Mac it runs under emulation, which
is slower.

### Tools

| Tool             | Version in the image | Used for                                   |
| ---------------- | -------------------- | ------------------------------------------ |
| Icarus Verilog   | 14.0 (devel)         | Main simulator for tutorials               |
| Verilator        | 5.053 (devel)        | Strict linting and fast simulation         |
| cocotb           | 2.1.0 (dev)          | Testbenches written in Python              |
| Yosys            | 0.70+286             | Synthesis, resource counts and schematics  |
| sby              | Bundled              | Formal verification                        |
| code-server      | 4.144.0              | VS Code in the browser                     |
| VaporView        | 1.6.0                | Waveform viewer inside VS Code             |
| RISC-V GCC       | 15.2.0 (xPack)       | C programs for the RISC-V core, from Tutorial 27 |

The EDA tools come from the [OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build).
It is published as nightly builds, so `docker/Dockerfile` pins one dated
release and its checksum to give everyone identical tools. To upgrade, change
the versions and checksums at the top of that file and rebuild.

### Build the image

From the repository root:

```bash
docker compose build
```

The first build downloads about 1.5 GB, and the image takes about 7 GB of disk.

### Open VS Code in the browser

```bash
docker compose up -d ide
```

Then open <http://localhost:8080> and log in with the password
`fpga-training`. The repository is mounted at `/work`, so files you change are
kept on the host. Open a terminal with **Terminal > New Terminal**; all the
tools are on its path.

A few things seen while checking the tutorials in the browser:

- `build/` is hidden from Quick Open (Ctrl+P), because `.gitignore` lists it. Open
  generated files from the Explorer, or with **File > Open File...**.
- At some zoom levels VaporView 1.6.0 once drew `clk` as an empty row, and zooming
  again redrew it. If a signal looks blank, change the zoom before trusting it.
- With the repository on a Windows drive (Docker Desktop), VS Code is not told when
  a file under `/work` changes, so an image open in the preview does not reload.
  Reopen it, or write it to the container's own `/tmp`, as Tutorial 33's live view
  does. A copy of the repository inside WSL 2's own Linux file system did reload.

Stop the server when you are finished:

```bash
docker compose down
```

Two optional settings can be set before starting the server:

```bash
export IDE_PASSWORD=choose-a-password
export IDE_PORT=8081
```

The port only accepts connections from the same machine. Serving trainees from
a shared host also needs HTTPS and a separate container and workspace for each
person, none of which is set up here. Do not simply open the port.

### Use the tools without a browser

To work from a terminal or your own editor instead, start a shell in the
container:

```bash
docker compose run --rm sim
```

Or run a single command by adding it after `sim`:

```bash
docker compose run --rm sim make -C tutorials/01-d-flip-flop sim
```

The container runs as UID/GID 1000 by default. If `id -u` or `id -g` prints
something else on your machine, set these first so generated files are owned
by you:

```bash
export HOST_UID=$(id -u) HOST_GID=$(id -g)
```

### Target FPGAs

Yosys reports resource use for the families we work with:

| Family               | Yosys command                        |
| -------------------- | ------------------------------------ |
| Xilinx 7 Series      | `synth_xilinx -family xc7`           |
| Gowin                | `synth_gowin`                        |
| Intel Cyclone V      | `synth_intel_alm -family cyclonev`   |

These counts are for comparing designs and families. They will not match
Vivado, Gowin EDA or Quartus exactly, and they say nothing about timing.
Programming a device requires the vendor's tools, which are not part of this
environment.
