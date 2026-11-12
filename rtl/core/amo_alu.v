// amo_alu.v
// Computes the new memory value for an atomic memory operation (AMO).
//
// An AMO reads `old` from memory, combines it with `src` (rs2), writes the
// result back, and returns `old` in rd. The read and write are done by the
// LSU; this module is only the "combine" step.
//
//   funct5: 00000 amoadd   00001 amoswap  00100 amoxor  01100 amoand
//           01000 amoor    10000 amomin   10100 amomax  11000 amominu
//           11100 amomaxu
//
// The decoder only lets valid funct5 values through.

`default_nettype none

module amo_alu (
    input  wire [4:0]  funct5,
    input  wire [31:0] old,
    input  wire [31:0] src,
    output reg  [31:0] result
);

    wire lt_signed   = ($signed(old) < $signed(src));
    wire lt_unsigned = (old < src);

    always @(*) begin
        case (funct5)
            5'b00000: result = old + src;                        // amoadd
            5'b00001: result = src;                              // amoswap
            5'b00100: result = old ^ src;                        // amoxor
            5'b01100: result = old & src;                        // amoand
            5'b01000: result = old | src;                        // amoor
            5'b10000: result = lt_signed   ? old : src;          // amomin
            5'b10100: result = lt_signed   ? src : old;          // amomax
            5'b11000: result = lt_unsigned ? old : src;          // amominu
            5'b11100: result = lt_unsigned ? src : old;          // amomaxu
            default:  result = old;
        endcase
    end

endmodule

`default_nettype wire
