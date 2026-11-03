// Counts from 0 to MOD-1, then wraps to 0. MOD must be at least 2.
module counter #(
    parameter MOD = 10
) (
    input  wire                   clk,
    input  wire                   rst,    // synchronous, active high, overrides en
    input  wire                   en,     // count holds its value when low
    output reg  [$clog2(MOD)-1:0] count,
    output wire                   wrap    // high when the next rising edge returns count to 0
);

    localparam integer LAST = MOD - 1;

    assign wrap = !rst && en && (count == LAST[$clog2(MOD)-1:0]);

    always @(posedge clk) begin
        if (rst || wrap)
            count <= 0;
        else if (en)
            count <= count + 1'b1;
    end

`ifdef FORMAL
    // $past needs one clock of history before it is meaningful.
    reg past_valid = 1'b0;
    always @(posedge clk)
        past_valid <= 1'b1;

    // Without this the solver may start count at a value above MOD-1.
    always @(posedge clk) begin
        if (!past_valid)
            assume (rst);
    end

    always @(posedge clk) begin
        if (past_valid) begin
            assert (count < MOD);

            if ($past(rst))
                assert (count == 0);
            else if ($past(en) && $past(count) == MOD - 1)
                assert (count == 0);
            else if ($past(en))
                assert (count == $past(count) + 1);
            else
                assert (count == $past(count));
        end
    end

    always @(*)
        assert (wrap == (!rst && en && count == MOD - 1));
`endif

endmodule
