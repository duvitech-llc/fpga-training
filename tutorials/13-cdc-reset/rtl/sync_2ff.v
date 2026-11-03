// Carries one level into the clk domain, two rising edges of clk later.
//
// d may come from any other clock, but it must be the output of a flop in that
// domain, and it must be a single bit. q belongs to clk. A change in d shorter
// than one period of clk can be missed completely, so this is for levels, not
// for pulses. Use pulse_sync for those.
module sync_2ff (
    input  wire clk,
    input  wire rst,    // synchronous to clk, active high
    input  wire d,      // from another clock domain
    output reg  q
`ifdef CHECK_PULSE_SYNC
    ,
    output wire f_meta  // lets the proof in pulse_sync see the first flop
`endif
);

    // meta is where a flop can go metastable. q is its only reader.
    reg meta;

`ifdef CHECK_PULSE_SYNC
    assign f_meta = meta;
`endif

    always @(posedge clk) begin
        if (rst) begin
            meta <= 1'b0;
            q    <= 1'b0;
        end else begin
            meta <= d;
            q    <= meta;
        end
    end

`ifdef CHECK_SYNC_2FF
    // Each step of $global_clock is one instant of solver time. clk is a plain
    // input, and d may change at any step, which is how a signal from another
    // clock behaves. Every flop is still ideal. Metastability is not modelled.
    reg past_valid = 1'b0;
    reg rst_seen   = 1'b0;

    always @($global_clock) begin
        past_valid <= 1'b1;
        if (past_valid && $rose(clk))
            rst_seen <= 1'b1;
    end

    // rst stays high until clk has risen. After that it may do anything.
    always @(*) begin
        if (!rst_seen)
            assume (rst);
    end

    // A reference model: what d was at the last two rising edges of clk.
    reg d_last   = 1'b0;
    reg d_before = 1'b0;

    always @(posedge clk) begin
        d_last   <= rst ? 1'b0 : d;
        d_before <= rst ? 1'b0 : d_last;
    end

    // q is exactly d from two rising edges ago, and it moves only on clk.
    always @(*) begin
        if (rst_seen)
            assert (q == d_before && meta == d_last);
    end

    always @($global_clock) begin
        if (past_valid && rst_seen && $past(rst_seen) && !$rose(clk))
            assert ($stable(q));
    end

    always @(*) begin
        if (rst_seen && !rst)
            cover (q);
    end
`endif

endmodule
