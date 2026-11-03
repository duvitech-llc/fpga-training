// A Wishbone B4 pipelined slave with two read-only counters, so that a program
// can time itself:
//
//   BASE + 0x0  cycles   clocks since reset
//   BASE + 0x4  instret  instructions retired since reset: the core's retire
//                        output, counted
//
// Both are 32 bits and wrap. A read returns the count at the clock edge that
// accepts it. Writes are acknowledged and ignored. RISC-V has CSRs for the same
// two numbers, mcycle and minstret. This core has no CSRs yet, so here they are
// a peripheral.
//
// adr is one bit: the word within the slave. Each request gets ack on the next
// clock, never err. hold stalls requests, as in wb_regfile. Tie it low in a
// real design.
module wb_counters (
    input  wire        clk,
    input  wire        rst,     // synchronous, active high
    input  wire        cyc,
    input  wire        stb,
    input  wire        we,
    input  wire        adr,     // 0 cycles, 1 instret
    output reg         ack,
    output wire        err,
    output wire        stall,
    output reg  [31:0] dat_r,
    input  wire        hold,
    input  wire        retire   // high for one clock per instruction
);

    reg [31:0] cycles;
    reg [31:0] instret;

    assign stall = hold;
    assign err   = 1'b0;

    wire accept = cyc && stb && !stall;

    always @(posedge clk) begin
        if (rst) begin
            cycles  <= 32'd0;
            instret <= 32'd0;
        end else begin
            cycles <= cycles + 32'd1;
            if (retire)
                instret <= instret + 32'd1;
        end

        if (rst || !cyc)
            ack <= 1'b0;
        else
            ack <= accept;

        if (accept && !we)
            dat_r <= adr ? instret : cycles;
    end

endmodule
