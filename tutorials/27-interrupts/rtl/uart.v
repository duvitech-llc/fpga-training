// One transmitter and one receiver sharing a clock. The two halves are independent.
module uart #(
    parameter CLKS_PER_BIT = 16
) (
    input  wire       clk,
    input  wire       rst,       // synchronous, active high
    input  wire       tx_valid,
    input  wire [7:0] tx_data,
    output wire       tx_ready,
    output wire       tx,
    input  wire       rx,
    output wire       rx_valid,
    output wire [7:0] rx_data,
    output wire       rx_error
);

    uart_tx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_tx (
        .clk(clk), .rst(rst),
        .tx_valid(tx_valid), .tx_data(tx_data), .tx_ready(tx_ready), .tx(tx)
    );

    uart_rx #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_rx (
        .clk(clk), .rst(rst),
        .rx(rx), .rx_valid(rx_valid), .rx_data(rx_data), .rx_error(rx_error)
    );

endmodule
