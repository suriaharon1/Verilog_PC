// muldiv.v
// Multiply/divide unit for the RISC-V M extension.
//
//   op (funct3): 000 mul   001 mulh   010 mulhsu   011 mulhu
//                100 div   101 divu   110 rem      111 remu
//
// Handshake (same as the LSU): the core holds `req` high with stable inputs
// until `done` pulses for one cycle. `result` is valid in that cycle.
// Operands are latched on the first cycle, so the unit does not depend on
// the register file staying stable while it works.
//
// Multiply: one 33 x 33 signed multiply covers all four ops. Each operand
// gets one extra top bit: its sign bit if that operand is signed, else 0.
// The product is registered, so a multiply takes 2 cycles in this unit.
//
// Divide: restoring division on absolute values, one quotient bit per cycle
// (32 cycles), then the signs are fixed. 34 cycles in this unit in total.
// Spec-mandated edge cases (no trap):
//   x / 0         -> quotient all ones, remainder x
//   -2^31 / -1    -> quotient -2^31,    remainder 0
// Both fall out of the unsigned algorithm, provided the quotient sign fix is
// skipped on divide by zero.

`default_nettype none

module muldiv (
    input  wire        clk,
    input  wire        rst,

    input  wire        req,
    input  wire [2:0]  op,
    input  wire [31:0] a,        // rs1
    input  wire [31:0] b,        // rs2
    output wire        done,
    output wire [31:0] result
);

    localparam [1:0] S_IDLE = 2'd0;
    localparam [1:0] S_DIV  = 2'd1;
    localparam [1:0] S_DONE = 2'd2;

    reg [1:0]  state;
    reg [31:0] result_r;

    assign done   = (state == S_DONE);
    assign result = result_r;

    // ------------------------------------------------------------------
    // Multiply (combinational from the inputs, captured into result_r)
    // ------------------------------------------------------------------
    wire a_signed_mul = (op[1:0] == 2'b01) || (op[1:0] == 2'b10);   // mulh, mulhsu
    wire b_signed_mul = (op[1:0] == 2'b01);                          // mulh

    wire signed [32:0] a_ext = {a_signed_mul & a[31], a};
    wire signed [32:0] b_ext = {b_signed_mul & b[31], b};

    /* verilator lint_off UNUSEDSIGNAL */
    wire signed [65:0] product = a_ext * b_ext;   // bits 65:64 are never needed
    /* verilator lint_on UNUSEDSIGNAL */

    wire [31:0] mul_result = (op[1:0] == 2'b00) ? product[31:0] : product[63:32];

    // ------------------------------------------------------------------
    // Divide setup (from the inputs, on the start cycle)
    // ------------------------------------------------------------------
    wire div_signed = !op[0];                 // div, rem
    wire a_neg_in   = div_signed && a[31];
    wire b_neg_in   = div_signed && b[31];
    wire [31:0] a_abs = a_neg_in ? (32'd0 - a) : a;
    wire [31:0] b_abs = b_neg_in ? (32'd0 - b) : b;

    // Divide working state
    reg [31:0] quo;          // shifts in quotient bits, shifts out dividend bits
    reg [31:0] rem;          // partial remainder
    reg [31:0] divisor;
    reg [4:0]  count;
    reg        want_rem;     // rem / remu
    reg        q_neg;        // negate quotient at the end
    reg        r_neg;        // negate remainder at the end

    // One restoring step: bring down the next dividend bit, try to subtract.
    wire [32:0] shifted = {rem, quo[31]};
    wire [32:0] diff    = shifted - {1'b0, divisor};
    wire        fits    = !diff[32];          // no borrow: divisor fits
    wire [31:0] rem_next = fits ? diff[31:0] : shifted[31:0];
    wire [31:0] quo_next = {quo[30:0], fits};

    // Final sign fix (applied to the values after the last step)
    wire [31:0] q_final = q_neg ? (32'd0 - quo_next) : quo_next;
    wire [31:0] r_final = r_neg ? (32'd0 - rem_next) : rem_next;

    always @(posedge clk) begin
        if (rst) begin
            state    <= S_IDLE;
            result_r <= 32'd0;
            quo      <= 32'd0;
            rem      <= 32'd0;
            divisor  <= 32'd0;
            count    <= 5'd0;
            want_rem <= 1'b0;
            q_neg    <= 1'b0;
            r_neg    <= 1'b0;
        end
        else begin
            case (state)
                S_IDLE: begin
                    if (req) begin
                        if (!op[2]) begin
                            result_r <= mul_result;
                            state    <= S_DONE;
                        end
                        else begin
                            quo      <= a_abs;
                            rem      <= 32'd0;
                            divisor  <= b_abs;
                            count    <= 5'd0;
                            want_rem <= op[1];
                            // Quotient is negative if exactly one operand is,
                            // except on divide by zero (must stay all ones).
                            q_neg    <= (a_neg_in ^ b_neg_in) && (b != 32'd0);
                            // Remainder takes the sign of the dividend.
                            r_neg    <= a_neg_in;
                            state    <= S_DIV;
                        end
                    end
                end

                S_DIV: begin
                    quo   <= quo_next;
                    rem   <= rem_next;
                    count <= count + 5'd1;
                    if (count == 5'd31) begin
                        result_r <= want_rem ? r_final : q_final;
                        state    <= S_DONE;
                    end
                end

                S_DONE: begin
                    state <= S_IDLE;
                end

                default: begin
                    state <= S_IDLE;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
