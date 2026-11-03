// A Wishbone B4 pipelined slave with one 32-bit output register, for LEDs or
// any other pins:
//
//   BASE + 0x0  gpio_out, read/write, reset to 0. A write changes only the bytes
//               whose sel bit is high. A read returns the whole word.
//
// The slave has one word, so it needs no address bits: the interconnect sends it
// only requests for that word. Each request gets ack on the next clock, never
// err. hold stalls requests, as in wb_regfile. Tie it low in a real design.
module wb_gpio (
    input  wire        clk,
    input  wire        rst,     // synchronous, active high
    input  wire        cyc,
    input  wire        stb,
    input  wire        we,
    input  wire [3:0]  sel,
    input  wire [31:0] dat_w,
    output reg         ack,
    output wire        err,
    output wire        stall,
    output reg  [31:0] dat_r,
    input  wire        hold,
    output reg  [31:0] gpio_out
);

    assign stall = hold;
    assign err   = 1'b0;

    wire accept = cyc && stb && !stall;

    integer k;

    always @(posedge clk) begin
        if (rst) begin
            gpio_out <= 32'd0;
        end else if (accept && we) begin
            for (k = 0; k < 4; k = k + 1)
                if (sel[k])
                    gpio_out[8*k +: 8] <= dat_w[8*k +: 8];
        end

        if (rst || !cyc)
            ack <= 1'b0;
        else
            ack <= accept;

        if (accept)
            dat_r <= gpio_out;
    end

endmodule
