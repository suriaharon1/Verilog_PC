// regfile.v
// 32 x 32-bit architectural register file.
// Two combinational read ports, one synchronous write port.
// x0 always reads as zero and writes to it are dropped.

`default_nettype none

module regfile (
    input  wire        clk,

    input  wire [4:0]  rs1_addr,
    output wire [31:0] rs1_data,
    input  wire [4:0]  rs2_addr,
    output wire [31:0] rs2_data,

    input  wire        we,
    input  wire [4:0]  rd_addr,
    input  wire [31:0] rd_data
);

    reg [31:0] regs [0:31];

    assign rs1_data = (rs1_addr == 5'd0) ? 32'd0 : regs[rs1_addr];
    assign rs2_data = (rs2_addr == 5'd0) ? 32'd0 : regs[rs2_addr];

    always @(posedge clk) begin
        if (we && rd_addr != 5'd0) begin
            regs[rd_addr] <= rd_data;
        end
    end

endmodule

`default_nettype wire
