// A FIFO with a separate clock for each side. Holds 2**ADDR_WIDTH words.
// ADDR_WIDTH must be at least 2.
//
// Tutorial 33: Tutorial 10's FIFO with two outputs added, wr_used and rd_used,
// the number of words held as each side can tell. Each is worked out from that
// side's own pointer and its synchronised copy of the other's, the copies that
// full and empty already use, so nothing new crosses between the clocks. Like
// the flags, each errs only in the safe direction: wr_used is never less than
// the true count, so a writer that trusts it never overflows, and rd_used is
// never more, so a reader that trusts it never underflows.
//
// Reset: each reset is synchronous to its own clock. The design assumes the two
// are used together: both high at once, for long enough that each clock has a
// rising edge while both are high. Never reset only one side. See the README.
module async_fifo #(
    parameter WIDTH      = 8,
    parameter ADDR_WIDTH = 4
) (
    // Write side. Everything here belongs to wr_clk.
    input  wire             wr_clk,
    input  wire             wr_rst,   // synchronous to wr_clk, active high
    input  wire             wr_en,    // ignored while full is high
    input  wire [WIDTH-1:0] wr_data,
    output wire             full,
    output wire [ADDR_WIDTH:0] wr_used,  // words held, never less than the truth

    // Read side. Everything here belongs to rd_clk.
    input  wire             rd_clk,
    input  wire             rd_rst,   // synchronous to rd_clk, active high
    input  wire             rd_en,    // ignored while empty is high
    output reg  [WIDTH-1:0] rd_data,  // valid on the clock after rd_en and !empty
    output wire             empty,
    output wire [ADDR_WIDTH:0] rd_used   // words held, never more than the truth
);

    localparam integer DEPTH = 1 << ADDR_WIDTH;

    reg [WIDTH-1:0] mem [0:DEPTH-1];

    wire wr_ok = wr_en && !full;
    wire rd_ok = rd_en && !empty;

    wire [ADDR_WIDTH-1:0] wr_addr;
    wire [ADDR_WIDTH-1:0] rd_addr;
    wire [ADDR_WIDTH:0]   wr_gray;
    wire [ADDR_WIDTH:0]   rd_gray;

    gray_ptr #(.ADDR_WIDTH(ADDR_WIDTH)) wr_ptr (
        .clk(wr_clk), .rst(wr_rst), .inc(wr_ok), .addr(wr_addr), .gray(wr_gray)
    );

    gray_ptr #(.ADDR_WIDTH(ADDR_WIDTH)) rd_ptr (
        .clk(rd_clk), .rst(rd_rst), .inc(rd_ok), .addr(rd_addr), .gray(rd_gray)
    );

    // The two synchronizers. These four registers are the only places where a
    // signal from one clock domain is sampled by the other. The _meta stage is
    // where a flop can go metastable, and only the _sync stage reads it.
    reg [ADDR_WIDTH:0] rd_gray_meta;  // clocked by wr_clk
    reg [ADDR_WIDTH:0] rd_gray_sync;  // clocked by wr_clk
    reg [ADDR_WIDTH:0] wr_gray_meta;  // clocked by rd_clk
    reg [ADDR_WIDTH:0] wr_gray_sync;  // clocked by rd_clk

    always @(posedge wr_clk) begin
        if (wr_rst) begin
            rd_gray_meta <= 0;
            rd_gray_sync <= 0;
        end else begin
            rd_gray_meta <= rd_gray;
            rd_gray_sync <= rd_gray_meta;
        end
    end

    always @(posedge rd_clk) begin
        if (rd_rst) begin
            wr_gray_meta <= 0;
            wr_gray_sync <= 0;
        end else begin
            wr_gray_meta <= wr_gray;
            wr_gray_sync <= wr_gray_meta;
        end
    end

    // Each flag compares this side's pointer with an old copy of the other's.
    // Full: the pointers are DEPTH apart. In Gray code that means the top two
    // bits differ and the rest are the same.
    assign full  = wr_gray == {~rd_gray_sync[ADDR_WIDTH:ADDR_WIDTH-1],
                               rd_gray_sync[ADDR_WIDTH-2:0]};
    assign empty = rd_gray == wr_gray_sync;

    // Tutorial 33. Gray code back to binary: each bit is the XOR of itself and
    // every bit above it.
    function [ADDR_WIDTH:0] to_bin(input [ADDR_WIDTH:0] g);
        integer i;
        begin
            to_bin[ADDR_WIDTH] = g[ADDR_WIDTH];
            for (i = ADDR_WIDTH - 1; i >= 0; i = i - 1)
                to_bin[i] = to_bin[i + 1] ^ g[i];
        end
    endfunction

    // The counts wrap at 2 * DEPTH, so their difference is the number of words
    // between them, as long as that is at most DEPTH.
    assign wr_used = to_bin(wr_gray) - to_bin(rd_gray_sync);
    assign rd_used = to_bin(wr_gray_sync) - to_bin(rd_gray);

    always @(posedge wr_clk) begin
        if (wr_ok)
            mem[wr_addr] <= wr_data;
    end

    always @(posedge rd_clk) begin
        if (rd_ok)
            rd_data <= mem[rd_addr];
    end

`ifdef FORMAL
    // Each step of $global_clock is one instant of solver time. wr_clk and
    // rd_clk are plain inputs here, so the solver may raise either at any step.
    // That covers every clock ratio, but every flop is still ideal: a sampled
    // bit is exactly 0 or exactly 1. Metastability is not modelled at all.
    reg  past_valid  = 1'b0;
    reg  wr_rst_seen = 1'b0;
    reg  rd_rst_seen = 1'b0;
    wire reset_done  = wr_rst_seen && rd_rst_seen;

    always @($global_clock) begin
        past_valid <= 1'b1;
        if (past_valid && $rose(wr_clk))
            wr_rst_seen <= 1'b1;
        if (past_valid && $rose(rd_clk))
            rd_rst_seen <= 1'b1;
    end

    // The reset assumption from the top of this file: both resets stay high
    // until each clock has risen. The proofs cover one reset, at the start.
    always @(*) begin
        assume (wr_rst == !reset_done);
        assume (rd_rst == !reset_done);
    end

`ifdef CHECK_GRAY
    // Each pointer moves at most one bit per clock of its own, and not at all
    // between clocks.
    always @($global_clock) begin
        if (past_valid && reset_done && $past(reset_done)) begin
            if ($rose(wr_clk))
                assert ($onehot0(wr_gray ^ $past(wr_gray)));
            else
                assert ($stable(wr_gray));

            if ($rose(rd_clk))
                assert ($onehot0(rd_gray ^ $past(rd_gray)));
            else
                assert ($stable(rd_gray));
        end
    end
`else
    function [ADDR_WIDTH:0] gray2bin(input [ADDR_WIDTH:0] g);
        integer i;
        begin
            gray2bin[ADDR_WIDTH] = g[ADDR_WIDTH];
            for (i = ADDR_WIDTH - 1; i >= 0; i = i - 1)
                gray2bin[i] = gray2bin[i + 1] ^ g[i];
        end
    endfunction

    // Every pointer and every copy of a pointer, as a binary count.
    wire [ADDR_WIDTH:0] wp = gray2bin(wr_gray);
    wire [ADDR_WIDTH:0] w1 = gray2bin(wr_gray_meta);
    wire [ADDR_WIDTH:0] w2 = gray2bin(wr_gray_sync);
    wire [ADDR_WIDTH:0] rp = gray2bin(rd_gray);
    wire [ADDR_WIDTH:0] r1 = gray2bin(rd_gray_meta);
    wire [ADDR_WIDTH:0] r2 = gray2bin(rd_gray_sync);

    localparam [ADDR_WIDTH:0] DEPTH_P = 1 << ADDR_WIDTH;
    wire [ADDR_WIDTH:0] used = wp - rp;

    // During the reset, a side that has been reset stays at zero.
    always @(*) begin
        if (wr_rst_seen && !reset_done)
            assert (wr_gray == 0 && rd_gray_meta == 0 && rd_gray_sync == 0);
        if (rd_rst_seen && !reset_done)
            assert (rd_gray == 0 && wr_gray_meta == 0 && wr_gray_sync == 0);
    end

    always @(*) begin
        if (reset_done) begin
            // Overflow and underflow.
            assert (used <= DEPTH_P);
            assert (!(wr_ok && used == DEPTH_P));
            assert (!(rd_ok && used == 0));

            // Pessimism: each copy is an older value of the pointer. Going
            // forward from the older end, the pointers come in this order.
            assert ((r1 - r2) <= (rp - r2));
            assert ((rp - r2) <= (wp - r2));
            assert ((wp - r2) <= DEPTH_P);
            assert ((w2 - rp) <= (w1 - rp));
            assert ((w1 - rp) <= used);

            // A flag is only ever wrong because its copy is old. With an
            // up-to-date copy it is exact, so it cannot simply stick high.
            if (rd_gray_sync == rd_gray)
                assert (full == (used == DEPTH_P));
            if (wr_gray_sync == wr_gray)
                assert (empty == (used == 0));

            // Tutorial 33: the two levels err only on the safe side.
            assert (wr_used == wp - r2);
            assert (rd_used == w2 - rp);
            assert (wr_used >= used && wr_used <= DEPTH_P);
            assert (rd_used <= used);
        end
    end

    // Each memory address matches its Gray pointer.
    always @(*) begin
        if (reset_done) begin
            assert (wr_addr == wp[ADDR_WIDTH-1:0]);
            assert (rd_addr == rp[ADDR_WIDTH-1:0]);
        end
    end

    // Each accepted write or read moves its pointer by exactly one.
    always @($global_clock) begin
        if (past_valid && reset_done && $past(reset_done)) begin
            if ($rose(wr_clk))
                assert (wp == $past(wp) + $past(wr_ok));
            else
                assert (wp == $past(wp));

            if ($rose(rd_clk))
                assert (rp == $past(rp) + $past(rd_ok));
            else
                assert (rp == $past(rp));
        end
    end

    // Ordering. Pick any pointer value and any data, and whenever the word at
    // that pointer is written, let it hold that data. It must stay in memory
    // until read, and come out when the read pointer has the same value. Both
    // pointers count up by one, so words leave in the order they came.
    (* anyconst *) reg [ADDR_WIDTH:0] f_ptr;
    (* anyconst *) reg [WIDTH-1:0]    f_data;

    always @(*) begin
        if (wr_ok && wp == f_ptr)
            assume (wr_data == f_data);
    end

    always @(*) begin
        if (reset_done && (f_ptr - rp) < used)
            assert (mem[f_ptr[ADDR_WIDTH-1:0]] == f_data);
    end

    always @($global_clock) begin
        if (past_valid && $rose(rd_clk) && $past(reset_done) && $past(rd_ok)
                && $past(rp) == f_ptr)
            assert (rd_data == f_data);
    end

    // Show that the proof is not empty, and catch pessimism in the act.
    always @(*) begin
        if (reset_done) begin
            cover (full);
            cover (full && used != DEPTH_P);    // full, yet a slot is free
            cover (empty && used != 0);         // empty, yet a word is waiting
        end
    end

    always @($global_clock) begin
        if (past_valid && $rose(rd_clk) && $past(reset_done) && $past(rd_ok))
            cover ($past(rp) == f_ptr);         // the tracked word comes out
    end
`endif
`endif

endmodule
