// decode.v
// Instruction decoder for RV32IM plus Zicsr, Zifencei, and the M-mode
// system instructions (ecall, ebreak, mret, wfi).
//
// Purely combinational. Any encoding not listed here sets `illegal`, and the
// core turns that into an illegal instruction trap. The core is responsible
// for suppressing all side effects of an instruction that traps, so the
// other control outputs do not need to be cleared when `illegal` is set.

`default_nettype none
`include "core_defs.vh"

module decode (
    input  wire [31:0] instr,

    // Register fields
    output wire [4:0]  rs1,
    output wire [4:0]  rs2,
    output wire [4:0]  rd,
    output wire [2:0]  funct3,
    output wire [11:0] csr_addr,

    // Datapath control
    output reg  [31:0] imm,
    output reg  [3:0]  alu_op,
    output reg  [1:0]  alu_a_sel,
    output reg         alu_b_imm,
    output reg  [2:0]  wb_sel,
    output reg         reg_write,

    // Instruction class
    output reg         is_load,
    output reg         is_store,
    output reg         is_branch,
    output reg         is_muldiv,
    output reg         is_jal,
    output reg         is_jalr,
    output reg         is_csr,
    output reg         csr_write,
    output reg         is_ecall,
    output reg         is_ebreak,
    output reg         is_mret,
    output reg         illegal
);

    wire [6:0] opcode = instr[6:0];
    wire [6:0] funct7 = instr[31:25];

    assign rs1      = instr[19:15];
    assign rs2      = instr[24:20];
    assign rd       = instr[11:7];
    assign funct3   = instr[14:12];
    assign csr_addr = instr[31:20];

    // Immediate formats
    wire [31:0] imm_i = {{20{instr[31]}}, instr[31:20]};
    wire [31:0] imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    wire [31:0] imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    wire [31:0] imm_u = {instr[31:12], 12'd0};
    wire [31:0] imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
    wire [31:0] imm_z = {27'd0, instr[19:15]};   // CSR zero-extended immediate

    always @(*) begin
        imm       = 32'd0;
        alu_op    = `ALU_ADD;
        alu_a_sel = `A_RS1;
        alu_b_imm = 1'b0;
        wb_sel    = `WB_ALU;
        reg_write = 1'b0;
        is_load   = 1'b0;
        is_store  = 1'b0;
        is_branch = 1'b0;
        is_muldiv = 1'b0;
        is_jal    = 1'b0;
        is_jalr   = 1'b0;
        is_csr    = 1'b0;
        csr_write = 1'b0;
        is_ecall  = 1'b0;
        is_ebreak = 1'b0;
        is_mret   = 1'b0;
        illegal   = 1'b0;

        case (opcode)
            `OPC_LUI: begin
                imm       = imm_u;
                alu_a_sel = `A_ZERO;
                alu_b_imm = 1'b1;
                reg_write = 1'b1;
            end

            `OPC_AUIPC: begin
                imm       = imm_u;
                alu_a_sel = `A_PC;
                alu_b_imm = 1'b1;
                reg_write = 1'b1;
            end

            `OPC_JAL: begin
                imm       = imm_j;
                is_jal    = 1'b1;
                wb_sel    = `WB_PC4;
                reg_write = 1'b1;
            end

            `OPC_JALR: begin
                imm       = imm_i;
                is_jalr   = 1'b1;
                alu_b_imm = 1'b1;
                wb_sel    = `WB_PC4;
                reg_write = 1'b1;
                illegal   = (funct3 != 3'b000);
            end

            `OPC_BRANCH: begin
                imm       = imm_b;
                is_branch = 1'b1;
                illegal   = (funct3 == 3'b010) || (funct3 == 3'b011);
            end

            `OPC_LOAD: begin
                imm       = imm_i;
                alu_b_imm = 1'b1;
                is_load   = 1'b1;
                wb_sel    = `WB_LOAD;
                reg_write = 1'b1;
                // Legal: lb 000, lh 001, lw 010, lbu 100, lhu 101
                illegal   = (funct3 == 3'b011) || (funct3 == 3'b110) || (funct3 == 3'b111);
            end

            `OPC_STORE: begin
                imm       = imm_s;
                alu_b_imm = 1'b1;
                is_store  = 1'b1;
                // Legal: sb 000, sh 001, sw 010
                illegal   = funct3[2] || (funct3[1:0] == 2'b11);
            end

            `OPC_OP_IMM: begin
                imm       = imm_i;
                alu_b_imm = 1'b1;
                reg_write = 1'b1;
                // funct7[5] only selects srai vs srli; for every other
                // OP-IMM instruction those bits are part of the immediate.
                alu_op    = {(funct3 == 3'b101) ? funct7[5] : 1'b0, funct3};
                if (funct3 == 3'b001) begin
                    illegal = (funct7 != 7'b0000000);                              // slli
                end
                else if (funct3 == 3'b101) begin
                    illegal = (funct7 != 7'b0000000) && (funct7 != 7'b0100000);    // srli, srai
                end
            end

            `OPC_OP: begin
                reg_write = 1'b1;
                alu_op    = {funct7[5], funct3};
                if (funct7 == 7'b0000001) begin
                    // M extension: mul, mulh, mulhsu, mulhu, div, divu, rem, remu
                    is_muldiv = 1'b1;
                    wb_sel    = `WB_MULDIV;
                end
                else begin
                    // funct7 = 0000000: all eight ops. funct7 = 0100000: sub, sra only.
                    illegal = !((funct7 == 7'b0000000) ||
                                ((funct7 == 7'b0100000) && ((funct3 == 3'b000) || (funct3 == 3'b101))));
                end
            end

            `OPC_MISC_MEM: begin
                // fence (000) and fence.i (001) are no-ops: there are no
                // caches and fetch and data share one memory port.
                illegal = (funct3[2:1] != 2'b00);
            end

            `OPC_SYSTEM: begin
                if (funct3 == 3'b000) begin
                    case (instr)
                        32'h00000073: is_ecall  = 1'b1;
                        32'h00100073: is_ebreak = 1'b1;
                        32'h30200073: is_mret   = 1'b1;
                        32'h10500073: ;                     // wfi: legal no-op
                        default:      illegal   = 1'b1;
                    endcase
                end
                else if (funct3 == 3'b100) begin
                    illegal = 1'b1;
                end
                else begin
                    // csrrw 001, csrrs 010, csrrc 011, csrrwi 101, csrrsi 110, csrrci 111
                    is_csr    = 1'b1;
                    imm       = imm_z;
                    wb_sel    = `WB_CSR;
                    reg_write = 1'b1;
                    // csrrs/csrrc with rs1 = x0 (or uimm = 0) must not write.
                    csr_write = (funct3[1:0] == 2'b01) || (rs1 != 5'd0);
                    // Writing a read-only CSR (addr[11:10] == 11) is illegal.
                    illegal   = csr_write && (csr_addr[11:10] == 2'b11);
                end
            end

            default: begin
                illegal = 1'b1;
            end
        endcase
    end

endmodule

`default_nettype wire
