// The same memory as sync_ram, but rdata follows raddr with no clock. Compare
// the two with "make synth" and "make synth-async".
module async_read_ram #(
    parameter WIDTH = 8,
    parameter DEPTH = 256
) (
    input  wire                     clk,
    input  wire                     we,
    input  wire [$clog2(DEPTH)-1:0] waddr,
    input  wire [WIDTH-1:0]         wdata,
    input  wire [$clog2(DEPTH)-1:0] raddr,
    output wire [WIDTH-1:0]         rdata
);

    reg [WIDTH-1:0] mem [0:DEPTH-1];

    assign rdata = mem[raddr];

    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
    end

endmodule
