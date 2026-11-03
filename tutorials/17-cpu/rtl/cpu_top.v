// The CPU with its two memories, for simulation and for "make pnr". Both are
// synchronous read, as in Tutorial 6: data appears one clock after the address.
//
// PROGRAM names a .hex file for $readmemh. Left empty, memory starts as all NOPs
// and a testbench loads it. Data memory starts as 0 here to keep tests repeatable.
// A real RAM holds whatever it powered up with.
module cpu_top #(
    parameter PROGRAM = ""
) (
    input  wire clk,
    input  wire rst,      // synchronous, active high
    output wire halted,
    output wire illegal,
    output wire retire
);

    reg [15:0] imem [0:255];
    reg [7:0]  dmem [0:255];

    wire [7:0]  imem_addr, dmem_addr, dmem_wdata;
    reg  [15:0] imem_data;
    reg  [7:0]  dmem_rdata;
    wire        dmem_re, dmem_we;

    // cpu says which instruction retired, which matters to testbenches only.
    wire [7:0]  unused_retire_pc;
    wire [15:0] unused_retire_instr;

    // Load imem or clear it, never both. With a loop that always ran, Yosys kept
    // the zeros, so the synthesized design had no program while simulation looked fine.
    integer i;
    initial begin
        if (PROGRAM != "")
            $readmemh(PROGRAM, imem);
        else
            for (i = 0; i < 256; i = i + 1)
                imem[i] = 16'd0;
        for (i = 0; i < 256; i = i + 1)
            dmem[i] = 8'd0;
    end

    always @(posedge clk)
        imem_data <= imem[imem_addr];

    always @(posedge clk) begin
        if (dmem_we)
            dmem[dmem_addr] <= dmem_wdata;
        if (dmem_re)
            dmem_rdata <= dmem[dmem_addr];
    end

    cpu u_cpu (
        .clk(clk),
        .rst(rst),
        .imem_addr(imem_addr),
        .imem_data(imem_data),
        .dmem_addr(dmem_addr),
        .dmem_re(dmem_re),
        .dmem_we(dmem_we),
        .dmem_wdata(dmem_wdata),
        .dmem_rdata(dmem_rdata),
        .halted(halted),
        .illegal(illegal),
        .retire(retire),
        .retire_pc(unused_retire_pc),
        .retire_instr(unused_retire_instr)
    );

endmodule
