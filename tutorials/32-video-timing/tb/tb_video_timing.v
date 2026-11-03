`timescale 1ns/1ps

// Measures every interval of the timing in clocks and compares it with the
// parameters. The measuring knows nothing of the counters inside the design:
// it only watches the outputs change, as a monitor would.
module tb_video_timing;

    parameter integer H_ACTIVE = 640;
    parameter integer H_FRONT  = 16;
    parameter integer H_SYNC   = 96;
    parameter integer H_BACK   = 48;
    parameter integer V_ACTIVE = 480;
    parameter integer V_FRONT  = 10;
    parameter integer V_SYNC   = 2;
    parameter integer V_BACK   = 33;
    parameter [0:0]   H_POL    = 1'b0;
    parameter [0:0]   V_POL    = 1'b0;
    parameter integer FRAMES   = 2;      // frames to run before, and after, a reset

    localparam integer H_TOTAL = H_ACTIVE + H_FRONT + H_SYNC + H_BACK;
    localparam integer V_TOTAL = V_ACTIVE + V_FRONT + V_SYNC + V_BACK;
    localparam integer FRAME   = H_TOTAL * V_TOTAL;
    localparam integer XW      = $clog2(H_TOTAL);
    localparam integer YW      = $clog2(V_TOTAL);

    reg           clk = 1'b0;
    reg           rst = 1'b1;
    wire          hsync, vsync, de, frame_start;
    wire [XW-1:0] x;
    wire [YW-1:0] y;

    wire          p_hsync, p_vsync, p_de, p_frame_start;
    wire [7:0]    r, g, b;

    video_timing #(
        .H_ACTIVE(H_ACTIVE), .H_FRONT(H_FRONT), .H_SYNC(H_SYNC), .H_BACK(H_BACK),
        .V_ACTIVE(V_ACTIVE), .V_FRONT(V_FRONT), .V_SYNC(V_SYNC), .V_BACK(V_BACK),
        .H_POL(H_POL), .V_POL(V_POL)
    ) dut (
        .clk(clk), .rst(rst), .hsync(hsync), .vsync(vsync), .de(de),
        .x(x), .y(y), .frame_start(frame_start)
    );

    // The pattern is here only to check that its outputs stay in line.
    test_pattern #(
        .H_ACTIVE(H_ACTIVE), .V_ACTIVE(V_ACTIVE), .XW(XW), .YW(YW),
        .BOX(V_ACTIVE / 8), .STEP(3)
    ) pattern (
        .clk(clk), .rst(rst), .hsync(hsync), .vsync(vsync), .de(de),
        .x(x), .y(y), .frame_start(frame_start),
        .out_hsync(p_hsync), .out_vsync(p_vsync), .out_de(p_de),
        .out_frame_start(p_frame_start), .r(r), .g(g), .b(b)
    );

    // 40 ns is a 25 MHz pixel clock.
    always #20 clk = ~clk;

    integer errors = 0;

    task fail(input [8*40-1:0] what, input integer got, input integer expected);
        begin
            $display("FAIL t=%0t %0s: got %0d, expected %0d", $time, what, got, expected);
            errors = errors + 1;
        end
    endtask

    task fail_bit(input [8*40-1:0] what, input got, input expected);
        begin
            $display("FAIL t=%0t %0s: got %b, expected %b", $time, what, got, expected);
            errors = errors + 1;
        end
    endtask

    // Full-width copies, so they compare with integers without a width warning.
    wire [31:0] xi  = {{(32 - XW){1'b0}}, x};
    wire [31:0] yi  = {{(32 - YW){1'b0}}, y};
    wire [31:0] rgb = {8'h00, r, g, b};

    // Times are in clocks since reset. -1 means not seen since reset.
    integer now;
    integer hs_rise, hs_fall, de_rise, de_fall, vs_rise, vs_fall;
    integer lines_in_frame, fs_in_frame;
    reg     hs_was, vs_was, de_was, fs_was, first;
    reg     hsync_was, vsync_was, idle_hsync, idle_vsync;

    // The last value measured for each interval, and how many were measured.
    integer m_line, m_hact, m_hfront, m_hsync, m_hback;
    integer m_frame, m_vact, m_vfront, m_vsync, m_vback;
    integer n_line, n_hfront, n_hback, n_frame, n_vfront, n_vback, n_vact, n_fs;

    wire hs_on = (hsync === H_POL);
    wire vs_on = (vsync === V_POL);

    initial begin
        n_line = 0; n_hfront = 0; n_hback = 0;
        n_frame = 0; n_vfront = 0; n_vback = 0; n_vact = 0; n_fs = 0;

    end

    // rst as the last rising edge saw it, which is what made the outputs.
    reg rst_seen = 1'b1;
    always @(posedge clk)
        rst_seen <= rst;

    // Outputs change just after a rising edge, so sample on the falling edge.
    always @(negedge clk) begin
        if (rst_seen) begin
            now = 0;
            hs_rise = -1; hs_fall = -1; de_rise = -1; de_fall = -1;
            vs_rise = -1; vs_fall = -1;
            lines_in_frame = 0; fs_in_frame = 0;
            hs_was = 1'b0; vs_was = 1'b0; de_was = 1'b0; fs_was = 1'b0;
            if (de !== 1'b0 || frame_start !== 1'b0 || hs_on || vs_on)
                fail("outputs not idle in reset", 0, 0);
        end else begin
            now = now + 1;
            first = 1'b0;

            // The first clock after a reset is pixel (0, 0).
            if (now == 1 && frame_start !== 1'b1)
                fail_bit("frame_start on first clock", frame_start, 1'b1);

            // ---- Horizontal ----
            if (hs_on && !hs_was) begin
                if (hs_rise >= 0) begin
                    m_line = now - hs_rise;
                    n_line = n_line + 1;
                    if (m_line != H_TOTAL) fail("clocks per line", m_line, H_TOTAL);
                end
                if (de_fall > hs_rise && de_fall >= 0) begin
                    m_hfront = now - de_fall;
                    n_hfront = n_hfront + 1;
                    if (m_hfront != H_FRONT) fail("front porch", m_hfront, H_FRONT);
                end
                hs_rise = now;
            end
            if (!hs_on && hs_was) begin
                m_hsync = now - hs_rise;
                if (m_hsync != H_SYNC) fail("hsync width", m_hsync, H_SYNC);
                hs_fall = now;
            end
            if (de && !de_was) begin
                if (hs_fall >= 0) begin
                    m_hback = now - hs_fall;
                    n_hback = n_hback + 1;
                    if (m_hback != H_BACK) fail("back porch", m_hback, H_BACK);
                end
                // The first active line after vsync ends is the back porch away.
                if (lines_in_frame == 0 && vs_fall >= 0) begin
                    m_vback = now - vs_fall;
                    n_vback = n_vback + 1;
                    if (m_vback != V_BACK * H_TOTAL)
                        fail("vertical back porch, clocks", m_vback, V_BACK * H_TOTAL);
                end
                // The first line since vsync, or since reset, starts a frame.
                first = (lines_in_frame == 0);
                de_rise = now;
                lines_in_frame = lines_in_frame + 1;
            end
            if (!de && de_was) begin
                m_hact = now - de_rise;
                if (m_hact != H_ACTIVE) fail("active pixels per line", m_hact, H_ACTIVE);
                de_fall = now;
            end

            // ---- Vertical ----
            if (vs_on && !vs_was) begin
                if (vs_rise >= 0) begin
                    m_frame = now - vs_rise;
                    n_frame = n_frame + 1;
                    if (m_frame != FRAME) fail("clocks per frame", m_frame, FRAME);
                    m_vact = lines_in_frame;
                    n_vact = n_vact + 1;
                    if (m_vact != V_ACTIVE) fail("active lines per frame", m_vact, V_ACTIVE);
                    if (fs_in_frame != 1) fail("frame_starts per frame", fs_in_frame, 1);
                end
                if (de_fall >= 0) begin
                    m_vfront = now - de_fall;
                    n_vfront = n_vfront + 1;
                    if (m_vfront != (H_TOTAL - H_ACTIVE) + V_FRONT * H_TOTAL)
                        fail("vertical front porch, clocks", m_vfront,
                             (H_TOTAL - H_ACTIVE) + V_FRONT * H_TOTAL);
                end
                vs_rise = now;
                lines_in_frame = 0;
                fs_in_frame = 0;
            end
            if (!vs_on && vs_was) begin
                m_vsync = now - vs_rise;
                if (m_vsync != V_SYNC * H_TOTAL)
                    fail("vsync width, clocks", m_vsync, V_SYNC * H_TOTAL);
                vs_fall = now;
            end

            // ---- Polarity: the level while the picture is drawn is the idle one ----
            if (de) begin
                idle_hsync = hsync;
                idle_vsync = vsync;
                if (hsync !== !H_POL) fail_bit("hsync level during de", hsync, !H_POL);
                if (vsync !== !V_POL) fail_bit("vsync level during de", vsync, !V_POL);
            end

            // ---- x, y and frame_start ----
            if (frame_start === 1'b1) begin
                fs_in_frame = fs_in_frame + 1;
                n_fs = n_fs + 1;
            end
            if (frame_start !== first) fail_bit("frame_start on the first pixel", frame_start, first);
            if (de) begin
                if (xi !== now - de_rise) fail("x", xi, now - de_rise);
                if (yi !== lines_in_frame - 1) fail("y", yi, lines_in_frame - 1);
            end
            if (xi >= H_TOTAL) fail("x in range", xi, H_TOTAL - 1);
            if (yi >= V_TOTAL) fail("y in range", yi, V_TOTAL - 1);

            // ---- The pattern's outputs are its inputs one clock later ----
            if (now > 1) begin
                if (p_de !== de_was) fail_bit("pattern de delay", p_de, de_was);
                if (p_frame_start !== fs_was) fail_bit("pattern frame_start delay", p_frame_start, fs_was);
                if (p_hsync !== hsync_was) fail_bit("pattern hsync delay", p_hsync, hsync_was);
                if (p_vsync !== vsync_was) fail_bit("pattern vsync delay", p_vsync, vsync_was);
                if (!p_de && rgb !== 0) fail("colour in blanking", rgb, 0);
            end

            hs_was = hs_on;
            vs_was = vs_on;
            de_was = de;
            fs_was = frame_start;
            hsync_was = hsync;
            vsync_was = vsync;
        end
    end

    initial begin
        // A whole VGA run would make a VCD of hundreds of megabytes, so only a
        // small mode writes one.
        if (FRAME < 100000) begin
            $dumpfile("build/tb_video_timing.vcd");
            $dumpvars(0, tb_video_timing);
        end

        repeat (3) @(negedge clk);
        rst = 1'b0;

        // Run, then reset in the middle of a line part-way down a frame, and run again.
        repeat (FRAMES * FRAME + FRAME / 3 + H_TOTAL / 2) @(negedge clk);
        rst = 1'b1;
        repeat (4) @(negedge clk);
        rst = 1'b0;
        repeat (FRAMES * FRAME + FRAME / 3) @(negedge clk);

        $display("mode %0dx%0d, %0dx%0d clocks", H_ACTIVE, V_ACTIVE, H_TOTAL, V_TOTAL);
        $display("line:  %0d clocks = %0d active + %0d front + %0d sync + %0d back (%0d lines measured)",
                 m_line, m_hact, m_hfront, m_hsync, m_hback, n_line);
        $display("frame: %0d lines = %0d active + %0d front + %0d sync + %0d back (%0d frames measured)",
                 m_frame / H_TOTAL, m_vact, (m_vfront - (H_TOTAL - H_ACTIVE)) / H_TOTAL,
                 m_vsync / H_TOTAL, m_vback / H_TOTAL, n_frame);
        $display("hsync pulses %0s, vsync pulses %0s",
                 idle_hsync ? "low" : "high", idle_vsync ? "low" : "high");
        $display("frame period %0d clocks = %0d ns at a 40 ns clock", m_frame, m_frame * 40);

        // A check that never ran proves nothing.
        if (n_line == 0 || n_hfront == 0 || n_hback == 0 || n_frame < 2 || n_vfront == 0
                || n_vback == 0 || n_vact < 2 || n_fs < 2 * FRAMES)
            fail("too few measurements", n_frame, 2);

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
