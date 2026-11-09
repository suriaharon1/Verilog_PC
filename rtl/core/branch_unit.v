// branch_unit.v
// Evaluates the condition of a conditional branch from funct3.
// funct3 values 010 and 011 are not branches; the decoder flags them illegal.

`default_nettype none

module branch_unit (
    input  wire [2:0]  funct3,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg         taken
);

    always @(*) begin
        case (funct3)
            3'b000:  taken = (a == b);                    // beq
            3'b001:  taken = (a != b);                    // bne
            3'b100:  taken = ($signed(a) <  $signed(b));  // blt
            3'b101:  taken = ($signed(a) >= $signed(b));  // bge
            3'b110:  taken = (a <  b);                    // bltu
            3'b111:  taken = (a >= b);                    // bgeu
            default: taken = 1'b0;
        endcase
    end

endmodule

`default_nettype wire
