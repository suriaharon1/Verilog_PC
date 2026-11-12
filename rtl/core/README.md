# rtl/core

The RV32IM CPU core. Modules, current and planned:

| Module | Milestone | Purpose |
|--------|-----------|---------|
| `core_defs.vh` | M1 | Shared opcode, ALU op, and cause code definitions |
| `regfile.v` | M1 | 32 x 32-bit registers, 2 read ports, 1 write port, x0 hardwired to 0 |
| `alu.v` | M1 | add, sub, shifts, compares, logic ops |
| `branch_unit.v` | M1 | Branch condition evaluation |
| `decode.v` | M1 | Field extraction, immediate generation, control signals, illegal instruction detect |
| `lsu.v` | M1 | Loads and stores with byte enables and sign/zero extension |
| `core_top.v` | M1 | Multi-cycle FSM (FETCH, EXEC, MEM, MULDIV), next-PC logic, wiring, retire trace |
| `muldiv.v` | M2 | 33x33 signed multiplier (2 cycles) and 32-step restoring divider (34 cycles) |
| `csr.v` | M1 (minimal), M4 (full) | CSR file and trap state; nonexistent CSRs trap |
| `mmu.v` | M8 | Sv32 page table walker and TLB |
