// Loads WIDTH bits at once or shifts them one at a time, towards the MSB.
// WIDTH must be at least 2. The priority is rst, then load, then en.
module shift_reg #(
    parameter WIDTH = 8
) (
    input  wire             clk,
    input  wire             rst,          // synchronous, active high, overrides load and en
    input  wire             load,         // copies parallel_in to q, overrides en
    input  wire             en,           // shifts one place, q holds its value when low
    input  wire [WIDTH-1:0] parallel_in,
    input  wire             serial_in,    // enters at q[0]
    output wire             serial_out,   // leaves from q[WIDTH-1], so the MSB goes first
    output reg  [WIDTH-1:0] q
);

    assign serial_out = q[WIDTH-1];

    always @(posedge clk) begin
        if (rst)
            q <= 0;
        else if (load)
            q <= parallel_in;
        else if (en)
            q <= {q[WIDTH-2:0], serial_in};
    end

`ifdef FORMAL
    // $past needs one clock of history before it is meaningful.
    reg past_valid = 1'b0;
    always @(posedge clk)
        past_valid <= 1'b1;

    always @(posedge clk) begin
        if (past_valid) begin
            if ($past(rst))
                assert (q == 0);
            else if ($past(load))
                assert (q == $past(parallel_in));
            else if ($past(en))
                assert (q == {$past(q[WIDTH-2:0]), $past(serial_in)});
            else
                assert (q == $past(q));
        end
    end

    always @(*)
        assert (serial_out == q[WIDTH-1]);
`endif

endmodule
