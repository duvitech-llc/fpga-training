// Tutorial 14's UART as a Wishbone B4 pipelined slave, with the registers of
// Tutorial 19's computer, widened to 32-bit words:
//
//   BASE + 0x0  status, read: bit 0 the transmitter is ready, bit 1 a received
//               byte is waiting, bit 2 a frame had a low stop bit. The other
//               bits read 0. Any write clears bit 2.
//   BASE + 0x4  data. A read returns the waiting byte in bits 7 to 0, and takes
//               it. A write with sel[0] high sends bits 7 to 0 of dat_w. A byte
//               written while the transmitter is busy is lost, so poll bit 0
//               first, as in Tutorial 19.
//
// Tutorial 29 adds one output, tx_ready, so a DMA engine can wait for the
// transmitter without polling the status register over the bus.
//
// adr is one bit: the word within the slave. The interconnect has checked the rest.
// Each request gets ack on the next clock, never err. hold stalls requests, as
// in wb_regfile. Tie it low in a real design.
module wb_uart #(
    parameter CLKS_PER_BIT = 16
) (
    input  wire        clk,
    input  wire        rst,     // synchronous, active high
    input  wire        cyc,
    input  wire        stb,
    input  wire        we,
    input  wire        adr,     // 0 status, 1 data
    input  wire [3:0]  sel,
    input  wire [31:0] dat_w,
    output reg         ack,
    output wire        err,
    output wire        stall,
    output reg  [31:0] dat_r,
    input  wire        hold,
    // The serial lines
    output wire        tx,
    input  wire        rx,      // asynchronous: uart_rx synchronizes it
    // New in Tutorial 29, for the DMA engine: a byte written to the data register
    // now would be sent, not lost. It is status bit 0, as a wire.
    output wire        tx_ready
);

    assign stall = hold;
    assign err   = 1'b0;

    wire accept = cyc && stb && !stall;

    wire tx_write     = accept && we && adr && sel[0];
    wire rx_read      = accept && !we && adr;
    wire status_write = accept && we && !adr;

    wire       rx_valid, rx_error;
    wire [7:0] rx_data;

    uart #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart (
        .clk(clk), .rst(rst),
        .tx_valid(tx_write), .tx_data(dat_w[7:0]), .tx_ready(tx_ready), .tx(tx),
        .rx(rx), .rx_valid(rx_valid), .rx_data(rx_data), .rx_error(rx_error)
    );

    // As in Tutorial 19: a byte that lands on the edge of a read is left waiting,
    // and a byte that arrives while one is already waiting replaces it.
    reg [7:0] rx_hold;
    reg       rx_waiting;
    reg       rx_err_seen;

    wire [31:0] status = {29'd0, rx_err_seen, rx_waiting, tx_ready};

    always @(posedge clk) begin
        if (rst) begin
            rx_hold     <= 8'd0;
            rx_waiting  <= 1'b0;
            rx_err_seen <= 1'b0;
        end else begin
            if (rx_valid) begin
                rx_hold    <= rx_data;
                rx_waiting <= 1'b1;
            end else if (rx_read) begin
                rx_waiting <= 1'b0;
            end

            if (rx_error)
                rx_err_seen <= 1'b1;
            else if (status_write)
                rx_err_seen <= 1'b0;
        end

        if (rst || !cyc)
            ack <= 1'b0;
        else
            ack <= accept;

        if (accept)
            dat_r <= adr ? {24'd0, rx_hold} : status;
    end

    // Only byte 0 of a write is used.
    wire unused = &{1'b0, sel[3:1], dat_w[31:8]};

endmodule
