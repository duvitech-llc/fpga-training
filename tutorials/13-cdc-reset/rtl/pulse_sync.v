// Carries a pulse from src_clk to dst_clk. Each src_clk edge with src_pulse high
// gives one dst_clk cycle of dst_pulse, two or three dst_clk edges later.
//
// The limit: pulses must be at least two dst_clk periods apart. See the README.
//
// Reset both sides together, with a rising edge of each clock while both resets
// are high. If only one side is reset, the two toggles disagree, and that looks
// like a pulse.
module pulse_sync (
    // Source side. Everything here belongs to src_clk.
    input  wire src_clk,
    input  wire src_rst,    // synchronous to src_clk, active high
    input  wire src_pulse,

    // Destination side. Everything here belongs to dst_clk.
    input  wire dst_clk,
    input  wire dst_rst,    // synchronous to dst_clk, active high
    output wire dst_pulse   // one dst_clk cycle high per pulse
);

    // A pulse becomes a change of level. The level stays until the next pulse,
    // so a slow clock has time to see it.
    reg src_toggle;

    always @(posedge src_clk) begin
        if (src_rst)
            src_toggle <= 1'b0;
        else if (src_pulse)
            src_toggle <= ~src_toggle;
    end

    wire dst_level;

`ifdef CHECK_PULSE_SYNC
    wire meta;

    sync_2ff toggle_sync (.clk(dst_clk), .rst(dst_rst), .d(src_toggle), .q(dst_level),
                          .f_meta(meta));
`else
    sync_2ff toggle_sync (.clk(dst_clk), .rst(dst_rst), .d(src_toggle), .q(dst_level));
`endif

    // Any change of level, in either direction, is one pulse.
    reg dst_last;

    always @(posedge dst_clk) begin
        if (dst_rst)
            dst_last <= 1'b0;
        else
            dst_last <= dst_level;
    end

    assign dst_pulse = dst_level ^ dst_last;

`ifdef CHECK_PULSE_SYNC
    // src_clk and dst_clk are plain inputs here, so the solver may raise either
    // at any step. That covers every clock ratio, but every flop is still ideal.
    // Metastability is not modelled at all.
    reg past_valid   = 1'b0;
    reg src_rst_seen = 1'b0;
    reg dst_rst_seen = 1'b0;
    wire reset_done  = src_rst_seen && dst_rst_seen;

    always @($global_clock) begin
        past_valid <= 1'b1;
        if (past_valid && $rose(src_clk))
            src_rst_seen <= 1'b1;
        if (past_valid && $rose(dst_clk))
            dst_rst_seen <= 1'b1;
    end

    // One reset, at the start, of both sides together.
    always @(*) begin
        assume (src_rst == !reset_done);
        assume (dst_rst == !reset_done);
    end

    // What happened at this step of solver time: a pulse leaving the source, a
    // rising edge of dst_clk, and a pulse being taken at the destination.
    reg src_clk_prev   = 1'b0;
    reg dst_clk_prev   = 1'b0;
    reg src_pulse_prev = 1'b0;
    reg dst_pulse_prev = 1'b0;
    reg src_rst_prev   = 1'b1;
    reg dst_rst_prev   = 1'b1;

    always @($global_clock) begin
        src_clk_prev   <= src_clk;
        dst_clk_prev   <= dst_clk;
        src_pulse_prev <= src_pulse;
        dst_pulse_prev <= dst_pulse;
        src_rst_prev   <= src_rst;
        dst_rst_prev   <= dst_rst;
    end

    wire dst_edge = dst_clk && !dst_clk_prev;
    wire src_sent = src_clk && !src_clk_prev && src_pulse_prev && !src_rst_prev;
    wire dst_took = dst_edge && dst_pulse_prev && !dst_rst_prev;

    // Rising edges of dst_clk since the last pulse left, up to 3.
    reg  [1:0] edges     = 2'd3;
    wire [1:0] edges_now = src_sent                 ? 2'd0 :
                           dst_edge && edges != 2'd3 ? edges + 2'd1 : edges;

    // The spacing limit: one rising edge of dst_clk strictly between two pulses.
    // That is weaker than the two periods the README asks for, so a design that
    // keeps the README's rule also meets this.
    always @(*) begin
        if (src_sent)
            assume (edges != 2'd0);
    end

    // Pulses sent and pulses taken, as wrapping counts.
    reg  [2:0] sent = 3'd0;
    reg  [2:0] took = 3'd0;
    wire [2:0] sent_now = sent + src_sent;
    wire [2:0] took_now = took + dst_took;

    always @($global_clock) begin
        edges <= edges_now;
        sent  <= sent_now;
        took  <= took_now;
    end

    // Each change of level still on its way down the chain of flops.
    wire [2:0] in_flight = (src_toggle ^ meta) + (meta ^ dst_level) + (dst_level ^ dst_last);

    // During the reset, a side that has been reset stays at zero.
    always @(*) begin
        if (src_rst_seen && !reset_done)
            assert (src_toggle == 1'b0);
        if (dst_rst_seen && !reset_done)
            assert (meta == 1'b0 && dst_level == 1'b0 && dst_last == 1'b0);
        if (!reset_done)
            assert (sent == 3'd0 && took == 3'd0 && edges == 2'd3);
    end

    always @(*) begin
        if (reset_done) begin
            // Every pulse sent has been taken or is in the chain. None was lost,
            // none was doubled, and none came from nowhere.
            assert (sent_now - took_now == in_flight);

            // The chain drains: a pulse has been delivered after three edges.
            if (edges_now >= 2'd1)
                assert (src_toggle == meta);
            if (edges_now >= 2'd2)
                assert (meta == dst_level);
            if (edges_now == 2'd3)
                assert (in_flight == 3'd0);
        end
    end

    // Show that the proof is not empty.
    always @(*) begin
        if (reset_done) begin
            cover (dst_pulse);
            cover (in_flight == 3'd3);  // three pulses in the chain at once
        end
    end
`endif

endmodule
