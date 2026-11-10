// csr.v
// Machine-mode CSR file and trap state.
//
// Current scope: the minimum the riscv-tests environment needs (mtvec, mepc,
// mcause, mtval, mstatus.MIE/MPIE, mscratch, counters, ID registers).
// The core is M-mode only, so mstatus.MPP is hardwired to 11.
//
// `valid` is low for any CSR address that does not exist on this core; the
// core turns that into an illegal instruction trap, as the spec requires.
// Some CSRs exist but are read-only zero: PMP (zero regions implemented),
// mstatush, mconfigptr, and the unused hardware performance counters.
//
// TODO(M4): mip/mie interrupt wiring, and connect `time` to the CLINT's mtime.

`default_nettype none

module csr (
    input  wire        clk,
    input  wire        rst,

    // CSR instruction port
    input  wire [11:0] addr,
    input  wire        we,         // perform the write this cycle
    input  wire [1:0]  op,         // funct3[1:0]: 01 write, 10 set, 11 clear
    input  wire [31:0] wsrc,       // rs1 value or zero-extended uimm
    output reg  [31:0] rdata,
    output reg         valid,      // addr names a CSR that exists

    // Trap entry and return
    input  wire        trap,
    input  wire [31:0] trap_cause,
    input  wire [31:2] trap_pc,    // pc is always 4-byte aligned
    input  wire [31:0] trap_val,
    input  wire        mret,

    // One pulse per retired instruction
    input  wire        retire,

    output wire [31:0] mtvec_o,
    output wire [31:0] mepc_o
);

    // CSR addresses
    localparam [11:0] CSR_MSTATUS   = 12'h300;
    localparam [11:0] CSR_MISA      = 12'h301;
    localparam [11:0] CSR_MIE       = 12'h304;
    localparam [11:0] CSR_MSTATUSH  = 12'h310;
    localparam [11:0] CSR_MTVEC     = 12'h305;
    localparam [11:0] CSR_MSCRATCH  = 12'h340;
    localparam [11:0] CSR_MEPC      = 12'h341;
    localparam [11:0] CSR_MCAUSE    = 12'h342;
    localparam [11:0] CSR_MTVAL     = 12'h343;
    localparam [11:0] CSR_MIP       = 12'h344;
    localparam [11:0] CSR_MCYCLE    = 12'hB00;
    localparam [11:0] CSR_MINSTRET  = 12'hB02;
    localparam [11:0] CSR_MCYCLEH   = 12'hB80;
    localparam [11:0] CSR_MINSTRETH = 12'hB82;
    localparam [11:0] CSR_CYCLE     = 12'hC00;
    localparam [11:0] CSR_TIME      = 12'hC01;
    localparam [11:0] CSR_INSTRET   = 12'hC02;
    localparam [11:0] CSR_CYCLEH    = 12'hC80;
    localparam [11:0] CSR_TIMEH     = 12'hC81;
    localparam [11:0] CSR_INSTRETH  = 12'hC82;
    localparam [11:0] CSR_MVENDORID = 12'hF11;
    localparam [11:0] CSR_MARCHID   = 12'hF12;
    localparam [11:0] CSR_MIMPID    = 12'hF13;
    localparam [11:0] CSR_MHARTID   = 12'hF14;
    localparam [11:0] CSR_MCONFIGPTR = 12'hF15;

    // misa: MXL = 1 (32-bit), extension I (bit 8). Bits for M and A are set
    // when those extensions land.
    localparam [31:0] MISA_VALUE = 32'h4000_0100;

    // State
    reg        mstatus_mie;
    reg        mstatus_mpie;
    reg [31:0] mie;
    reg [29:0] mtvec_base;     // mtvec[31:2]; MODE is fixed at 0 (direct)
    reg [31:0] mscratch;
    reg [29:0] mepc_r;         // mepc[31:2]; bits 1:0 are zero without C
    reg [31:0] mcause;
    reg [31:0] mtval;
    reg [63:0] mcycle;
    reg [63:0] minstret;

    // mstatus view: MPP (12:11) = 11, MPIE (7), MIE (3)
    wire [31:0] mstatus = {19'd0, 2'b11, 3'd0, mstatus_mpie, 3'd0, mstatus_mie, 3'd0};

    assign mtvec_o = {mtvec_base, 2'b00};
    assign mepc_o  = {mepc_r, 2'b00};

    // Read-only-zero ranges that must still exist
    wire is_pmp      = (addr >= 12'h3A0) && (addr <= 12'h3EF);   // pmpcfg0-15, pmpaddr0-63
    wire is_mhpm_evt = (addr >= 12'h323) && (addr <= 12'h33F);   // mhpmevent3-31
    wire is_mhpm_cnt = ((addr >= 12'hB03) && (addr <= 12'hB1F)) ||
                       ((addr >= 12'hB83) && (addr <= 12'hB9F)); // mhpmcounter3-31(h)

    // Read mux
    always @(*) begin
        valid = 1'b1;
        case (addr)
            CSR_MSTATUS:   rdata = mstatus;
            CSR_MISA:      rdata = MISA_VALUE;
            CSR_MIE:       rdata = mie;
            CSR_MTVEC:     rdata = mtvec_o;
            CSR_MSCRATCH:  rdata = mscratch;
            CSR_MEPC:      rdata = mepc_o;
            CSR_MCAUSE:    rdata = mcause;
            CSR_MTVAL:     rdata = mtval;
            CSR_MIP:       rdata = 32'd0;
            CSR_MCYCLE,
            CSR_CYCLE,
            CSR_TIME:      rdata = mcycle[31:0];    // time aliases cycle until the CLINT exists
            CSR_MCYCLEH,
            CSR_CYCLEH,
            CSR_TIMEH:     rdata = mcycle[63:32];
            CSR_MINSTRET,
            CSR_INSTRET:   rdata = minstret[31:0];
            CSR_MINSTRETH,
            CSR_INSTRETH:  rdata = minstret[63:32];
            CSR_MVENDORID,
            CSR_MARCHID,
            CSR_MIMPID,
            CSR_MHARTID,
            CSR_MCONFIGPTR,
            CSR_MSTATUSH:  rdata = 32'd0;
            default: begin
                rdata = 32'd0;
                valid = is_pmp || is_mhpm_evt || is_mhpm_cnt;
            end
        endcase
    end

    // Value to write for csrrw / csrrs / csrrc
    reg [31:0] wval;
    always @(*) begin
        case (op)
            2'b01:   wval = wsrc;
            2'b10:   wval = rdata | wsrc;
            2'b11:   wval = rdata & ~wsrc;
            default: wval = rdata;
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            mstatus_mie  <= 1'b0;
            mstatus_mpie <= 1'b0;
            mie          <= 32'd0;
            mtvec_base   <= 30'd0;
            mscratch     <= 32'd0;
            mepc_r       <= 30'd0;
            mcause       <= 32'd0;
            mtval        <= 32'd0;
            mcycle       <= 64'd0;
            minstret     <= 64'd0;
        end
        else begin
            // Counters. An explicit CSR write below takes priority.
            mcycle <= mcycle + 64'd1;
            if (retire) begin
                minstret <= minstret + 64'd1;
            end

            if (trap) begin
                mepc_r       <= trap_pc;
                mcause       <= trap_cause;
                mtval        <= trap_val;
                mstatus_mpie <= mstatus_mie;
                mstatus_mie  <= 1'b0;
            end
            else if (mret) begin
                mstatus_mie  <= mstatus_mpie;
                mstatus_mpie <= 1'b1;
            end
            else if (we) begin
                case (addr)
                    CSR_MSTATUS: begin
                        mstatus_mie  <= wval[3];
                        mstatus_mpie <= wval[7];
                    end
                    CSR_MIE:       mie            <= wval & 32'h0000_0888;   // MEIE, MTIE, MSIE
                    CSR_MTVEC:     mtvec_base     <= wval[31:2];
                    CSR_MSCRATCH:  mscratch       <= wval;
                    CSR_MEPC:      mepc_r         <= wval[31:2];
                    CSR_MCAUSE:    mcause         <= wval;
                    CSR_MTVAL:     mtval          <= wval;
                    CSR_MCYCLE:    mcycle[31:0]   <= wval;
                    CSR_MCYCLEH:   mcycle[63:32]  <= wval;
                    CSR_MINSTRET:  minstret[31:0] <= wval;
                    CSR_MINSTRETH: minstret[63:32] <= wval;
                    default: ;
                endcase
            end
        end
    end

endmodule

`default_nettype wire
