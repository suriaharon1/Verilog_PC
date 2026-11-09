# rtl/core

The RV32 CPU core. Planned modules (see ROADMAP.md section 4.1):

| Module | Milestone | Purpose |
|--------|-----------|---------|
| `regfile.v` | M1 | 32 x 32-bit registers, 2 read ports, 1 write port, x0 hardwired to 0 |
| `alu.v` | M1 | add, sub, shifts, compares, logic ops |
| `decode.v` | M1 | Field extraction, immediate generation, control signals, illegal instruction detect |
| `lsu.v` | M1 | Loads and stores with byte enables and sign/zero extension |
| `core_top.v` | M1 | Fetch, next-PC logic, and wiring of the above |
| `muldiv.v` | M2 | Multiplier and 32-cycle iterative divider |
| `csr.v` | M4 | CSR file and trap unit |
| `mmu.v` | M8 | Sv32 page table walker and TLB |
