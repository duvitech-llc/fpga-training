// A DVI transmitter: three TMDS channels and the clock channel.
//
//   channel 0  blue,  and in blanking C0 = hsync, C1 = vsync
//   channel 1  green, and in blanking C0 = C1 = 0
//   channel 2  red,   and in blanking C0 = C1 = 0
//   clock      the pixel clock, sent as the character 0000011111: five bits
//              high, five low, once per pixel
//
// The encoders run on the pixel clock and the serialisers on clk_x10. The
// outputs are single wires here. On a board each would be a differential pair
// from a vendor serialiser: see tmds_serialiser.v.
//
// The inputs are registered by the encoders, so a character leaves one pixel
// clock after its pixel, then ten bits on each wire.
module dvi_tx #(
    parameter integer LOAD = 4
) (
    input  wire       pclk,
    input  wire       prst,          // synchronous to pclk, active high
    input  wire       clk_x10,
    input  wire       de,
    input  wire       hsync,
    input  wire       vsync,
    input  wire [7:0] r,
    input  wire [7:0] g,
    input  wire [7:0] b,
    output wire [9:0] q0,            // the characters, for testbenches to watch
    output wire [9:0] q1,
    output wire [9:0] q2,
    output wire [2:0] tmds_data,     // serial, channel 0 in bit 0
    output wire       tmds_clk
);

    tmds_encoder u_enc0 (.clk(pclk), .rst(prst), .de(de), .d(b), .c({vsync, hsync}), .q(q0));
    tmds_encoder u_enc1 (.clk(pclk), .rst(prst), .de(de), .d(g), .c(2'b00),          .q(q1));
    tmds_encoder u_enc2 (.clk(pclk), .rst(prst), .de(de), .d(r), .c(2'b00),          .q(q2));

    // prst belongs to pclk. clk_x10 comes from the same source, so prst is
    // synchronous to it too; see tmds_serialiser.v.
    tmds_serialiser #(.LOAD(LOAD)) u_ser0 (.clk_x10(clk_x10), .rst(prst), .word(q0), .q(tmds_data[0]));
    tmds_serialiser #(.LOAD(LOAD)) u_ser1 (.clk_x10(clk_x10), .rst(prst), .word(q1), .q(tmds_data[1]));
    tmds_serialiser #(.LOAD(LOAD)) u_ser2 (.clk_x10(clk_x10), .rst(prst), .word(q2), .q(tmds_data[2]));
    tmds_serialiser #(.LOAD(LOAD)) u_serc (.clk_x10(clk_x10), .rst(prst), .word(10'b0000011111),
                                           .q(tmds_clk));

endmodule
