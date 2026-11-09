// alu.v
// Combinational integer ALU for RV32I.
// Shift amount is the low 5 bits of b, as the ISA requires.

`default_nettype none
`include "core_defs.vh"

module alu (
    input  wire [3:0]  op,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg  [31:0] y
);

    wire [4:0] shamt = b[4:0];

    always @(*) begin
        case (op)
            `ALU_ADD:  y = a + b;
            `ALU_SUB:  y = a - b;
            `ALU_SLL:  y = a << shamt;
            `ALU_SLT:  y = {31'd0, $signed(a) < $signed(b)};
            `ALU_SLTU: y = {31'd0, a < b};
            `ALU_XOR:  y = a ^ b;
            `ALU_SRL:  y = a >> shamt;
            `ALU_SRA:  y = $signed(a) >>> shamt;
            `ALU_OR:   y = a | b;
            `ALU_AND:  y = a & b;
            default:   y = 32'd0;
        endcase
    end

endmodule

`default_nettype wire
