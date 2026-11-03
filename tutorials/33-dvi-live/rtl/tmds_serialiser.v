// A 10-to-1 serialiser, behavioural: a shift register on a clock ten times the
// pixel clock. This is a model for simulation. Real DVI and HDMI need the FPGA
// vendor's serialiser primitive, such as OSERDESE2 on Xilinx 7 series, OSER10
// on Gowin, or the DDIO and LVDS blocks on Cyclone V, and differential output
// pins. Those are left out of this course. Nothing here was run on a monitor.
//
// clk_x10 must come from the same source as the pixel clock, ten times as
// fast, as a PLL would make them. word belongs to the pixel clock. The
// serialiser takes it every tenth clk_x10 edge, LOAD edges after rst falls, so
// word must hold still around that edge. tb_dvi.v gives the pixel clock's
// rising edge half a bit before a clk_x10 edge and sets LOAD so the word is
// taken in the middle of the pixel. A vendor serialiser does this alignment in
// its own logic, from the two clocks.
//
// Bit 0 of each word leaves first, as DVI sends it.
module tmds_serialiser #(
    parameter integer LOAD = 4      // which of the ten edges takes the word, 0 to 9
) (
    input  wire       clk_x10,
    input  wire       rst,          // synchronous to clk_x10, active high
    input  wire [9:0] word,
    output reg        q
);

    reg [3:0] count;
    reg [8:0] rest;                 // the bits still to send, bit 0 next

    always @(posedge clk_x10) begin
        if (rst) begin
            count <= 4'd0;
            rest  <= 9'd0;
            q     <= 1'b0;
        end else begin
            count <= (count == 4'd9) ? 4'd0 : count + 4'd1;
            if (count == LOAD[3:0]) begin
                q    <= word[0];
                rest <= word[9:1];
            end else begin
                q    <= rest[0];
                rest <= {1'b0, rest[8:1]};
            end
        end
    end

endmodule
