// A Wishbone B4 pipelined slave that controls the instruction cache and counts
// what it does:
//
//   BASE + 0x0  INVALIDATE  write: clear every line of the cache. The data is
//                           ignored. Reads return 0.
//   BASE + 0x4  HITS        read: cacheable fetches the cache answered by itself,
//                           since reset
//   BASE + 0x8  MISSES      read: cacheable fetches that had to fill a line,
//                           since reset
//   BASE + 0xC              reads 0
//
// The counters are 32 bits and wrap. Writes to them are acknowledged and
// ignored, as in wb_counters. Every request gets ack on the next clock, never
// err.
//
// invalidate is high for one clock, the clock in which the write is answered.
// The cache clears its lines at the edge that ends that clock, which is the
// same edge where the core finishes the store. So the core's next fetch already
// finds the cache empty.
//
// hold stalls requests, as in wb_regfile. Tie it low in a real design.
module wb_cachectl (
    input  wire        clk,
    input  wire        rst,     // synchronous, active high
    input  wire        cyc,
    input  wire        stb,
    input  wire        we,
    input  wire [1:0]  adr,     // the word: 0 INVALIDATE, 1 HITS, 2 MISSES
    output reg         ack,
    output wire        err,
    output wire        stall,
    output reg  [31:0] dat_r,
    input  wire        hold,
    // To and from the cache
    output reg         invalidate,
    input  wire        hit,
    input  wire        miss
);

    reg [31:0] hits;
    reg [31:0] misses;

    assign stall = hold;
    assign err   = 1'b0;

    wire accept = cyc && stb && !stall;

    always @(posedge clk) begin
        if (rst) begin
            hits       <= 32'd0;
            misses     <= 32'd0;
            invalidate <= 1'b0;
        end else begin
            if (hit)
                hits <= hits + 32'd1;
            if (miss)
                misses <= misses + 32'd1;
            invalidate <= accept && we && adr == 2'd0;
        end

        if (rst || !cyc)
            ack <= 1'b0;
        else
            ack <= accept;

        if (accept && !we)
            dat_r <= (adr == 2'd1) ? hits :
                     (adr == 2'd2) ? misses :
                                     32'd0;
    end

endmodule
