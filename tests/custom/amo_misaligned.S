# amo_misaligned.S
# Custom test: misaligned atomics must trap, not be split.
#
# The official rv32ua tests only use aligned addresses. A misaligned
# AMO/LR/SC must raise an address-misaligned OR an access-fault exception
# (the spec allows either). This core, like Spike, raises access fault, which
# tells software not to emulate the access:
#   lr.w            -> cause 5 (load access fault)
#   sc.w, amo*.w    -> cause 7 (store/AMO access fault)
#   mtval           =  the misaligned address
# and memory must be left unchanged.
#
# The trap handler checks mcause and mtval, records that it ran, and skips
# the faulting instruction.

#include "riscv_test.h"
#include "test_macros.h"

RVTEST_RV32U
RVTEST_CODE_BEGIN

  la s0, data

  # 2: misaligned amoadd.w traps with cause 7, memory unchanged
  li TESTNUM, 2
  li s1, 0                  # set to 1 by the handler
  li s2, 7                  # expected mcause
  addi a0, s0, 1            # misaligned address
  li a2, 0x100
  amoadd.w a1, a2, (a0)
  beqz s1, fail
  lw t1, 0(s0)
  li t2, 0x11223344
  bne t1, t2, fail
  lw t1, 4(s0)
  li t2, 0x55667788
  bne t1, t2, fail

  # 3: misaligned amoswap.w at offset 2 traps with cause 7
  li TESTNUM, 3
  li s1, 0
  li s2, 7
  addi a0, s0, 2
  amoswap.w a1, a2, (a0)
  beqz s1, fail
  lw t1, 0(s0)
  li t2, 0x11223344
  bne t1, t2, fail

  # 4: misaligned lr.w traps with cause 5 (it is a load)
  li TESTNUM, 4
  li s1, 0
  li s2, 5
  addi a0, s0, 3
  lr.w a1, (a0)
  beqz s1, fail

  # 5: misaligned sc.w traps with cause 7, memory unchanged
  li TESTNUM, 5
  li s1, 0
  li s2, 7
  lr.w t0, (s0)             # valid reservation on the aligned word
  addi a0, s0, 1
  sc.w a1, a2, (a0)
  beqz s1, fail
  lw t1, 0(s0)
  li t2, 0x11223344
  bne t1, t2, fail
  lw t1, 4(s0)
  li t2, 0x55667788
  bne t1, t2, fail

  # 6: an aligned AMO still works after all that
  li TESTNUM, 6
  li a2, 1
  amoadd.w a1, a2, (s0)
  li t2, 0x11223344
  bne a1, t2, fail
  lw t1, 0(s0)
  li t2, 0x11223345
  bne t1, t2, fail

  TEST_PASSFAIL

  # Trap handler, reached from the env's trap_vector for non-ecall traps.
  .align 2
  .global mtvec_handler
mtvec_handler:
  csrr t0, mcause
  bne t0, s2, fail
  csrr t0, mtval
  bne t0, a0, fail
  li s1, 1
  csrr t0, mepc
  addi t0, t0, 4            # skip the faulting instruction
  csrw mepc, t0
  mret

RVTEST_CODE_END

  .data
RVTEST_DATA_BEGIN

  TEST_DATA

  .align 3
data:
  .word 0x11223344
  .word 0x55667788

RVTEST_DATA_END
