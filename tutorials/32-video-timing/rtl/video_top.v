// The timing generator and the test pattern, joined. The outputs are what a
// video encoder needs: sync, display enable and a colour for every clock.
module video_top #(
    parameter integer H_ACTIVE = 640,
    parameter integer H_FRONT  = 16,
    parameter integer H_SYNC   = 96,
    parameter integer H_BACK   = 48,
    parameter integer V_ACTIVE = 480,
    parameter integer V_FRONT  = 10,
    parameter integer V_SYNC   = 2,
    parameter integer V_BACK   = 33,
    parameter [0:0]   H_POL    = 1'b0,
    parameter [0:0]   V_POL    = 1'b0,
    parameter integer BOX      = 32,
    parameter integer STEP     = 8
) (
    input  wire       clk,
    input  wire       rst,
    output wire       hsync,
    output wire       vsync,
    output wire       de,
    output wire       frame_start,
    output wire [7:0] r,
    output wire [7:0] g,
    output wire [7:0] b
);

    localparam integer XW = $clog2(H_ACTIVE + H_FRONT + H_SYNC + H_BACK);
    localparam integer YW = $clog2(V_ACTIVE + V_FRONT + V_SYNC + V_BACK);

    wire          t_hsync, t_vsync, t_de, t_frame_start;
    wire [XW-1:0] t_x;
    wire [YW-1:0] t_y;

    video_timing #(
        .H_ACTIVE(H_ACTIVE), .H_FRONT(H_FRONT), .H_SYNC(H_SYNC), .H_BACK(H_BACK),
        .V_ACTIVE(V_ACTIVE), .V_FRONT(V_FRONT), .V_SYNC(V_SYNC), .V_BACK(V_BACK),
        .H_POL(H_POL), .V_POL(V_POL)
    ) timing (
        .clk(clk), .rst(rst),
        .hsync(t_hsync), .vsync(t_vsync), .de(t_de),
        .x(t_x), .y(t_y), .frame_start(t_frame_start)
    );

    test_pattern #(
        .H_ACTIVE(H_ACTIVE), .V_ACTIVE(V_ACTIVE), .XW(XW), .YW(YW),
        .BOX(BOX), .STEP(STEP)
    ) pattern (
        .clk(clk), .rst(rst),
        .hsync(t_hsync), .vsync(t_vsync), .de(t_de),
        .x(t_x), .y(t_y), .frame_start(t_frame_start),
        .out_hsync(hsync), .out_vsync(vsync), .out_de(de),
        .out_frame_start(frame_start),
        .r(r), .g(g), .b(b)
    );

endmodule
