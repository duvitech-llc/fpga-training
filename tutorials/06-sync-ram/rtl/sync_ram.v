// Simple dual-port RAM: one write port and one read port on one clock.
// rdata appears one clock after a read. A read of the address being written
// returns the old data. There is no reset, so a word holds an unknown value
// until it is first written. DEPTH must be at least 2, and addresses must stay
// below DEPTH.
module sync_ram #(
    parameter WIDTH = 8,
    parameter DEPTH = 256
) (
    input  wire                     clk,
    input  wire                     we,     // write wdata to waddr
    input  wire [$clog2(DEPTH)-1:0] waddr,
    input  wire [WIDTH-1:0]         wdata,
    input  wire                     re,     // read raddr, rdata holds when low
    input  wire [$clog2(DEPTH)-1:0] raddr,
    output reg  [WIDTH-1:0]         rdata
);

    reg [WIDTH-1:0] mem [0:DEPTH-1];

    always @(posedge clk) begin
        if (we)
            mem[waddr] <= wdata;
        if (re)
            rdata <= mem[raddr];
    end

`ifdef FORMAL
    // The solver chooses one address and one value, and they stay constant for
    // the whole proof. It may choose any of them, so the proof covers them all.
    (* anyconst *) reg [$clog2(DEPTH)-1:0] watch_addr;
    (* anyconst *) reg [WIDTH-1:0]         watch_data;

    // High while the watched word holds watch_data. The last write decides.
    reg holds = 1'b0;
    always @(posedge clk) begin
        if (we && waddr == watch_addr)
            holds <= (wdata == watch_data);
    end

    // $past needs one clock of history before it is meaningful.
    reg past_valid = 1'b0;
    always @(posedge clk)
        past_valid <= 1'b1;

    // With a DEPTH that is not a power of two, some addresses have no word.
    always @(*)
        assume (watch_addr < DEPTH);

    // The invariant. Without it k-induction may start from a state where holds
    // is high but the memory disagrees.
    always @(*) begin
        if (holds)
            assert (mem[watch_addr] == watch_data);
    end

    always @(posedge clk) begin
        if (past_valid) begin
            // $past(holds) is the state before the edge, so this also says that
            // a read during a write of the same address returns the old data.
            if ($past(re) && $past(raddr) == watch_addr && $past(holds))
                assert (rdata == watch_data);

            if (!$past(re))
                assert (rdata == $past(rdata));
        end
    end
`endif

endmodule
