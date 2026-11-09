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
    output wire        done,
    output reg  [31:0] rdata,

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

    wire        need_second = |mask8[7:4];

    reg         phase;       // 0: low word, 1: high word
    reg  [31:0] lo_word;     // low word captured during a split load

    wire        last = phase || !need_second;

    assign mem_valid = req;
    assign mem_addr  = phase ? (base + 32'd4) : base;
    assign mem_wdata = phase ? wdata64[63:32] : wdata64[31:0];
    assign mem_wstrb = !is_store ? 4'b0000 :
                       phase     ? mask8[7:4] : mask8[3:0];
    assign done      = req && mem_ready && last;

    // Load data path
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
