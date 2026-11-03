// Test pattern: eight colour bars over the top three quarters of the picture, a
// grey strip below them with a white box that moves STEP pixels each frame, and
// a one-pixel white border around the edge.
//
// The colour is registered, so it comes out one clock after the x and y it was
// worked out from. The timing signals go through one register too, so that each
// colour leaves on the same clock as its own de, hsync and vsync.
module test_pattern #(
    parameter integer H_ACTIVE = 640,
    parameter integer V_ACTIVE = 480,
    parameter integer XW       = 10,    // widths of x and y from video_timing
    parameter integer YW       = 10,
    parameter integer BOX      = 32,    // the box is BOX by BOX pixels
    parameter integer STEP     = 8      // and moves this far right each frame
) (
    input  wire          clk,
    input  wire          rst,
    // From video_timing.
    input  wire          hsync,
    input  wire          vsync,
    input  wire          de,
    input  wire [XW-1:0] x,
    input  wire [YW-1:0] y,
    input  wire          frame_start,
    // The same timing, one clock later, with the colour of each pixel.
    output wire          out_hsync,
    output wire          out_vsync,
    output wire          out_de,
    output wire          out_frame_start,
    output reg  [7:0]    r,
    output reg  [7:0]    g,
    output reg  [7:0]    b
);

    localparam integer BAR_H = V_ACTIVE * 3 / 4;                  // height of the bars
    localparam integer BOX_Y = BAR_H + (V_ACTIVE - BAR_H - BOX) / 2;

    // x and y as 32-bit numbers, so they compare with integers at full width.
    wire [31:0] px = {{(32 - XW){1'b0}}, x};
    wire [31:0] py = {{(32 - YW){1'b0}}, y};

    // The left edge of the box. It moves after the last visible pixel of each
    // frame, so a frame never shows the box in two places.
    reg  [XW-1:0] box_x;
    wire [31:0]   bx   = {{(32 - XW){1'b0}}, box_x};
    wire          last = de && px == H_ACTIVE - 1 && py == V_ACTIVE - 1;

    always @(posedge clk) begin
        if (rst)
            box_x <= 0;
        else if (last)
            box_x <= (bx + STEP + BOX > H_ACTIVE) ? {XW{1'b0}} : box_x + STEP[XW-1:0];
    end

    // Which of the eight bars x is in, counting from the left.
    reg [2:0] bar;
    integer   i;
    always @(*) begin
        bar = 3'd0;
        for (i = 1; i < 8; i = i + 1)
            if (px >= i * H_ACTIVE / 8)
                bar = i[2:0];
    end

    wire border = px == 0 || px == H_ACTIVE - 1 || py == 0 || py == V_ACTIVE - 1;
    wire in_box = px >= bx && px < bx + BOX && py >= BOX_Y && py < BOX_Y + BOX;

    // The standard order is white, yellow, cyan, green, magenta, red, blue,
    // black. Read as {green, red, blue}, those are 7, 6, 5 ... 0, so each colour
    // is just the bar number inverted.
    reg [23:0] colour;
    always @(*) begin
        if (!de)
            colour = 24'h000000;      // blanking must be black
        else if (border || in_box)
            colour = 24'hffffff;
        else if (py < BAR_H)
            colour = {{8{!bar[1]}}, {8{!bar[2]}}, {8{!bar[0]}}};
        else
            colour = 24'h404040;
    end

    reg hsync_r, vsync_r, de_r, frame_start_r;

    always @(posedge clk) begin
        {r, g, b}     <= colour;
        hsync_r       <= hsync;
        vsync_r       <= vsync;
        de_r          <= de;
        frame_start_r <= frame_start;
    end

    assign out_hsync       = hsync_r;
    assign out_vsync       = vsync_r;
    assign out_de          = de_r;
    assign out_frame_start = frame_start_r;

endmodule
