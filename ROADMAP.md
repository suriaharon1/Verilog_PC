# Verilog PC: Linux-Capable RISC-V SoC

A RISC-V CPU and system-on-chip written from scratch in Verilog, built up in stages until it boots Linux, first in simulation and then on an FPGA.

**Owner:** Aharon Suri
**Repo:** `Verilog_PC-`
**Built with:** AI assistance (Claude Code). Every module must be understood well enough to explain and defend in an interview.

---

## 1. Project goals

1. **Primary goal:** an RV32IMA core that boots a nommu Linux kernel to a BusyBox shell in Verilator.
2. **Secondary goal:** the same system running on a real FPGA board.
3. **Stretch goal:** S-mode, U-mode, and an Sv32 MMU so it boots full (MMU) Linux with OpenSBI.
4. **Career goal:** a project that strengthens applications for RTL design, verification, and architecture roles (AMD, NVIDIA, Micron, TSMC, FPGA teams at HFT firms), for the Fall 2027 co-op and new grad recruiting.

### Guiding principles

- **Simulation first.** Nothing goes on an FPGA until it works in Verilator.
- **Tests are the source of truth.** Code is not "done" until the official tests pass.
- **Small steps.** Build one module, test it, commit it, then move on.
- **Design for extension.** Every milestone should add to the core, not force a rewrite.
- **Understand everything.** If a module can't be explained on a whiteboard, it isn't finished.
- **Precise claims.** Describe exactly what works ("boots nommu Linux in Verilator"), never round up.

---

## 2. Milestones

| # | Milestone | Done when | Target |
|---|-----------|-----------|--------|
| M0 | Toolchain and repo setup | All tools verified, repo cloned | Done (Nov 9, 2026) |
| M1 | RV32I core | All `rv32ui-p-*` tests pass in Verilator | Done (Nov 9, 2026) |
| M1.5 | Lockstep verification | Core trace compared against Spike, first mismatch reported automatically | Done (Nov 10, 2026) |
| M2 | M extension | All `rv32um-p-*` tests pass | Nov 2026 |
| M3 | A extension | All `rv32ua-p-*` tests pass | Late Nov 2026 |
| M4 | CSRs, M-mode traps, interrupts | All `rv32mi-p-*` tests pass; bare-metal C prints over UART; timer interrupt fires | Dec 2026 |
| M5 | SoC plus nommu Linux in simulation | Linux boots to a BusyBox shell in Verilator | Jan to Feb 2027 |
| M6 | FPGA bring-up | Bare-metal, then nommu Linux, running on a real board | Spring 2027 |
| M7 | S-mode, U-mode, delegation | Privilege tests pass | Summer 2027 |
| M8 | Sv32 MMU plus full Linux | Full Linux boots with OpenSBI | Summer 2027 |
| M9 | Polish | README, metrics, demo video, clean history | Before Aug 2027 recruiting |

Targets assume roughly an hour a day plus AI help. They are guides, not deadlines. The key date is having at least M5 done and documented before new grad and co-op recruiting opens around August 2027.

---

## 3. System architecture

```
+--------------------------------------------------------------+
|                         SoC (top)                            |
|                                                              |
|   +------------------------------------------------------+   |
|   |                      CPU core                        |   |
|   |  Fetch -> Decode -> Execute -> Memory -> Writeback   |   |
|   |     Regfile      CSR file / trap unit     (MMU)      |   |
|   +--------------------------+---------------------------+   |
|                              |                               |
|   +--------------------------+---------------------------+   |
|   |            System bus and address decoder            |   |
|   +----+----------+----------+----------+----------+-----+   |
|        |          |          |          |          |         |
|   Boot ROM      RAM        CLINT      PLIC       UART        |
+--------------------------------------------------------------+
```

### Memory map

This matches the QEMU `virt` machine where possible, so existing device trees and kernel configs need minimal changes.

| Region | Base address | Size | Notes |
|--------|--------------|------|-------|
| Boot ROM | `0x0000_1000` | 4 KB | First instructions after reset (added in M5/M6) |
| CLINT | `0x0200_0000` | 64 KB | `msip` at +0x0, `mtimecmp` at +0x4000, `mtime` at +0xBFF8 |
| PLIC | `0x0C00_0000` | 64 MB window | External interrupts (can be deferred) |
| UART (16550) | `0x1000_0000` | 256 B | Console, uses Linux's existing 8250/16550 driver |
| RAM | `0x8000_0000` | 64 MB | riscv-tests and Linux both expect RAM here |

**Reset vector:** `0x8000_0000` during M1 to M4 (the testbench loads programs straight into RAM). Moves to the boot ROM once the SoC exists.

---

## 4. Component breakdown

### 4.1 CPU core

#### Fetch
- **Goal:** produce the address and bits of the next instruction.
- **Contains:** PC register, next-PC mux, instruction memory interface.
- **Next-PC sources:** PC+4, branch target, JAL/JALR target, `mtvec` (trap), `mepc` (mret). Later: `stvec`, `sepc`.
- **Gotcha:** no C (compressed) extension is planned. All software must be built with `-march=rv32ima -mabi=ilp32` and the kernel with `CONFIG_RISCV_ISA_C=n`. Forgetting this is the most common cause of a crash on the first kernel instruction.

#### Decode
- **Goal:** turn a 32-bit instruction into control signals and operands.
- **Contains:** field extraction (opcode, funct3, funct7, rs1, rs2, rd), immediate generation (I, S, B, U, J formats, plus CSR zimm), control signal generation.
- **Rule:** any unrecognized encoding raises an illegal instruction trap with the instruction bits in `mtval`. Never silently treat unknown opcodes as no-ops.

#### Register file
- **Goal:** hold the 32 architectural registers.
- **Contains:** 32 x 32-bit registers, 2 read ports, 1 write port.
- **Rule:** `x0` always reads 0 and ignores writes.

#### Execute
- **Goal:** compute results and branch decisions.
- **ALU:** add, sub, sll, srl, sra (shift amount is the low 5 bits only), slt, sltu, and, or, xor, lui/auipc support.
- **Branch unit:** beq, bne, blt, bge, bltu, bgeu.
- **Multiplier (M2):** mul, mulh, mulhsu, mulhu. Watch the signed/unsigned mix in mulhsu.
- **Divider (M2):** div, divu, rem, remu. A 32-cycle iterative divider is fine. Required edge cases (no trap):
  - Divide by zero: quotient = all ones, remainder = dividend.
  - Signed overflow (-2^31 / -1): quotient = -2^31, remainder = 0.

#### Memory (load/store unit)
- **Goal:** all data memory access.
- **Loads/stores:** lb, lh, lw, lbu, lhu, sb, sh, sw, with byte enables and sign/zero extension.
- **Misaligned access:** handle in hardware (split into two bus accesses) or raise a misaligned exception. Since nommu Linux has no OpenSBI to emulate them, hardware handling is the safer choice.
- **fence / fence.i:** no-ops while there are no caches.

#### Atomics (M3)
- **LR/SC:** a reservation register (address plus valid bit). LR sets it. SC succeeds only if it is still valid for that address, writing 0 to rd on success and 1 on failure. Clear the reservation on every SC and on every trap or mret.
- **AMOs:** amoswap, amoadd, amoand, amoor, amoxor, amomin, amomax, amominu, amomaxu. Each is load, compute, store, with the old value written to rd.
- The aq/rl bits can be ignored on a single in-order core.

#### CSR file and trap unit (M4)
- **Goal:** privileged state, exceptions, and interrupts. This is where most Linux boot bugs live.
- **M-mode CSRs:** `mstatus`, `misa`, `mhartid` (hardwired 0), `mtvec`, `mepc`, `mcause`, `mtval`, `mie`, `mip`, `mscratch`, plus `cycle`/`cycleh`, `time`/`timeh`, `instret`/`instreth`.
- **Instructions:** csrrw, csrrs, csrrc, csrrwi, csrrsi, csrrci, ecall, ebreak, mret, wfi (wfi can be a no-op).
- **Trap entry (one step):**
  1. `mepc` <- PC of the faulting instruction (or the next PC for interrupts)
  2. `mcause` <- cause code (top bit set for interrupts)
  3. `mtval` <- bad address or bad instruction bits
  4. `mstatus.MPIE` <- `mstatus.MIE`, then `mstatus.MIE` <- 0
  5. `mstatus.MPP` <- current privilege, privilege <- M
  6. PC <- `mtvec`
- **mret:** `MIE` <- `MPIE`, `MPIE` <- 1, privilege <- `MPP`, PC <- `mepc`.
- **Interrupts:** checked between instructions. Taken when `(mip & mie) != 0` and `mstatus.MIE` is set (or current privilege is lower than M). Priority: external, then software, then timer. `mip.MTIP` comes from the CLINT comparing `mtime >= mtimecmp`.
- **Wire `mtime` into the `time` CSR** so reads don't need to trap.

#### Phase two additions (M7, M8)
- **Privilege:** S-mode and U-mode, a 2-bit privilege register.
- **Delegation:** `medeleg` and `mideleg` route page faults, U-mode ecalls, and S-mode interrupts straight to `stvec`.
- **S-mode CSRs:** `stvec`, `sepc`, `scause`, `stval`, `sscratch`, `satp`.
- **Gotcha:** `sstatus`, `sie`, and `sip` are restricted views of `mstatus`, `mie`, and `mip`, not separate registers.
- **Counter access:** `mcounteren` and `scounteren`.

#### MMU (M8)
- **Goal:** Sv32 virtual memory.
- **satp:** mode bit (bare or Sv32) plus root page table PPN.
- **Page table walker:** two-level walk, 4 KB pages and 4 MB megapages.
- **PTE checks:** V, R, W, X, U bits, plus `SUM` and `MXR` in `sstatus`.
- **A/D bits:** raise a page fault when one needs setting; Linux handles it.
- **TLB:** 4 to 16 entries is enough. `sfence.vma` can flush everything.
- **Page faults:** instruction (cause 12), load (13), store/AMO (15), faulting virtual address in `stval`.
- Translation applies to fetch and data accesses, and is bypassed in M-mode.

### 4.2 Memory system

- **System bus:** Wishbone (simpler than AXI, plenty for this project). Keep the core's memory interface simple enough to adapt later.
- **Address decoder:** routes each access to a device by the memory map above. Unmapped addresses should return an access fault, not garbage.
- **Boot ROM:** small block RAM holding the first code after reset; jumps to RAM.
- **RAM:** a large array in simulation, loaded from a hex file. On FPGA, use LiteDRAM or the vendor's DRAM IP. **Do not write a DDR controller.**
- **Caches:** optional, only if FPGA boot is too slow.

### 4.3 Peripherals

- **CLINT (required):** `mtime` (64-bit, free-running), `mtimecmp` (64-bit), `msip`. Drives the timer and software interrupts. Linux needs it for scheduling.
- **UART (required):** 16550-compatible register layout so Linux's built-in driver works with no kernel code. In simulation, the testbench prints transmitted bytes to the terminal.
- **PLIC (deferrable):** routes external interrupts such as UART receive. The console can poll at first, but an interactive shell wants this.
- **Storage (optional):** not needed; the root filesystem is an initramfs built into the kernel image.

### 4.4 Software stack

- **Toolchain:** `riscv64-unknown-elf-gcc` with `-march=rv32ima -mabi=ilp32` for bare metal; a riscv32 Linux toolchain from Buildroot for the kernel and userspace.
- **Bare-metal programs (M4):** startup assembly, a linker script placing code at `0x8000_0000`, a tiny `putchar` over the UART, a timer interrupt demo.
- **Device tree:** describes the memory map, UART (`ns16550a`), CLINT (`riscv,clint0`), timebase frequency, and the CPU's ISA string (`rv32ima`). This is the contract between hardware and kernel.
- **Linux kernel (M5):** nommu build with `CONFIG_RISCV_M_MODE=y`, `CONFIG_MMU=n`, `CONFIG_RISCV_ISA_C=n`, 16550 console, built-in initramfs. In nommu mode the kernel runs directly in M-mode.
- **Root filesystem:** Buildroot with BusyBox, packed as an initramfs.
- **OpenSBI (M8 only):** M-mode firmware below an S-mode kernel.

---

## 5. Verification strategy

| Layer | Tool | Purpose |
|-------|------|---------|
| ISA compliance | riscv-tests (`rv32ui`, `rv32um`, `rv32ua`, `rv32mi`) | Prove each instruction and trap works |
| Broader compliance | riscv-arch-test | Second opinion before claiming "compliant" |
| Lockstep | Spike (`--log-commits`) vs core trace | Find the exact instruction where behavior diverges |
| Waveforms | Verilator `--trace-fst` plus Surfer | Debug cycle by cycle |
| Lint | `verilator --lint-only -Wall` | Catch width mismatches and latches early |
| Formal (stretch) | riscv-formal | Strongest correctness evidence for interviews |

### riscv-tests pass/fail convention
The tests signal results by writing to the `tohost` symbol. The testbench watches stores to that address:
- Value `1` means pass.
- Any other odd value means fail, and `value >> 1` is the failing test case number.
- Add a cycle timeout so a hung test fails instead of running forever.

### Lockstep plan (M1.5)
1. Have the testbench log every retired instruction: PC, instruction bits, destination register, and written value.
2. Run the same ELF through `spike --isa=rv32ima --log-commits`.
3. A script compares both logs and reports the first mismatch.

This turns "Linux hangs 40 million cycles in" into "instruction 12,345,678 wrote the wrong value to a5."

---

## 6. Repo layout

```
Verilog_PC-/
  rtl/
    core/        fetch, decode, regfile, alu, muldiv, lsu, csr, (mmu), core_top
    soc/         bus, address decoder, soc_top
    periph/      uart16550, clint, plic, bootrom
  sim/           Verilator testbench (C++), memory loader, tohost watcher
  tests/         riscv-tests (git submodule), custom tests
  sw/
    baremetal/   startup.S, linker.ld, hello, timer demo
    linux/       device tree, kernel config, Buildroot config
  scripts/       run_tests.sh, lockstep compare, helpers
  fpga/          board constraints and build scripts (M6)
  docs/          this roadmap, design notes, diagrams
  Makefile
  README.md
```

---

## 7. Environment (verified Nov 9, 2026)

| Tool | Version | Use |
|------|---------|-----|
| macOS Command Line Tools | 27.2 | Build prerequisites |
| Verilator | 5.054 | Main simulator |
| Icarus Verilog | 13.0 | Backup simulator |
| riscv64-unknown-elf-gcc | 16.1.0 | Bare-metal RISC-V compiler (rv32 builds verified) |
| Spike | from riscv-tools | Reference simulator for lockstep |
| Surfer | 0.7.0 | Waveform viewer |

**FPGA board:** not chosen yet. Linux needs a board with external DRAM (for example a Digilent Arty A7-100T). Boards without DRAM can still run the bare-metal milestones.

---

## 8. Workflow rules (for Claude Code and for me)

- Work one module or one feature at a time.
- After writing a module, explain how it works and why the design choices were made before moving on.
- Run the relevant tests as soon as possible. Fix failures one at a time.
- Commit to git after every working step, with a clear message.
- Never mark a milestone done unless its tests pass.
- Keep the core's interfaces stable so later milestones extend it instead of rewriting it.
- Lint with `verilator -Wall` and keep it warning-free.
- **Code style:** in C and C++ code, put braces on their own line (Allman style) for if/else and loops.
- **Writing style:** no em dashes in docs or comments.

---

## 9. Resume and portfolio logistics

### Metrics to record as they become available
- Tests passed (which suites, how many)
- CPI or cycles per instruction on a benchmark
- Linux boot time in simulation (cycles and wall-clock)
- FPGA: Fmax, LUT/FF/BRAM/DSP usage, boot time on hardware
- Lines of RTL, number of modules

### Deliverables for M9
- README with an architecture diagram, memory map, how to build and run, and test results
- A short demo video: boot log scrolling to a BusyBox shell (FPGA if possible)
- A resume bullet with real numbers, for example: "Designed an RV32IMA RISC-V CPU and SoC in Verilog that passes the official riscv-tests and boots nommu Linux in Verilator; verified with lockstep comparison against Spike."

### Interview prep
Be ready to explain, without notes:
- The full trap entry and mret sequence
- Why Linux needs the A extension
- How LR/SC works and when a reservation is lost
- How interrupts are prioritized and when they're taken
- Why `sstatus` is a view of `mstatus`
- How the device tree tells the kernel about the hardware
- How a page table walk works (after M8)
- How the design was verified, and the hardest bug found

---

## 10. Out of scope (for now)

- Pipelining (revisit after Linux boots, as a performance project)
- C (compressed) extension
- Floating point (F/D)
- Multi-core
- Writing a DDR controller
- Caches (unless FPGA performance demands them)
