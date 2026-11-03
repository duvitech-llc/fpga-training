// Turns a reset from anywhere into a reset for the clk domain. rst rises as soon
// as arst rises, with no clock needed, and falls on the second rising edge of
// clk after arst has fallen. Use one of these per clock domain.
module reset_sync (
    input  wire clk,
    input  wire arst,   // asynchronous, active high, from any domain
    output reg  rst     // asserted asynchronously, released on clk
);

    // arst is the only input. The data path is a constant 0 moving down two flops,
    // so the one thing that can be late is the release.
    reg meta;

    always @(posedge clk or posedge arst) begin
        if (arst) begin
            meta <= 1'b1;
            rst  <= 1'b1;
        end else begin
            meta <= 1'b0;
            rst  <= meta;
        end
    end

`ifdef CHECK_RESET_SYNC
    // clk and arst are plain inputs here, so arst may rise and fall at any step,
    // including between clocks. Every flop is still ideal. The recovery and
    // removal times of a real flop are not modelled at all.
    reg past_valid = 1'b0;

    always @($global_clock)
        past_valid <= 1'b1;

    // Without this the solver may start with the flops at any value.
    always @(*) begin
        if (!past_valid)
            assume (arst);
    end

    // Rising edges of clk since arst was last high, up to 2. A flop here samples
    // the step before a clock edge, so an edge counts if arst was low by then.
    reg        clk_prev  = 1'b0;
    reg        arst_prev = 1'b1;
    reg  [1:0] edges     = 2'd0;
    wire       clk_rose  = clk && !clk_prev && !arst_prev;
    wire [1:0] edges_now = arst                       ? 2'd0 :
                           clk_rose && edges != 2'd2  ? edges + 2'd1 : edges;

    always @($global_clock) begin
        clk_prev  <= clk;
        arst_prev <= arst;
        edges     <= edges_now;
    end

    // rst is high with no clock at all while arst is high, and it stays high
    // until exactly the second rising edge after. So it can only fall on clk.
    always @(*) begin
        assert (edges_now != 2'd3);
        assert (meta == (edges_now == 2'd0));
        assert (rst == (edges_now != 2'd2));
    end

    // Show that the proof is not empty: rst falls, then a new reset arrives.
    always @($global_clock) begin
        if (past_valid)
            cover ($past(!rst) && arst && !clk);
    end
`endif

endmodule
