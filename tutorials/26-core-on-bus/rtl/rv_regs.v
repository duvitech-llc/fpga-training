// The 32 integer registers of RV32I, x0 to x31, built from enreg as in Tutorial 11.
// One synchronous write port and two combinational read ports.
//
// This is Tutorial 11's regfile with one change: x0 is not a register. The spec
// says x0 always reads as zero and a write to it is thrown away, so q[0] is a
// constant and the generate loop starts at 1. There is nothing to reset or
// write, and no state that a bug could make non-zero.
//
// A read of the register being written returns the old value until the rising
// edge, and the new value after it. rst clears x1 to x31 on the edge.
module rv_regs #(
    parameter WIDTH = 32
) (
    input  wire             clk,
    input  wire             rst,      // synchronous, active high, overrides we
    input  wire             we,       // write wdata to register waddr
    input  wire [4:0]       waddr,    // 0 is accepted and changes nothing
    input  wire [WIDTH-1:0] wdata,
    input  wire [4:0]       raddr_a,
    output wire [WIDTH-1:0] rdata_a,
    input  wire [4:0]       raddr_b,
    output wire [WIDTH-1:0] rdata_b
);

    wire [WIDTH-1:0] q [0:31];

    assign q[0] = {WIDTH{1'b0}};

    genvar i;
    generate
        for (i = 1; i < 32; i = i + 1) begin : gen_regs
            localparam [4:0] INDEX = i;

            wire wen = we && (waddr == INDEX);

            enreg #(.WIDTH(WIDTH)) u_reg (
                .clk(clk),
                .rst(rst),
                .en(wen),
                .d(wdata),
                .q(q[i])
            );
        end
    endgenerate

    assign rdata_a = q[raddr_a];
    assign rdata_b = q[raddr_b];

endmodule
