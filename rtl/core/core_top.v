// core_top.v
// Multi-cycle RV32IMA core (plus Zicsr, Zifencei, and basic M-mode traps).
//
// State machine:
//
//   FETCH : read the instruction at pc over the bus. Waits for mem_ready.
//   EXEC  : decode, read registers, run the ALU/branch unit, and either
//           finish the instruction (write rd, update pc) or go to MEM.
//           Traps and mret also resolve here.
//   MEM   : the LSU runs one or two bus transactions (an AMO is always two:
//           read, then write). On done, loads/AMOs write rd and pc advances.
//   MULDIV: the multiply/divide unit runs (2 cycles for multiply, 34 for
//           divide). On done, rd is written and pc advances.
//
// Fetch and data share one bus port (von Neumann). That keeps fence.i
// trivially correct and maps directly onto a single Wishbone master later.
//
// Atomics (A extension): LR sets a one-word reservation; SC succeeds only if
// the reservation is still valid for that word. Every SC clears it, and so
// does every trap and mret. A failing SC finishes in EXEC with no memory
// access. AMOs are read-modify-write in the LSU. A single in-order hart with
// no caches needs nothing else for atomicity.
//
// Bus protocol: the core drives mem_valid with stable addr/wdata/wstrb until
// it sees mem_ready high on a rising edge. wstrb == 0 means a read.
//
// The trace_* outputs describe each instruction in the cycle it completes.
// They are for the testbench (debug logs now, Spike lockstep in M1.5).

`default_nettype none
`include "core_defs.vh"

module core_top #(
    parameter [31:0] RESET_PC = 32'h8000_0000
) (
    input  wire        clk,
    input  wire        rst,

    // Memory bus
    output wire        mem_valid,
    output wire [31:0] mem_addr,
    output wire [31:0] mem_wdata,
    output wire [3:0]  mem_wstrb,
    input  wire        mem_ready,
    input  wire [31:0] mem_rdata,

    // Retirement trace
    output wire        trace_valid,
    output wire [31:0] trace_pc,
    output wire [31:0] trace_insn,
    output wire        trace_trap,
    output wire        trace_rd_we,
    output wire [4:0]  trace_rd,
    output wire [31:0] trace_rd_wdata,
    output wire        trace_mem_valid,   // instruction was a load or store
    output wire        trace_mem_store,
    output wire        trace_mem_amo,     // read-modify-write: wdata is the new value
    output wire [1:0]  trace_mem_size,    // 00 byte, 01 half, 10 word
    output wire [31:0] trace_mem_addr,    // architectural (byte) address
    output wire [31:0] trace_mem_wdata    // store data, masked to the access size
);

    localparam [1:0] S_FETCH = 2'd0;
    localparam [1:0] S_EXEC  = 2'd1;
    localparam [1:0] S_MEM    = 2'd2;
    localparam [1:0] S_MULDIV = 2'd3;

    reg [1:0]  state;
    reg [31:0] pc;
    reg [31:0] ir;

    wire in_fetch = (state == S_FETCH);
    wire in_exec  = (state == S_EXEC);
    wire in_mem    = (state == S_MEM);
    wire in_muldiv = (state == S_MULDIV);

    // ------------------------------------------------------------------
    // Decode
    // ------------------------------------------------------------------
    wire [4:0]  rs1, rs2, rd;
    wire [2:0]  funct3;
    wire [11:0] csr_addr;
    wire [31:0] imm;
    wire [3:0]  alu_op;
    wire [1:0]  alu_a_sel;
    wire        alu_b_imm;
    wire [2:0]  wb_sel;
    wire        reg_write;
    wire        is_load, is_store, is_branch, is_muldiv, is_jal, is_jalr;
    wire        is_lr, is_sc, is_amo;
    wire [4:0]  amo_funct5;
    wire        is_csr, csr_write, is_ecall, is_ebreak, is_mret, illegal;

    decode u_decode (
        .instr     (ir),
        .rs1       (rs1),
        .rs2       (rs2),
        .rd        (rd),
        .funct3    (funct3),
        .csr_addr  (csr_addr),
        .imm       (imm),
        .alu_op    (alu_op),
        .alu_a_sel (alu_a_sel),
        .alu_b_imm (alu_b_imm),
        .wb_sel    (wb_sel),
        .reg_write (reg_write),
        .is_load   (is_load),
        .is_store  (is_store),
        .is_branch (is_branch),
        .is_muldiv (is_muldiv),
        .is_lr     (is_lr),
        .is_sc     (is_sc),
        .is_amo    (is_amo),
        .amo_funct5(amo_funct5),
        .is_jal    (is_jal),
        .is_jalr   (is_jalr),
        .is_csr    (is_csr),
        .csr_write (csr_write),
        .is_ecall  (is_ecall),
        .is_ebreak (is_ebreak),
        .is_mret   (is_mret),
        .illegal   (illegal)
    );

    // ------------------------------------------------------------------
    // Register file
    // ------------------------------------------------------------------
    wire [31:0] rs1_val, rs2_val;
    wire        rf_we;
    wire [31:0] rf_wdata;

    regfile u_regfile (
        .clk      (clk),
        .rs1_addr (rs1),
        .rs1_data (rs1_val),
        .rs2_addr (rs2),
        .rs2_data (rs2_val),
        .we       (rf_we),
        .rd_addr  (rd),
        .rd_data  (rf_wdata)
    );

    // ------------------------------------------------------------------
    // Execute
    // ------------------------------------------------------------------
    wire [31:0] alu_a = (alu_a_sel == `A_PC)   ? pc    :
                        (alu_a_sel == `A_ZERO) ? 32'd0 : rs1_val;
    wire [31:0] alu_b = alu_b_imm ? imm : rs2_val;
    wire [31:0] alu_y;

    alu u_alu (
        .op (alu_op),
        .a  (alu_a),
        .b  (alu_b),
        .y  (alu_y)
    );

    wire br_taken;

    branch_unit u_branch (
        .funct3 (funct3),
        .a      (rs1_val),
        .b      (rs2_val),
        .taken  (br_taken)
    );

    wire [31:0] pc_plus4    = pc + 32'd4;
    wire [31:0] pc_plus_imm = pc + imm;
    wire        jump        = is_jal || is_jalr || (is_branch && br_taken);
    wire [31:0] jump_target = is_jalr ? {alu_y[31:1], 1'b0} : pc_plus_imm;

    // Without the C extension, every taken control transfer must land on a
    // 4-byte boundary. The trap is raised on the jump itself.
    wire        target_misaligned = jump && jump_target[1];

    // ------------------------------------------------------------------
    // Atomics: reservation for LR/SC
    // ------------------------------------------------------------------
    reg         resv_valid;
    reg  [29:0] resv_addr;      // word address (reservation granule = 1 word)

    wire        is_atomic = is_lr || is_sc || is_amo;
    // Atomics must be naturally aligned (word). Misaligned ones trap instead
    // of being split, because a split access cannot be atomic. The spec
    // allows either an address-misaligned or an access-fault exception; this
    // core raises access fault (as Spike does), which tells software the
    // access must not be emulated. Ordinary misaligned loads/stores are
    // handled in hardware, so a misaligned-address trap could invite a
    // handler to emulate the atomic non-atomically.
    wire        atomic_misaligned = is_atomic && (alu_y[1:0] != 2'b00);
    wire        sc_fail = is_sc && !(resv_valid && (resv_addr == alu_y[31:2]));

    // ------------------------------------------------------------------
    // Exceptions
    // ------------------------------------------------------------------
    wire        csr_valid;
    wire        illegal_csr = is_csr && !csr_valid;    // CSR does not exist
    wire        illegal_any = illegal || illegal_csr;

    wire exception = illegal_any || is_ecall || is_ebreak || atomic_misaligned || target_misaligned;

    reg [31:0] exc_cause;
    reg [31:0] exc_tval;
    always @(*) begin
        if (illegal_any) begin
            exc_cause = `CAUSE_ILLEGAL_INSN;
            exc_tval  = ir;
        end
        else if (is_ecall) begin
            exc_cause = `CAUSE_MACHINE_ECALL;
            exc_tval  = 32'd0;
        end
        else if (is_ebreak) begin
            exc_cause = `CAUSE_BREAKPOINT;
            exc_tval  = pc;
        end
        else if (atomic_misaligned) begin
            exc_cause = is_lr ? `CAUSE_LOAD_ACCESS_FAULT : `CAUSE_STORE_ACCESS_FAULT;
            exc_tval  = alu_y;
        end
        else begin
            exc_cause = `CAUSE_MISALIGNED_FETCH;
            exc_tval  = jump_target;
        end
    end

    wire trap_take = in_exec && exception;
    wire mret_take = in_exec && !exception && is_mret;
    // A failing SC never touches memory: it finishes in EXEC with rd = 1.
    wire go_mem    = in_exec && !exception && (is_load || (is_store && !sc_fail));
    wire go_muldiv = in_exec && !exception && is_muldiv;

    // ------------------------------------------------------------------
    // CSR file
    // ------------------------------------------------------------------
    wire [31:0] csr_rdata;
    wire [31:0] mtvec, mepc;
    wire        retire_ok;    // completes without trapping

    csr u_csr (
        .clk        (clk),
        .rst        (rst),
        .addr       (csr_addr),
        .we         (in_exec && !exception && is_csr && csr_write),
        .op         (funct3[1:0]),
        .wsrc       (funct3[2] ? imm : rs1_val),
        .rdata      (csr_rdata),
        .valid      (csr_valid),
        .trap       (trap_take),
        .trap_cause (exc_cause),
        .trap_pc    (pc[31:2]),
        .trap_val   (exc_tval),
        .mret       (mret_take),
        .retire     (retire_ok),
        .mtvec_o    (mtvec),
        .mepc_o     (mepc)
    );

    // ------------------------------------------------------------------
    // Load/store unit
    // ------------------------------------------------------------------
    wire        lsu_done;
    wire [31:0] lsu_rdata;
    wire        lsu_valid;
    wire [31:0] lsu_addr, lsu_wdata;
    wire [3:0]  lsu_wstrb;
    wire [31:0] lsu_amo_wdata;

    lsu u_lsu (
        .clk         (clk),
        .rst         (rst),
        .req         (in_mem),
        .is_store    (is_store),
        .addr        (alu_y),
        .wdata       (rs2_val),
        .size        (funct3[1:0]),
        .is_unsigned (funct3[2]),
        .is_amo      (is_amo),
        .amo_funct5  (amo_funct5),
        .done        (lsu_done),
        .rdata       (lsu_rdata),
        .amo_wdata   (lsu_amo_wdata),
        .mem_valid   (lsu_valid),
        .mem_addr    (lsu_addr),
        .mem_wdata   (lsu_wdata),
        .mem_wstrb   (lsu_wstrb),
        .mem_ready   (mem_ready),
        .mem_rdata   (mem_rdata)
    );

    // ------------------------------------------------------------------
    // Multiply/divide unit
    // ------------------------------------------------------------------
    wire        md_done;
    wire [31:0] md_result;

    muldiv u_muldiv (
        .clk    (clk),
        .rst    (rst),
        .req    (in_muldiv),
        .op     (funct3),
        .a      (rs1_val),
        .b      (rs2_val),
        .done   (md_done),
        .result (md_result)
    );

    // ------------------------------------------------------------------
    // Bus mux: fetch owns the bus in FETCH, the LSU in MEM.
    // ------------------------------------------------------------------
    assign mem_valid = in_fetch || lsu_valid;
    assign mem_addr  = in_fetch ? pc : lsu_addr;
    assign mem_wdata = lsu_wdata;
    assign mem_wstrb = in_fetch ? 4'b0000 : lsu_wstrb;

    // ------------------------------------------------------------------
    // Writeback
    // ------------------------------------------------------------------
    // Each instruction writes rd in the cycle it finishes: EXEC for most,
    // MEM for loads/LR/AMOs/successful SC, MULDIV for mul/div.
    wire exec_finish = in_exec && !exception && !go_mem && !go_muldiv;
    wire exec_wb     = exec_finish && reg_write;
    wire mem_wb      = in_mem && lsu_done && reg_write;
    wire muldiv_wb   = in_muldiv && md_done;

    assign rf_we = exec_wb || mem_wb || muldiv_wb;

    reg [31:0] wb_data;
    always @(*) begin
        case (wb_sel)
            `WB_PC4:  wb_data = pc_plus4;
            `WB_CSR:  wb_data = csr_rdata;
            `WB_LOAD:   wb_data = lsu_rdata;
            `WB_MULDIV: wb_data = md_result;
            // SC: rd = 0 on success (finishes in MEM), 1 on failure (finishes in EXEC)
            `WB_SC:     wb_data = in_mem ? 32'd0 : 32'd1;
            default:  wb_data = alu_y;
        endcase
    end
    assign rf_wdata = wb_data;

    // ------------------------------------------------------------------
    // Next PC
    // ------------------------------------------------------------------
    reg [31:0] next_pc;
    always @(*) begin
        if (exception) begin
            next_pc = mtvec;
        end
        else if (is_mret) begin
            next_pc = mepc;
        end
        else if (jump) begin
            next_pc = jump_target;
        end
        else begin
            next_pc = pc_plus4;
        end
    end

    // ------------------------------------------------------------------
    // State machine
    // ------------------------------------------------------------------
    always @(posedge clk) begin
        if (rst) begin
            state <= S_FETCH;
            pc    <= RESET_PC;
            ir    <= 32'd0;
        end
        else begin
            case (state)
                S_FETCH: begin
                    if (mem_ready) begin
                        ir    <= mem_rdata;
                        state <= S_EXEC;
                    end
                end

                S_EXEC: begin
                    if (go_mem) begin
                        state <= S_MEM;
                    end
                    else if (go_muldiv) begin
                        state <= S_MULDIV;
                    end
                    else begin
                        pc    <= next_pc;
                        state <= S_FETCH;
                    end
                end

                S_MEM: begin
                    if (lsu_done) begin
                        pc    <= pc_plus4;
                        state <= S_FETCH;
                    end
                end

                S_MULDIV: begin
                    if (md_done) begin
                        pc    <= pc_plus4;
                        state <= S_FETCH;
                    end
                end

                default: begin
                    state <= S_FETCH;
                end
            endcase
        end
    end

    // Reservation: set by LR, cleared by every SC, trap, and mret.
    always @(posedge clk) begin
        if (rst) begin
            resv_valid <= 1'b0;
            resv_addr  <= 30'd0;
        end
        else if (trap_take || mret_take) begin
            resv_valid <= 1'b0;
        end
        else if (is_sc && (exec_finish || (in_mem && lsu_done))) begin
            resv_valid <= 1'b0;
        end
        else if (is_lr && in_mem && lsu_done) begin
            resv_valid <= 1'b1;
            resv_addr  <= alu_y[31:2];
        end
    end

    // ------------------------------------------------------------------
    // Retirement trace
    // ------------------------------------------------------------------
    wire exec_done = in_exec && !go_mem && !go_muldiv;   // includes trapping instructions
    wire unit_done = (in_mem && lsu_done) || (in_muldiv && md_done);

    assign retire_ok      = (exec_done && !exception) || unit_done;
    assign trace_valid    = exec_done || unit_done;
    assign trace_pc       = pc;
    assign trace_insn     = ir;
    assign trace_trap     = in_exec && exception;
    assign trace_rd_we    = rf_we && (rd != 5'd0);
    assign trace_rd       = rd;
    assign trace_rd_wdata = rf_wdata;

    assign trace_mem_valid = in_mem && lsu_done;
    assign trace_mem_store = is_store;
    assign trace_mem_amo   = is_amo;
    assign trace_mem_size  = funct3[1:0];
    assign trace_mem_addr  = alu_y;
    assign trace_mem_wdata = is_amo                 ? lsu_amo_wdata :
                             (funct3[1:0] == 2'b00) ? {24'd0, rs2_val[7:0]}  :
                             (funct3[1:0] == 2'b01) ? {16'd0, rs2_val[15:0]} : rs2_val;

endmodule

`default_nettype wire
