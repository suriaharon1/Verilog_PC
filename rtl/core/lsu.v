// lsu.v
// Load/store unit.
//
// Turns one load or store into one or two aligned 32-bit bus transactions.
// A misaligned access that stays inside one word needs one transaction; one
// that crosses a word boundary is split into two (low word, then high word).
// Misaligned accesses are handled in hardware, because nommu Linux has no
// firmware underneath it to emulate them.
//
// The trick: treat the two words as one 64-bit window. Byte strobes and store
// data are shifted left by the byte offset into that window; load data is
// shifted right by the same offset to come back out.
//
// Atomic memory operations (AMOs, M3) reuse the two-phase machinery: phase 0
// reads the word, phase 1 writes amo_alu(old, wdata) back to the SAME word,
// and `rdata` returns the old value. The core only sends word-aligned AMOs
// (misaligned ones trap). LR is a plain load and SC a plain store here; the
// reservation logic lives in the core.
//
// Handshake: the core holds `req` high (with stable inputs) until `done`
// pulses for one cycle. `done` and `rdata` are valid in that same cycle.

`default_nettype none

module lsu (
    input  wire        clk,
    input  wire        rst,

    // Core side
    input  wire        req,
    input  wire        is_store,
    input  wire [31:0] addr,
    input  wire [31:0] wdata,
    input  wire [1:0]  size,         // 00 byte, 01 half, 10 word
    input  wire        is_unsigned,  // lbu, lhu
    input  wire        is_amo,       // read-modify-write (word, aligned)
    input  wire [4:0]  amo_funct5,
    output wire        done,
    output reg  [31:0] rdata,
    output wire [31:0] amo_wdata,    // value an AMO writes (for the trace)

    // Bus side
    output wire        mem_valid,
    output wire [31:0] mem_addr,
    output wire [31:0] mem_wdata,
    output wire [3:0]  mem_wstrb,    // all zero means read
    input  wire        mem_ready,
    input  wire [31:0] mem_rdata
);

    wire [1:0]  off       = addr[1:0];
    wire [5:0]  bit_off   = {1'b0, off, 3'b000};
    wire [31:0] base      = {addr[31:2], 2'b00};

    wire [3:0]  size_mask = (size == 2'b00) ? 4'b0001 :
                            (size == 2'b01) ? 4'b0011 : 4'b1111;
    wire [7:0]  mask8     = {4'b0000, size_mask} << off;
    wire [63:0] wdata64   = {32'd0, wdata} << bit_off;

    reg         phase;       // 0: low word (or AMO read), 1: high word (or AMO write)
    reg  [31:0] lo_word;     // low word of a split load, or the AMO's old value

    // AMOs always take both phases: read, then write.
    wire        need_second = is_amo || (|mask8[7:4]);
    wire        last        = phase || !need_second;

    amo_alu u_amo_alu (
        .funct5 (amo_funct5),
        .old    (lo_word),
        .src    (wdata),
        .result (amo_wdata)
    );

    assign mem_valid = req;
    assign mem_addr  = (phase && !is_amo) ? (base + 32'd4) : base;
    assign mem_wdata = is_amo ? amo_wdata :
                       phase  ? wdata64[63:32] : wdata64[31:0];
    assign mem_wstrb = is_amo    ? (phase ? 4'b1111 : 4'b0000) :
                       !is_store ? 4'b0000 :
                       phase     ? mask8[7:4] : mask8[3:0];
    assign done      = req && mem_ready && last;

    // Load data path. For an AMO (aligned, phase 1) the low word is lo_word,
    // the old value, which is what rd must receive.
    wire [63:0] rd64 = phase ? {mem_rdata, lo_word} : {32'd0, mem_rdata};
    /* verilator lint_off UNUSEDSIGNAL */
    wire [63:0] rd_shifted = rd64 >> bit_off;   // only the low 32 bits are needed
    /* verilator lint_on UNUSEDSIGNAL */
    wire [31:0] lw_val = rd_shifted[31:0];

    always @(*) begin
        case (size)
            2'b00:   rdata = is_unsigned ? {24'd0, lw_val[7:0]}  : {{24{lw_val[7]}},  lw_val[7:0]};
            2'b01:   rdata = is_unsigned ? {16'd0, lw_val[15:0]} : {{16{lw_val[15]}}, lw_val[15:0]};
            default: rdata = lw_val;
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            phase   <= 1'b0;
            lo_word <= 32'd0;
        end
        else if (req && mem_ready) begin
            if (last) begin
                phase <= 1'b0;
            end
            else begin
                phase   <= 1'b1;
                lo_word <= mem_rdata;
            end
        end
    end

endmodule

`default_nettype wire
