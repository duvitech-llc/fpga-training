// regfile written as an array, with no reset. Compare the two with "make synth"
// and "make synth-noreset". Addresses must stay below REGS.
module regfile_noreset #(
    parameter WIDTH = 8,
    parameter REGS  = 4
) (
    input  wire                    clk,
    input  wire                    we,
    input  wire [$clog2(REGS)-1:0] waddr,
    input  wire [WIDTH-1:0]        wdata,
    input  wire [$clog2(REGS)-1:0] raddr_a,
    output wire [WIDTH-1:0]        rdata_a,
    input  wire [$clog2(REGS)-1:0] raddr_b,
    output wire [WIDTH-1:0]        rdata_b
);

    reg [WIDTH-1:0] mem [0:REGS-1];

    assign rdata_a = mem[raddr_a];
    assign rdata_b = mem[raddr_b];

    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
    end

endmodule
