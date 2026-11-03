// D flip-flop with synchronous reset and clock enable.
module dff (
    input  wire clk,
    input  wire rst,  // synchronous, active high, overrides en
    input  wire en,   // q holds its value when low
    input  wire d,
    output reg  q
);

    always @(posedge clk) begin
        if (rst)
            q <= 1'b0;
        else if (en)
            q <= d;
    end

`ifdef FORMAL
    // $past needs one clock of history before it is meaningful.
    reg past_valid = 1'b0;
    always @(posedge clk)
        past_valid <= 1'b1;

    always @(posedge clk) begin
        if (past_valid) begin
            if ($past(rst))
                assert (q == 1'b0);
            else if ($past(en))
                assert (q == $past(d));
            else
                assert (q == $past(q));
        end
    end
`endif

endmodule
