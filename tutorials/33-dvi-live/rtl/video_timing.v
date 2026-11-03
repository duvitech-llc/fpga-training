// Video timing generator. The defaults are VGA 640x480 at 60 Hz:
// 800 clocks per line and 525 lines per frame, both syncs active low.
//
// Each line is H_ACTIVE visible pixels, then the front porch, the sync pulse
// and the back porch. Each frame is the same in lines, using V_*.
//
// Two stages of registers. Stage 1 is the pair of counters h and v. Stage 2
// decodes them, so every output comes straight from a flip-flop and all of them
// describe the same position: x and y are h and v one clock later.
module video_timing #(
    parameter integer H_ACTIVE = 640,
    parameter integer H_FRONT  = 16,
    parameter integer H_SYNC   = 96,
    parameter integer H_BACK   = 48,
    parameter integer V_ACTIVE = 480,
    parameter integer V_FRONT  = 10,
    parameter integer V_SYNC   = 2,
    parameter integer V_BACK   = 33,
    parameter [0:0]   H_POL    = 1'b0,   // level of hsync during the pulse
    parameter [0:0]   V_POL    = 1'b0,   // level of vsync during the pulse
    // Widths of x and y. Leave these at their defaults.
    parameter integer XW = $clog2(H_ACTIVE + H_FRONT + H_SYNC + H_BACK),
    parameter integer YW = $clog2(V_ACTIVE + V_FRONT + V_SYNC + V_BACK)
) (
    input  wire          clk,          // the pixel clock
    input  wire          rst,          // synchronous, active high
    output reg           hsync,
    output reg           vsync,
    output reg           de,           // display enable: x and y are a visible pixel
    output reg  [XW-1:0] x,            // counts 0 to H_TOTAL-1 along each line
    output reg  [YW-1:0] y,            // counts 0 to V_TOTAL-1 down each frame
    output reg           frame_start   // high with de for pixel (0, 0) only
);

    localparam integer H_TOTAL = H_ACTIVE + H_FRONT + H_SYNC + H_BACK;
    localparam integer V_TOTAL = V_ACTIVE + V_FRONT + V_SYNC + V_BACK;
    localparam integer H_LAST  = H_TOTAL - 1;
    localparam integer V_LAST  = V_TOTAL - 1;
    localparam integer HS_FIRST = H_ACTIVE + H_FRONT;      // first clock of the pulse
    localparam integer HS_LAST  = HS_FIRST + H_SYNC - 1;   // last clock of the pulse
    localparam integer VS_FIRST = V_ACTIVE + V_FRONT;
    localparam integer VS_LAST  = VS_FIRST + V_SYNC - 1;

    // Stage 1: where the beam is.
    reg [XW-1:0] h;
    reg [YW-1:0] v;

    always @(posedge clk) begin
        if (rst) begin
            h <= 0;
            v <= 0;
        end else if (h == H_LAST[XW-1:0]) begin
            h <= 0;
            v <= (v == V_LAST[YW-1:0]) ? {YW{1'b0}} : v + 1'b1;
        end else begin
            h <= h + 1'b1;
        end
    end

    // Stage 2: what the beam should be doing there.
    always @(posedge clk) begin
        if (rst) begin
            hsync       <= !H_POL;
            vsync       <= !V_POL;
            de          <= 1'b0;
            x           <= 0;
            y           <= 0;
            frame_start <= 1'b0;
        end else begin
            hsync       <= (h >= HS_FIRST[XW-1:0] && h <= HS_LAST[XW-1:0]) ? H_POL : !H_POL;
            vsync       <= (v >= VS_FIRST[YW-1:0] && v <= VS_LAST[YW-1:0]) ? V_POL : !V_POL;
            de          <= (h < H_ACTIVE[XW-1:0]) && (v < V_ACTIVE[YW-1:0]);
            x           <= h;
            y           <= v;
            frame_start <= (h == 0) && (v == 0);
        end
    end

`ifdef FORMAL
    reg past_valid = 1'b0;
    always @(posedge clk)
        past_valid <= 1'b1;

    always @(*)
        if (!past_valid)
            assume (rst);

    // running is low on the clock after a reset, when stage 2 holds its reset
    // values instead of a decoded position.
    reg running = 1'b0;
    always @(posedge clk)
        running <= !rst;

    wire hs_on = (hsync == H_POL);
    wire vs_on = (vsync == V_POL);

    // Counters that only the proof uses. hs_run and vs_run count how many
    // clocks in a row the sync was on, up to the clock before this one.
    reg [31:0] hs_run   = 0;
    reg [31:0] vs_run   = 0;
    reg        was_rst  = 1'b0;
    reg        seen_fs  = 1'b0;   // a frame_start since the last reset
    reg [31:0] since_fs = 0;      // clocks since that frame_start

    always @(posedge clk) begin
        hs_run   <= hs_on ? hs_run + 1 : 0;
        vs_run   <= vs_on ? vs_run + 1 : 0;
        was_rst  <= rst;
        seen_fs  <= !rst && (seen_fs || frame_start);
        since_fs <= frame_start ? 1 : since_fs + 1;
    end

    // On the first step nothing has been clocked, so nothing is checked.
    always @(*) if (past_valid) begin
        // The counters stay in range.
        assert (h < H_TOTAL);
        assert (v < V_TOTAL);
        assert (x < H_TOTAL);
        assert (y < V_TOTAL);

        // de only in the active area, and frame_start only at its first pixel.
        if (de)
            assert (x < H_ACTIVE && y < V_ACTIVE);
        if (frame_start)
            assert (de && x == 0 && y == 0);

        // The pulses are never longer than they should be...
        if (hs_on)
            assert (hs_run < H_SYNC);
        if (vs_on)
            assert (vs_run < V_SYNC * H_TOTAL);

        // ...nor shorter, unless a reset cut them off.
        if (!hs_on && hs_run != 0 && !was_rst)
            assert (hs_run == H_SYNC);
        if (!vs_on && vs_run != 0 && !was_rst)
            assert (vs_run == V_SYNC * H_TOTAL);

        // frame_start comes once per frame, exactly H_TOTAL * V_TOTAL clocks apart.
        if (frame_start && seen_fs)
            assert (since_fs == H_TOTAL * V_TOTAL);

        if (!running) begin
            // Just after a reset: everything idle, the counters at the start.
            assert (h == 0 && v == 0);
            assert (!de && !hs_on && !vs_on && !frame_start);
            assert (!seen_fs);
        end else begin
            // Each output matches the position, with the porches written out
            // from the parameters rather than taken from the localparams above.
            assert (de == (x < H_ACTIVE && y < V_ACTIVE));
            assert (hs_on == (x >= H_ACTIVE + H_FRONT && x < H_ACTIVE + H_FRONT + H_SYNC));
            assert (vs_on == (y >= V_ACTIVE + V_FRONT && y < V_ACTIVE + V_FRONT + V_SYNC));
            assert (frame_start == (x == 0 && y == 0));

            // Stage 1 is one position ahead of stage 2.
            if (x == H_TOTAL - 1)
                assert (h == 0 && v == ((y == V_TOTAL - 1) ? 0 : y + 1));
            else
                assert (h == x + 1 && v == y);

            // Helpers that tie the proof's counters to the position.
            if (hs_on)
                assert (hs_run == x - (H_ACTIVE + H_FRONT));
            if (vs_on)
                assert (vs_run == (y - (V_ACTIVE + V_FRONT)) * H_TOTAL + x);
            if (seen_fs)
                assert (since_fs == (frame_start ? H_TOTAL * V_TOTAL : y * H_TOTAL + x));
            else
                assert (x == 0 && y == 0);
        end
    end

    // Each of these must be reachable, or the proof above could be vacuous.
    always @(*) if (past_valid) begin
        cover (frame_start && seen_fs);                       // a second frame
        cover (hs_on && vs_on);                               // both pulses at once
        cover (de && x == H_ACTIVE - 1 && y == V_ACTIVE - 1); // the last pixel
        cover (!hs_on && hs_run == H_SYNC);                   // the end of a pulse
    end
`endif

endmodule
