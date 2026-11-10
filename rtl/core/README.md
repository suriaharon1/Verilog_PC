# rtl/core

The RV32 CPU core. Planned modules (see ROADMAP.md section 4.1):

| Module | Milestone | Purpose |
|--------|-----------|---------|
| `core_defs.vh` | M1 | Shared opcode, ALU op, and cause code definitions |
| `regfile.v` | M1 | 32 x 32-bit registers, 2 read ports, 1 write port, x0 hardwired to 0 |
| `alu.v` | M1 | add, sub, shifts, compares, logic ops |
| `branch_unit.v` | M1 | Branch condition evaluation |
| `decode.v` | M1 | Field extraction, immediate generation, control signals, illegal instruction detect |
| `lsu.v` | M1 | Loads and stores with byte enables and sign/zero extension |
| `core_top.v` | M1 | Multi-cycle FSM (FETCH, EXEC, MEM), next-PC logic, wiring, retire trace |
| `muldiv.v` | M2 | Multiplier and 32-cycle iterative divider |
| `csr.v` | M1 (minimal), M4 (full) | CSR file and trap state; nonexistent CSRs trap |
| `mmu.v` | M8 | Sv32 page table walker and TLB |
