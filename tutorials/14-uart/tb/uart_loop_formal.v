// A bounded check of one whole byte: tx wired to rx, the byte chosen by the solver.
// This is a fixed-depth search, not a proof for all time. See the README.
module uart_loop_formal #(
    parameter CLKS_PER_BIT = 4
) (
    input wire clk,
    input wire rst
);

    (* anyconst *) reg [7:0] watch_data;

    reg       past_valid = 1'b0;
    reg       sent       = 1'b0;
    reg [7:0] age        = 8'd0;

    wire       line;
    wire       tx_ready;
    wire       rx_valid;
    wire [7:0] rx_data;
    wire       rx_error;
    wire       tx_valid = !sent;

    uart #(.CLKS_PER_BIT(CLKS_PER_BIT)) dut (
        .clk(clk), .rst(rst),
        .tx_valid(tx_valid), .tx_data(watch_data), .tx_ready(tx_ready), .tx(line),
        .rx(line), .rx_valid(rx_valid), .rx_data(rx_data), .rx_error(rx_error)
    );

    always @(posedge clk) begin
        past_valid <= 1'b1;
        if (tx_valid && tx_ready)
            sent <= 1'b1;
        if (sent)
            age <= age + 1'b1;
    end

    // Reset for the first clock, then never again.
    always @(posedge clk)
        assume (rst == !past_valid);

    reg got = 1'b0;
    always @(posedge clk) begin
        if (rx_valid)
            got <= 1'b1;

        if (past_valid) begin
            assert (!rx_error);
            if (rx_valid)
                assert (rx_data == watch_data);
            // The byte must arrive within eleven bit times.
            if (age == 11 * CLKS_PER_BIT)
                assert (got);
        end
    end

endmodule
