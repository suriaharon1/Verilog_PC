// core_defs.vh
// Shared encodings for the RV32 core.

`ifndef CORE_DEFS_VH
`define CORE_DEFS_VH

// Major opcodes (instr[6:0])
`define OPC_LUI      7'b0110111
`define OPC_AUIPC    7'b0010111
`define OPC_JAL      7'b1101111
`define OPC_JALR     7'b1100111
`define OPC_BRANCH   7'b1100011
`define OPC_LOAD     7'b0000011
`define OPC_STORE    7'b0100011
`define OPC_OP_IMM   7'b0010011
`define OPC_OP       7'b0110011
`define OPC_MISC_MEM 7'b0001111
`define OPC_SYSTEM   7'b1110011

// ALU operations. Encoded as {funct7[5], funct3} so the decoder can pass
// instruction bits straight through for OP and OP-IMM.
`define ALU_ADD  4'b0000
`define ALU_SUB  4'b1000
`define ALU_SLL  4'b0001
`define ALU_SLT  4'b0010
`define ALU_SLTU 4'b0011
`define ALU_XOR  4'b0100
`define ALU_SRL  4'b0101
`define ALU_SRA  4'b1101
`define ALU_OR   4'b0110
`define ALU_AND  4'b0111

// ALU operand A select
`define A_RS1  2'd0
`define A_PC   2'd1
`define A_ZERO 2'd2

// Writeback select
`define WB_ALU    3'd0
`define WB_PC4    3'd1
`define WB_CSR    3'd2
`define WB_LOAD   3'd3
`define WB_MULDIV 3'd4

// Exception cause codes (mcause, interrupt bit clear)
`define CAUSE_MISALIGNED_FETCH 32'd0
`define CAUSE_ILLEGAL_INSN     32'd2
`define CAUSE_BREAKPOINT       32'd3
`define CAUSE_MACHINE_ECALL    32'd11

`endif
