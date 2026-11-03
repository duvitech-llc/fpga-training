// The display controller's pixel side: everything here runs on the pixel
// clock. Tutorial 32's timing generator says where the beam is; this module
// takes words from the dual-clock FIFO and turns each byte into a pixel.
//
// A pixel is one byte, RGB332: red in bits 7:5, green in 4:2, blue in 1:0.
// Each 32-bit word holds four pixels, the leftmost in bits 7:0, as the core
// stores bytes. The framebuffer has exactly the visible size: WIDTH is
// H_ACTIVE and HEIGHT is V_ACTIVE, and WIDTH must be a multiple of 4.
//
// A frame, from the pixel side. When vertical blanking starts, show_next takes
// ENABLE, synchronised: it says whether the next frame will be shown, and the
// bus side reads it to decide whether to fetch that frame. Both sides see the
// same decision, so the reader sends exactly WORDS words for every frame shown.
// At the first pixel of a frame, show takes show_next, and owed grows by WORDS.
// Every fourth visible pixel of a shown frame takes one word. A word that is
// due while the FIFO is empty is an underrun: UNDERRUN goes high and stays
// high, and the pixels show the old word. The word is still owed, so in the
// vertical blanking the pixel side takes and throws away whatever is owed, and
// the next frame starts in step again.
//
// The pipeline, as in Tutorials 15 and 32. On the clock where the timing
// generator gives x and de, the FIFO is read. Its word arrives on the next
// clock, the byte for the pixel is picked, and on the clock after that the
// colour leaves, registered, with de, hsync and vsync each delayed by two
// clocks to stay with it.
module display_pixel #(
    parameter integer H_ACTIVE = 160,
    parameter integer H_FRONT  = 8,
    parameter integer H_SYNC   = 16,
    parameter integer H_BACK   = 16,
    parameter integer V_ACTIVE = 120,
    parameter integer V_FRONT  = 2,
    parameter integer V_SYNC   = 3,
    parameter integer V_BACK   = 5,
    parameter [0:0]   H_POL    = 1'b1,
    parameter [0:0]   V_POL    = 1'b1
) (
    input  wire        pclk,
    input  wire        prst,          // synchronous to pclk, active high
    input  wire        enable_b,      // CTRL's ENABLE, from the system clock's domain
    // The FIFO's read side
    output wire        fifo_rd,
    input  wire [31:0] fifo_data,     // valid the clock after a read
    input  wire        fifo_empty,
    // To the system clock's domain
    output reg         vblank,
    output reg         show_next,
    output reg         underrun,
    // To the DVI transmitter
    output reg         de_o,
    output reg         hsync_o,
    output reg         vsync_o,
    output reg  [7:0]  r_o,
    output reg  [7:0]  g_o,
    output reg  [7:0]  b_o
);

    localparam integer WORDS = H_ACTIVE * V_ACTIVE / 4;
    localparam integer XW    = $clog2(H_ACTIVE + H_FRONT + H_SYNC + H_BACK);
    localparam integer YW    = $clog2(V_ACTIVE + V_FRONT + V_SYNC + V_BACK);
    localparam integer OW    = $clog2(2 * WORDS + 1);

    wire          hsync, vsync, de, frame_start;
    wire [XW-1:0] x;
    wire [YW-1:0] y;

    video_timing #(
        .H_ACTIVE(H_ACTIVE), .H_FRONT(H_FRONT), .H_SYNC(H_SYNC), .H_BACK(H_BACK),
        .V_ACTIVE(V_ACTIVE), .V_FRONT(V_FRONT), .V_SYNC(V_SYNC), .V_BACK(V_BACK),
        .H_POL(H_POL), .V_POL(V_POL)
    ) u_timing (
        .clk(pclk), .rst(prst),
        .hsync(hsync), .vsync(vsync), .de(de), .x(x), .y(y), .frame_start(frame_start)
    );

    wire enable;
    sync_2ff u_sync_enable (.clk(pclk), .rst(prst), .d(enable_b), .q(enable));

    // ----- Stage 1: which word is due -----

    reg          show;
    reg [OW-1:0] owed;          // words of shown frames not yet taken

    wire in_vblank = y >= V_ACTIVE[YW-1:0];
    wire show_now  = frame_start ? show_next : show;
    wire due       = de && show_now && x[1:0] == 2'b00;
    wire catch_up  = in_vblank && owed != {OW{1'b0}};
    wire take      = fifo_rd && !fifo_empty;

    assign fifo_rd = due || catch_up;

    always @(posedge pclk) begin
        if (prst) begin
            vblank    <= 1'b0;
            show_next <= 1'b0;
            show      <= 1'b0;
            owed      <= {OW{1'b0}};
            underrun  <= 1'b0;
        end else begin
            vblank <= in_vblank;
            if (y == V_ACTIVE[YW-1:0] && x == {XW{1'b0}})
                show_next <= enable;
            if (frame_start)
                show <= show_next;
            owed <= owed + ((frame_start && show_next) ? WORDS[OW-1:0] : {OW{1'b0}})
                         - {{(OW-1){1'b0}}, take};
            if (due && fifo_empty)
                underrun <= 1'b1;
        end
    end

    // ----- Stage 2: the byte, from the word that has just arrived -----

    reg       de_1, hsync_1, vsync_1, show_1;
    reg [1:0] x_1;

    always @(posedge pclk) begin
        de_1    <= de;
        hsync_1 <= hsync;
        vsync_1 <= vsync;
        show_1  <= show_now;
        x_1     <= x[1:0];
    end

    wire [7:0] pixel = fifo_data[{x_1, 3'b000} +: 8];

    // ----- Stage 3: RGB332 to 8 bits a colour, by repeating the bits -----

    always @(posedge pclk) begin
        if (prst) begin
            de_o    <= 1'b0;
            hsync_o <= !H_POL;
            vsync_o <= !V_POL;
            r_o     <= 8'd0;
            g_o     <= 8'd0;
            b_o     <= 8'd0;
        end else begin
            de_o    <= de_1;
            hsync_o <= hsync_1;
            vsync_o <= vsync_1;
            if (de_1 && show_1) begin
                r_o <= {pixel[7:5], pixel[7:5], pixel[7:6]};
                g_o <= {pixel[4:2], pixel[4:2], pixel[4:3]};
                b_o <= {4{pixel[1:0]}};
            end else begin
                r_o <= 8'd0;
                g_o <= 8'd0;
                b_o <= 8'd0;
            end
        end
    end

endmodule
