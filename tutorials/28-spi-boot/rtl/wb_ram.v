// A Wishbone B4 pipelined slave: 2**AW words of RAM, for instructions and data.
//
// This is Tutorial 22's wb_regfile with LATENCY 1, made into a memory: no reset,
// and the contents loaded from INIT, a file for $readmemh with one 32-bit word
// per line. Each request is answered with ack on the next clock. A write changes
// only the bytes whose sel bit is high. A read returns the whole word.
//
// hold makes the RAM slow, as in wb_regfile: while it is high, stall is high and
// no request is taken. Tie it low in a real design.
//
// The read is a synchronous read of a memory array, so FPGA tools can put it in
// block RAM.
module wb_ram #(
    parameter AW   = 14,   // 2**AW words: 14 is 64 KiB
    parameter INIT = ""    // a file for $readmemh, or "" for none
) (
    input  wire          clk,
    input  wire          rst,     // synchronous, active high
    input  wire          cyc,
    input  wire          stb,
    input  wire          we,
    input  wire [AW-1:0] adr,     // word address
    input  wire [3:0]    sel,
    input  wire [31:0]   dat_w,
    output reg           ack,
    output wire          err,     // never
    output wire          stall,
    output reg  [31:0]   dat_r,
    input  wire          hold
);

    reg [31:0] mem [0:(1<<AW)-1];

    initial
        if (INIT != "")
            $readmemh(INIT, mem);

    assign stall = hold;
    assign err   = 1'b0;

    wire accept = cyc && stb && !stall;

    integer k;

    always @(posedge clk) begin
        if (rst || !cyc)
            ack <= 1'b0;
        else
            ack <= accept;

        dat_r <= mem[adr];

        if (accept && we)
            for (k = 0; k < 4; k = k + 1)
                if (sel[k])
                    mem[adr][8*k +: 8] <= dat_w[8*k +: 8];
    end

endmodule
