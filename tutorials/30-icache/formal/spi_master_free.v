// For the proof of wb_xip only: a stand-in for Tutorial 24's spi_master with the
// same ports, whose outputs the solver chooses freely on every clock. wb_xip's
// proof assumes the one rule of the byte interface it relies on.
//
// Tutorial 24 proved the master itself. Here it is replaced so that the proof is
// about the slave's side alone, and so that the cover traces need not wait for
// real bytes on the wire, which take 35 clocks each.
module spi_master #(
    parameter DIV_WIDTH = 8
) (
    input  wire                 clk,
    input  wire                 rst,
    input  wire                 cpol,
    input  wire                 cpha,
    input  wire [DIV_WIDTH-1:0] clk_div,
    input  wire                 tx_valid,
    input  wire [7:0]           tx_data,
    input  wire                 tx_last,
    output wire                 tx_ready,
    output wire                 rx_valid,
    output wire [7:0]           rx_data,
    output wire                 sclk,
    output wire                 mosi,
    input  wire                 miso,
    output wire                 cs_n
);

    (* anyseq *) reg       f_ready, f_rx_valid, f_sclk, f_mosi, f_cs_n;
    (* anyseq *) reg [7:0] f_rx_data;

    assign tx_ready = f_ready;
    assign rx_valid = f_rx_valid;
    assign rx_data  = f_rx_data;
    assign sclk     = f_sclk;
    assign mosi     = f_mosi;
    assign cs_n     = f_cs_n;

endmodule
