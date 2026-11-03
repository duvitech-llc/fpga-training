// A first-in, first-out queue on one clock. DEPTH must be a power of two, at
// least 2. Reads take one clock: rd_data is valid after the edge that accepts
// rd_en. A write while full and a read while empty are ignored.
module sync_fifo #(
    parameter WIDTH = 8,
    parameter DEPTH = 16
) (
    input  wire             clk,
    input  wire             rst,      // synchronous, active high, overrides wr_en and rd_en
    input  wire             wr_en,
    input  wire [WIDTH-1:0] wr_data,
    output wire             full,     // high when a write would be ignored
    input  wire             rd_en,
    output reg  [WIDTH-1:0] rd_data,  // holds its value until the next accepted read
    output wire             empty     // high when a read would be ignored
);

    localparam integer ADDR = $clog2(DEPTH);

    reg [WIDTH-1:0] mem [0:DEPTH-1];

    // One bit wider than the address. The low bits pick the memory entry, and
    // the top bit tells whether the pointer has gone round one more time.
    reg [ADDR:0] wr_ptr;
    reg [ADDR:0] rd_ptr;

    wire same_entry = wr_ptr[ADDR-1:0] == rd_ptr[ADDR-1:0];
    wire same_lap   = wr_ptr[ADDR] == rd_ptr[ADDR];

    assign empty = same_entry && same_lap;
    assign full  = same_entry && !same_lap;

    wire do_write = !rst && wr_en && !full;
    wire do_read  = !rst && rd_en && !empty;

    always @(posedge clk) begin
        if (do_write)
            mem[wr_ptr[ADDR-1:0]] <= wr_data;
        if (do_read)
            rd_data <= mem[rd_ptr[ADDR-1:0]];
    end

    always @(posedge clk) begin
        if (rst) begin
            wr_ptr <= 0;
            rd_ptr <= 0;
        end else begin
            if (do_write)
                wr_ptr <= wr_ptr + 1'b1;
            if (do_read)
                rd_ptr <= rd_ptr + 1'b1;
        end
    end

`ifdef FORMAL
    // $past needs one clock of history before it is meaningful.
    reg past_valid = 1'b0;
    always @(posedge clk)
        past_valid <= 1'b1;

    // Without this the solver may start the pointers more than DEPTH apart.
    always @(posedge clk) begin
        if (!past_valid)
            assume (rst);
    end

    // When a write and a read happen, by the ports. These match do_write and
    // do_read on purpose, so they are not independent of the design. What checks
    // the design is the count below: it is kept apart from the pointers, and the
    // assertions tie full, empty and the data to it.
    wire f_write = !rst && wr_en && !full;
    wire f_read  = !rst && rd_en && !empty;

    // Occupancy, counted separately from the pointers.
    reg [ADDR:0] f_count = 0;
    always @(posedge clk) begin
        if (rst)
            f_count <= 0;
        else
            f_count <= f_count + f_write - f_read;
    end

    wire [ADDR:0] f_distance = wr_ptr - rd_ptr;

    always @(posedge clk) begin
        if (past_valid) begin
            assert (f_count <= DEPTH);
            assert (f_count == f_distance);
            assert (full == (f_count == DEPTH));
            assert (empty == (f_count == 0));

            // Lesson 6's read-during-write case can never happen here.
            assert (!(f_write && f_read && same_entry));

            if ($past(rst)) begin
                assert (wr_ptr == 0);
                assert (rd_ptr == 0);
            end else begin
                // f_write and f_read are low on overflow and underflow.
                assert (wr_ptr == $past(wr_ptr) + $past(f_write));
                assert (rd_ptr == $past(rd_ptr) + $past(f_read));
            end

            if (!$past(f_read))
                assert (rd_data == $past(rd_data));
        end
    end

    // Ordering. The solver picks one write, by its pointer value and its data.
    // If that write found f_ahead entries in front of it, then exactly
    // f_ahead reads later the next read must return its data. The solver may
    // pick any write, so this covers every write.
    (* anyconst *) reg [ADDR:0]    f_tag_ptr;
    (* anyconst *) reg [WIDTH-1:0] f_tag_data;

    reg          f_tagged   = 1'b0;
    reg [ADDR:0] f_ahead    = 0;
    reg          f_returned = 1'b0;

    wire f_tag_write = f_write && wr_ptr == f_tag_ptr && wr_data == f_tag_data;
    wire f_tag_read  = f_read && f_tagged && f_ahead == 0;

    always @(posedge clk) begin
        f_returned <= f_tag_read;

        if (rst) begin
            f_tagged <= 1'b0;
        end else if (f_tag_write) begin
            f_tagged <= 1'b1;
            f_ahead  <= f_count - f_read;
        end else if (f_tag_read) begin
            f_tagged <= 1'b0;
        end else if (f_tagged && f_read) begin
            f_ahead <= f_ahead - 1'b1;
        end
    end

    // The claim.
    always @(posedge clk) begin
        if (f_returned)
            assert (rd_data == f_tag_data);
    end

    // Helpers. Induction starts from any state that passes the assertions, so
    // these tell it what a state with a tagged write looks like.
    wire [ADDR:0] f_tag_position = rd_ptr + f_ahead;

    always @(posedge clk) begin
        if (f_tagged) begin
            assert (f_ahead < f_count);
            assert (f_tag_position == f_tag_ptr);
            assert (mem[f_tag_ptr[ADDR-1:0]] == f_tag_data);
        end
    end

    // A proof says nothing about a case that cannot be reached, so show that
    // the interesting cases can be. f_tag_ptr >= DEPTH means a second lap.
    always @(posedge clk) begin
        if (!rst) begin
            cover (full && wr_en && rd_en);
            cover (empty && wr_en && rd_en);
            cover (f_returned && f_tag_ptr >= DEPTH);
        end
    end
`endif

endmodule
