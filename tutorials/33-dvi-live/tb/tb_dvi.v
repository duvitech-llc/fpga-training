`timescale 1ps/1ps

// The whole system, booted from the SPI flash model, running programs/draw.c.
// The testbench sees the picture only as a receiver would: from the four TMDS
// wires. It recovers the 10-bit characters, finds where each one starts from
// the control tokens, decodes them back to pixels and sync, and builds whole
// frames. Then:
//
//   - every decoded pixel is compared with the framebuffer, at the address the
//     display took for that frame, or with black if the frame was not shown;
//   - each frame is written to a PNG file, with a PNG writer written here in
//     Verilog: <out>/frame_NN.png for the first few, and the live view, one
//     file written again every frame;
//   - the vertical blank interrupt is checked: exactly one handler run, seen
//     on gpio_out, for each vertical blank;
//   - the clock wire must carry 0000011111 in step with the data;
//   - and it measures: the FIFO's lowest level when a word was due, the
//     running disparity of each channel, transitions in data characters and in
//     tokens, and the frame period.
//
// tb/check_frames.py then compares the PNG files with tools/scene.py, a Python
// model of what the program draws.
//
// Clocks: clk is 100 MHz. pclk and clk_x10 come from one source, as from a
// PLL: clk_x10 rises every bit, pclk every ten bits, half a bit before a
// clk_x10 edge. See tmds_serialiser.v. The pixel period is the plusarg
// +pix_ps, 39000 ps by default, and must be a multiple of 20 ps. 39 ns is not
// a multiple of clk's 10 ns, so the two clocks drift past each other.
//
// Plusargs: +mode=0 no stalls, 1 every slave stalls at random about one clock
// in four, 2 the framebuffer stalls for HOLD_CLOCKS clocks in the middle of the
// third frame shown, to cause an underrun on purpose. +frames=N decoded frames
// to run. +out=DIR for the numbered PNG files, +keep=N how many, +live=FILE for
// the live view. +waves records a waveform, in two short windows.
//
// Inputs change on the falling edge of their clock.
module tb_dvi #(
    parameter CLKS_PER_BIT = 16
);

    // The display's mode: soc.v's defaults.
    localparam integer W       = 160;
    localparam integer H       = 120;
    localparam integer H_TOTAL = 160 + 8 + 16 + 16;
    localparam integer V_TOTAL = 120 + 2 + 3 + 5;
    localparam integer FIFO_AW = 4;
    localparam [31:0]  FB_BASE = 32'h0100_0000;
    localparam integer SCALE   = 2;            // each pixel is 2x2 in the PNG files
    localparam integer HOLD_CLOCKS = 3000;     // mode 2's stall

    reg clk = 1'b0;
    reg pclk = 1'b0;
    reg clk_x10 = 1'b0;
    reg rst = 1'b1;
    reg [16:0] hold = 17'd0;

    wire        uart_tx, trap, retire;
    wire [31:0] trap_cause, gpio_out, retire_pc, retire_instr;
    wire        sclk, mosi, cs_n, flash_miso;
    wire [2:0]  tmds_data;
    wire        tmds_clk;

    soc #(.CLKS_PER_BIT(CLKS_PER_BIT), .ROM_INIT("build/boot.hex")) dut (
        .clk(clk), .rst(rst), .uart_rx(1'b1), .uart_tx(uart_tx), .gpio_out(gpio_out),
        .spi_sclk(sclk), .spi_mosi(mosi), .spi_miso(flash_miso), .spi_cs_n(cs_n),
        .trap(trap), .trap_cause(trap_cause),
        .retire(retire), .retire_pc(retire_pc), .retire_instr(retire_instr),
        .hold(hold),
        .pclk(pclk), .clk_x10(clk_x10), .tmds_data(tmds_data), .tmds_clk(tmds_clk)
    );

    // Tutorial 24's flash model, unchanged, with 64 KiB.
    spi_flash_model #(
        .MEM_FILE("build/flash_draw.hex"), .MEM_BYTES(65536)
    ) u_flash (
        .cs_n(cs_n), .sclk(sclk), .mosi(mosi), .miso(flash_miso)
    );

    pullup (flash_miso);

    // ----- Clocks -----

    integer pix_ps = 39000;
    integer bit_ps;

    always #5000 clk = ~clk;

    initial begin
        if (!$value$plusargs("pix_ps=%d", pix_ps))
            pix_ps = 39000;
        bit_ps = pix_ps / 10;
        fork
            forever #(bit_ps / 2) clk_x10 = ~clk_x10;
            begin
                #(pix_ps / 2);
                forever begin
                    pclk = 1'b1;
                    #(pix_ps / 2);
                    pclk = 1'b0;
                    #(pix_ps / 2);
                end
            end
        join
    end

    // ----- Errors -----

    integer errors = 0;

    task fail(input string why);
        begin
            if (errors < 30)
                $display("FAIL t=%0t ps %0s", $time, why);
            errors = errors + 1;
        end
    endtask

    // ----- Stalls -----

    integer    mode = 0;
    reg [31:0] random = 32'h2545F491;   // xorshift32, the same in both simulators
    reg [31:0] random2;
    integer    hold_left = 0;            // mode 2: clocks of the framebuffer's stall to go
    integer    hold_frame = -1;          // the decoded frame it fell in

    function [31:0] next_random(input [31:0] r);
        reg [31:0] s;
        begin
            s = r ^ (r << 13);
            s = s ^ (s >> 17);
            next_random = s ^ (s << 5);
        end
    endfunction

    always @(negedge clk) begin
        random  = next_random(random);
        random2 = next_random(random);
        random  = random2;
        if (mode == 1)
            hold <= random[16:0] & random[31:15];
        else if (hold_left > 0) begin
            hold <= 17'd1 << 15;
            hold_left = hold_left - 1;
        end else
            hold <= 17'd0;
    end

    // ----- What each frame should show, recorded on the pixel side -----

    // Frame k of the pixel side starts at its k-th frame_start, counting from 0.
    // The decoder counts frames by vsync, and the first vsync comes in frame
    // 0's blanking, so decoded frame k is the pixel side's frame k too.
    localparam integer MAX_FRAMES = 4096;
    reg     exp_show [0:MAX_FRAMES-1];
    reg [31:0] exp_base [0:MAX_FRAMES-1];
    integer pframe = -1;
    integer first_shown = -1;

    always @(posedge pclk) begin
        if (!rst && dut.u_display.u_pixel.frame_start === 1'b1) begin
            pframe = pframe + 1;
            if (pframe < MAX_FRAMES) begin
                exp_show[pframe] = dut.u_display.u_pixel.show_next;
                exp_base[pframe] = {dut.u_display.u_bus.current, 2'b00};
            end
            if (first_shown < 0 && dut.u_display.u_pixel.show_next)
                first_shown = pframe;
            // Mode 2: stall the framebuffer in the middle of the third frame shown.
        end
        if (mode == 2 && first_shown >= 0 && pframe == first_shown + 2 && hold_frame < 0
            && dut.u_display.u_pixel.y == 60 && dut.u_display.u_pixel.x == 0) begin
            hold_left = HOLD_CLOCKS;
            hold_frame = pframe;
        end
    end

    // ----- The FIFO's level when a word is due -----

    // The true level, from both binary pointers, and rd_used, the level the
    // pixel side can see. Words are due only in shown frames. The FIFO always
    // runs down at the end of a frame, when the reader has nothing left to
    // fetch, so the lowest level is taken only while more words of the frame
    // are owed than the FIFO can hold: then the reader still has work to do.
    integer lowest = 1 << 30, lowest_seen = 1 << 30, dues = 0, underruns = 0;
    wire [FIFO_AW:0] fifo_level = dut.u_display.u_fifo.wr_ptr.bin
                                - dut.u_display.u_fifo.rd_ptr.bin;

    always @(posedge pclk) begin
        if (!rst && dut.u_display.u_pixel.due === 1'b1) begin
            dues = dues + 1;
            if (dut.u_display.u_pixel.owed > (1 << FIFO_AW)) begin
                if ({27'd0, fifo_level} < lowest)
                    lowest = {27'd0, fifo_level};
                if ({27'd0, dut.u_display.u_fifo.rd_used} < lowest_seen)
                    lowest_seen = {27'd0, dut.u_display.u_fifo.rd_used};
            end
            if (dut.u_display.u_pixel.fifo_empty)
                underruns = underruns + 1;
        end
    end

    // ----- The reader on the bus -----

    // Clocks from the reader raising cyc to its first request being taken:
    // the wait for the arbiter, and for a stalled slave. And bursts begun.
    integer bursts = 0, wait_now = -1, wait_max = 0, wait_sum = 0;

    always @(negedge clk) begin
        if (!rst) begin
            if (dut.dsp_cyc && wait_now == -1) begin
                bursts = bursts + 1;
                wait_now = 0;
            end
            if (wait_now >= 0) begin
                if (dut.dsp_stb && !dut.dsp_stall) begin
                    if (wait_now > wait_max)
                        wait_max = wait_now;
                    wait_sum = wait_sum + wait_now;
                    wait_now = -2;           // taken: wait for cyc to fall
                end else if (wait_now >= 0) begin
                    wait_now = wait_now + 1;
                end
            end
            if (!dut.dsp_cyc && wait_now == -2)
                wait_now = -1;
        end
    end

    // ----- The vertical blank interrupt -----

    // Every rise of the synchronised vblank must be followed by exactly one
    // run of the handler, which writes its count to gpio_out.
    integer   edges_since = 0, handler_runs = 0, vblank_edges = 0;
    reg       vblank_q = 1'b0;
    reg [31:0] gpio_q = 32'd0;

    always @(negedge clk) begin
        if (!rst) begin
            if (dut.vblank && !vblank_q) begin
                vblank_edges = vblank_edges + 1;
                edges_since = edges_since + 1;
                if (handler_runs > 0 && edges_since >= 2)
                    fail("two vertical blanks without a vblank interrupt");
            end
            if (gpio_out !== gpio_q) begin
                if (gpio_out !== gpio_q + 32'd1)
                    fail($sformatf("gpio_out went from %0d to %0d", gpio_q, gpio_out));
                if (handler_runs > 0 && edges_since != 1)
                    fail($sformatf("the vblank handler ran after %0d vertical blanks, not 1",
                                   edges_since));
                handler_runs = handler_runs + 1;
                edges_since = 0;
            end
        end
        vblank_q = !rst && dut.vblank;
        gpio_q   = gpio_out;
    end

    // ----- Traps: the program never ends, so any EBREAK or exception is an error -----

    always @(negedge clk) begin
        if (!rst && trap === 1'b1 && trap_cause[31] !== 1'b1)
            fail($sformatf("exception, mcause %0d, at %h, a0 %0d", trap_cause, retire_pc,
                           dut.u_core.u_regs.q[10]));
    end

    // ----- The receiver: bits back to characters -----

    // The wires change on the rising edge of clk_x10, so each is sampled on the
    // falling edge, in the middle of the bit. sr[ch] is the last ten bits,
    // the oldest in bit 0, since DVI sends bit 0 first.
    function is_token(input [9:0] w);
        is_token = w == 10'b1101010100 || w == 10'b0010101011
                || w == 10'b0101010100 || w == 10'b1010101011;
    endfunction

    function [1:0] token(input [9:0] w);
        token = (w == 10'b1101010100) ? 2'b00 : (w == 10'b0010101011) ? 2'b01 :
                (w == 10'b0101010100) ? 2'b10 : 2'b11;
    endfunction

    // The DVI 1.0 decoder: undo the inversion, then the XOR or XNOR.
    function [7:0] decode(input [9:0] w);
        reg [7:0] v;
        integer k;
        begin
            v = w[9] ? ~w[7:0] : w[7:0];
            decode[0] = v[0];
            for (k = 1; k < 8; k = k + 1)
                decode[k] = w[8] ? (v[k] ^ v[k-1]) : !(v[k] ^ v[k-1]);
        end
    endfunction

    function integer ones10(input [9:0] w);
        integer k;
        begin
            ones10 = 0;
            for (k = 0; k < 10; k = k + 1)
                ones10 = ones10 + w[k];
        end
    endfunction

    function integer changes10(input [9:0] w);
        integer k;
        begin
            changes10 = 0;
            for (k = 1; k < 10; k = k + 1)
                changes10 = changes10 + (w[k] != w[k-1]);
        end
    endfunction

    reg  [9:0] sr [0:3];             // channels 0 to 2, then the clock wire
    integer    last_token [0:2];
    integer    run [0:2];
    integer    phase [0:2];
    reg        locked [0:2];
    integer    bits = 0;             // falling edges of clk_x10 since reset
    integer    ch;

    initial
        for (ch = 0; ch < 3; ch = ch + 1) begin
            last_token[ch] = -100;
            run[ch] = 0;
            phase[ch] = -1;
            locked[ch] = 1'b0;
        end

    // A character from each channel, once all three are in step.
    reg  [9:0] c0, c1, c2;
    reg        got = 1'b0;

    always @(negedge clk_x10) begin
        if (!rst) begin
            sr[0] = {tmds_data[0], sr[0][9:1]};
            sr[1] = {tmds_data[1], sr[1][9:1]};
            sr[2] = {tmds_data[2], sr[2][9:1]};
            sr[3] = {tmds_clk,     sr[3][9:1]};
            bits = bits + 1;
            got = 1'b0;
            // Word alignment: eight control tokens in a row, ten bits apart.
            for (ch = 0; ch < 3; ch = ch + 1) begin
                if (!locked[ch] && is_token(sr[ch])) begin
                    run[ch] = (bits - last_token[ch] == 10) ? run[ch] + 1 : 1;
                    last_token[ch] = bits;
                    if (run[ch] == 8) begin
                        locked[ch] = 1'b1;
                        phase[ch] = bits % 10;
                    end
                end
            end
            if (locked[0] && locked[1] && locked[2] && bits % 10 == phase[0]) begin
                if (phase[1] != phase[0] || phase[2] != phase[0])
                    fail($sformatf("channels locked at different bits: %0d %0d %0d",
                                   phase[0], phase[1], phase[2]));
                if (sr[3] !== 10'b0000011111)
                    fail($sformatf("clock wire carried %b, not 0000011111", sr[3]));
                c0 = sr[0];
                c1 = sr[1];
                c2 = sr[2];
                got = 1'b1;
                character(c0, c1, c2);
            end
        end
    end

    // ----- Characters back to frames -----

    reg  [23:0] img [0:W*H-1];       // the frame being decoded
    integer     row = 0, col = 0;
    reg         in_data = 1'b0;
    reg         vs_q = 1'b0;
    integer     dframe = 0;          // decoded frames begun, counted by vsync
    reg         open = 1'b0;         // a whole frame is being decoded
    integer     mismatches = 0, frame_mismatches = 0;
    integer     frames_done = 0, frames_shown = 0;
    integer     bad_frames = 0;      // frames with any wrong pixel
    time        vs_time = 0, period = 0;
    integer     hs_count = 0;        // hsync pulses in this frame

    // Disparity. run_disp: 1s minus 0s since the last token, at the end of
    // each character, which the encoder's cnt should equal. wire_disp: since
    // lock, tokens included.
    integer     run_disp [0:2];
    integer     run_min [0:2], run_max [0:2];
    integer     wire_disp [0:2], wire_at_frame [0:2], drift [0:2];
    integer     data_changes_max = 0, token_changes_min = 99;
    integer     k;
    reg  [7:0]  db [0:2];
    reg         hs_q = 1'b0;

    initial
        for (k = 0; k < 3; k = k + 1) begin
            run_disp[k] = 0;
            run_min[k] = 0;
            run_max[k] = 0;
            wire_disp[k] = 0;
            wire_at_frame[k] = 0;
            drift[k] = 0;
        end

    // The pixel the framebuffer holds, as the display expands it.
    function [23:0] expected(input integer f, input integer x, input integer y);
        reg [31:0] word;
        reg [7:0]  p;
        integer    a;
        begin
            if (f >= MAX_FRAMES || !exp_show[f]) begin
                expected = 24'd0;
            end else begin
                a = exp_base[f] - FB_BASE + y * W + x;
                word = dut.u_fb.mem[a / 4];
                p = word[8 * (a % 4) +: 8];
                expected = {p[7:5], p[7:5], p[7:6], p[4:2], p[4:2], p[4:3], {4{p[1:0]}}};
            end
        end
    endfunction

    task character(input [9:0] w0, input [9:0] w1, input [9:0] w2);
        reg [9:0] w [0:2];
        reg       tok0, tok1, tok2;
        reg [1:0] ctl;
        reg [23:0] px, want;
        begin
            w[0] = w0;
            w[1] = w1;
            w[2] = w2;
            tok0 = is_token(w0);
            tok1 = is_token(w1);
            tok2 = is_token(w2);
            for (k = 0; k < 3; k = k + 1) begin
                wire_disp[k] = wire_disp[k] + 2 * ones10(w[k]) - 10;
                if (is_token(w[k])) begin
                    run_disp[k] = 0;
                    if (changes10(w[k]) < token_changes_min)
                        token_changes_min = changes10(w[k]);
                end else begin
                    run_disp[k] = run_disp[k] + 2 * ones10(w[k]) - 10;
                    if (run_disp[k] < run_min[k]) run_min[k] = run_disp[k];
                    if (run_disp[k] > run_max[k]) run_max[k] = run_disp[k];
                    if (changes10(w[k]) > data_changes_max)
                        data_changes_max = changes10(w[k]);
                end
            end

            if (tok0 && tok1 && tok2) begin
                // Blanking. Channel 0 carries hsync in C0 and vsync in C1.
                ctl = token(w0);
                if (token(w1) != 2'b00 || token(w2) != 2'b00)
                    fail("a control token other than 00 on channel 1 or 2");
                if (in_data) begin
                    if (open && col != W)
                        fail($sformatf("frame %0d row %0d had %0d pixels", dframe, row, col));
                    row = row + 1;
                    col = 0;
                    in_data = 1'b0;
                end
                if (ctl[0] && !hs_q)
                    hs_count = hs_count + 1;
                hs_q = ctl[0];
                if (ctl[1] && !vs_q)
                    vsync_rose;
                vs_q = ctl[1];
            end else if (!tok0 && !tok1 && !tok2) begin
                db[0] = decode(w0);
                db[1] = decode(w1);
                db[2] = decode(w2);
                px = {db[2], db[1], db[0]};
                if (open) begin
                    if (row >= H || col >= W) begin
                        fail($sformatf("pixel outside the frame at row %0d col %0d", row, col));
                    end else begin
                        img[row * W + col] = px;
                        want = expected(dframe, col, row);
                        if (px !== want) begin
                            frame_mismatches = frame_mismatches + 1;
                            if (mode != 2 && mismatches < 10)
                                $display("FAIL frame %0d pixel (%0d, %0d) is %h, the framebuffer says %h",
                                         dframe, col, row, px, want);
                            mismatches = mismatches + 1;
                        end
                    end
                end
                col = col + 1;
                in_data = 1'b1;
            end else begin
                fail("data on some channels and a control token on others");
            end
        end
    endtask

    // ----- A frame is complete -----

    string out_dir = "build/run";
    string live = "";
    integer keep = 8;
    integer frames_wanted = 8;
    time    first_vs = 0;

    task vsync_rose;
        begin
            if (open) begin
                if (row != H)
                    fail($sformatf("frame %0d had %0d rows", dframe, row));
                if (hs_count != V_TOTAL)
                    fail($sformatf("frame %0d had %0d hsync pulses, not %0d", dframe, hs_count,
                                   V_TOTAL));
                period = $time - vs_time;
                for (k = 0; k < 3; k = k + 1) begin
                    drift[k] = wire_disp[k] - wire_at_frame[k];
                end
                frames_done = frames_done + 1;
                if (exp_show[dframe])
                    frames_shown = frames_shown + 1;
                if (frame_mismatches != 0)
                    bad_frames = bad_frames + 1;
                if (mode == 2 && frame_mismatches != 0)
                    $display("frame %0d: %0d pixels differ from the framebuffer", dframe,
                             frame_mismatches);
                $display("frame %0d: %0s, %0d pixels checked, disparity on the wire this frame %0d %0d %0d",
                         dframe, exp_show[dframe] ? "shown" : "black", W * H,
                         drift[0], drift[1], drift[2]);
                if (dframe <= keep)
                    write_png($sformatf("%0s/frame_%02d.png", out_dir, dframe));
                if (live != "")
                    write_png(live);
            end else begin
                first_vs = $time;
            end
            dframe = dframe + 1;
            vs_time = $time;
            open = 1'b1;
            row = 0;
            col = 0;
            hs_count = 0;
            frame_mismatches = 0;
            for (k = 0; k < 3; k = k + 1)
                wire_at_frame[k] = wire_disp[k];
        end
    endtask

    // ----- PNG files, written from Verilog -----

    // A PNG file is a signature, then chunks: IHDR for the size, IDAT for the
    // pixels as a zlib stream, IEND. Each chunk ends with a CRC-32 of its type
    // and data, Tutorial 25's CRC. zlib allows "stored" blocks, which are not
    // compressed at all, so no compressor is needed here: only the CRC-32 for
    // each chunk and an Adler-32 checksum for the zlib stream.
    reg [31:0] crc_table [0:255];
    integer    png_fd;
    reg [31:0] png_crc;
    reg [31:0] adler_a, adler_b;
    integer    raw_count;
    integer    raw_len;

    initial begin : make_crc_table
        reg [31:0] c;
        integer n, b;
        for (n = 0; n < 256; n = n + 1) begin
            c = n;
            for (b = 0; b < 8; b = b + 1)
                c = c[0] ? (32'hEDB88320 ^ (c >> 1)) : (c >> 1);
            crc_table[n] = c;
        end
    end

    task png_byte(input [7:0] b);
        begin
            $fwrite(png_fd, "%c", b);
            png_crc = crc_table[(png_crc ^ {24'd0, b}) & 32'hFF] ^ (png_crc >> 8);
        end
    endtask

    task png_u32(input [31:0] v);
        begin
            png_byte(v[31:24]);
            png_byte(v[23:16]);
            png_byte(v[15:8]);
            png_byte(v[7:0]);
        end
    endtask

    // A chunk's length, which the CRC does not cover, then its type, which it does.
    task png_chunk(input [31:0] len, input [31:0] kind);
        begin
            $fwrite(png_fd, "%c%c%c%c", len[31:24], len[23:16], len[15:8], len[7:0]);
            png_crc = 32'hFFFFFFFF;
            png_u32(kind);
        end
    endtask

    task png_chunk_end;
        reg [31:0] c;
        begin
            c = ~png_crc;
            $fwrite(png_fd, "%c%c%c%c", c[31:24], c[23:16], c[15:8], c[7:0]);
        end
    endtask

    // One byte of the image data. A stored block holds at most 65535 bytes,
    // and each starts with a header: final or not, then LEN and its complement.
    task png_raw(input [7:0] b);
        integer len;
        begin
            if (raw_count % 65535 == 0) begin
                len = (raw_len - raw_count > 65535) ? 65535 : raw_len - raw_count;
                png_byte((raw_len - raw_count <= 65535) ? 8'd1 : 8'd0);
                png_byte(len[7:0]);
                png_byte(len[15:8]);
                png_byte(~len[7:0]);
                png_byte(~len[15:8]);
            end
            png_byte(b);
            adler_a = (adler_a + {24'd0, b}) % 65521;
            adler_b = (adler_b + adler_a) % 65521;
            raw_count = raw_count + 1;
        end
    endtask

    task write_png(input string name);
        integer x, y, sx, sy, blocks;
        reg [23:0] p;
        begin
            png_fd = $fopen(name, "wb");
            if (png_fd == 0) begin
                fail({"cannot write ", name});
            end else begin
                $fwrite(png_fd, "%c%c%c%c%c%c%c%c", 8'h89, "P", "N", "G", 8'h0D, 8'h0A, 8'h1A, 8'h0A);
                png_chunk(13, "IHDR");
                png_u32(W * SCALE);
                png_u32(H * SCALE);
                png_byte(8);                 // bits per sample
                png_byte(2);                 // RGB
                png_byte(0);                 // deflate
                png_byte(0);                 // filter method 0
                png_byte(0);                 // no interlace
                png_chunk_end;

                raw_len = H * SCALE * (1 + 3 * W * SCALE);
                blocks = (raw_len + 65534) / 65535;
                png_chunk(2 + 5 * blocks + raw_len + 4, "IDAT");
                png_byte(8'h78);             // zlib: deflate, 32 KiB window
                png_byte(8'h01);             // no preset dictionary; 0x7801 is a multiple of 31
                raw_count = 0;
                adler_a = 1;
                adler_b = 0;
                for (y = 0; y < H; y = y + 1)
                    for (sy = 0; sy < SCALE; sy = sy + 1) begin
                        png_raw(8'd0);       // each row starts with its filter: 0, none
                        for (x = 0; x < W; x = x + 1) begin
                            p = img[y * W + x];
                            for (sx = 0; sx < SCALE; sx = sx + 1) begin
                                png_raw(p[23:16]);
                                png_raw(p[15:8]);
                                png_raw(p[7:0]);
                            end
                        end
                    end
                png_u32({adler_b[15:0], adler_a[15:0]});
                png_chunk_end;

                png_chunk(0, "IEND");
                png_chunk_end;
                $fclose(png_fd);
            end
        end
    endtask

    // ----- The waveform -----

    // Two short windows, so the file stays small: the vertical blank before
    // the first frame shown, from the pixel side's vblank to the reader's
    // first burst, and the first lines of that frame.
    reg waves = 1'b0;
    reg window_a = 1'b0, window_b = 1'b0;
    integer window_clocks = 0;
    // The pixel side's x and y are 8 bits in this mode.
    localparam [7:0] WIN_A_Y = 8'd119, WIN_A_X = 8'd197;   // H - 1, H_TOTAL - 3
    localparam [7:0] WIN_B_Y = 8'd129, WIN_B_X = 8'd190;   // V_TOTAL - 1, H_TOTAL - 10

    always @(posedge clk) begin
        if (waves) begin
            // The end of the last visible line after the program set ENABLE.
            if (!window_a && first_shown < 0 && dut.u_display.u_bus.enable
                && dut.u_display.u_pixel.y == WIN_A_Y
                && dut.u_display.u_pixel.x >= WIN_A_X) begin
                window_a = 1'b1;
                window_clocks = 400;
                $dumpon;
            end
            // The last line of that blanking, ten pixels before the first shown frame.
            if (window_a && !window_b && dut.u_display.u_pixel.show_next
                && dut.u_display.u_pixel.y == WIN_B_Y
                && dut.u_display.u_pixel.x >= WIN_B_X) begin
                window_b = 1'b1;
                window_clocks = 1200;
                $dumpon;
            end
            if (window_clocks > 0) begin
                window_clocks = window_clocks - 1;
                if (window_clocks == 0)
                    $dumpoff;
            end
        end
    end

    // ----- The run -----

    time limit;

    initial begin
        if (!$value$plusargs("mode=%d", mode))
            mode = 0;
        if (!$value$plusargs("frames=%d", frames_wanted))
            frames_wanted = 8;
        if (!$value$plusargs("keep=%d", keep))
            keep = 8;
        if (!$value$plusargs("out=%s", out_dir))
            out_dir = "build/run";
        if (!$value$plusargs("live=%s", live))
            live = "";
        if ($test$plusargs("waves")) begin
            waves = 1'b1;
            $dumpfile("build/tb_dvi.vcd");
            $dumpvars(1, tb_dvi);
            $dumpvars(1, tb_dvi.dut.u_display.u_bus);
            $dumpvars(1, tb_dvi.dut.u_display.u_pixel);
            $dumpvars(1, tb_dvi.dut.u_display.u_fifo);
            $dumpvars(1, tb_dvi.dut.u_dvi.u_enc2);
            $dumpvars(1, tb_dvi.dut.u_intc);
            $dumpoff;
        end
        $display("mode %0d, pixel clock %0d ps, bit %0d ps, %0d frames", mode, pix_ps,
                 pix_ps / 10, frames_wanted);

        repeat (8) @(negedge clk);
        rst = 1'b0;

        // Run until enough frames are decoded, or far too long.
        limit = {32'd0, frames_wanted + 32'sd3};
        limit = limit * H_TOTAL * V_TOTAL;
        limit = limit * {32'd0, pix_ps};
        while (frames_done < frames_wanted && errors < 30 && $time < limit)
            @(negedge clk);

        if (frames_done < frames_wanted)
            fail($sformatf("only %0d frames decoded", frames_done));
        if (first_shown < 0)
            fail("no frame was shown");

        $display("--- mode %0d", mode);
        $display("frames: %0d decoded, %0d shown, the first shown was frame %0d; %0d with wrong pixels",
                 frames_done, frames_shown, first_shown, bad_frames);
        $display("frame period: %0d ps = %0d pixel clocks of %0d ps; %0d hsync pulses a frame",
                 period, period / {32'd0, pix_ps}, pix_ps, V_TOTAL);
        $display("fifo: %0d words due; lowest level when one was due, the reader not done, %0d, as the pixel side saw it %0d, of %0d; %0d found it empty",
                 dues, lowest, lowest_seen, 1 << FIFO_AW, underruns);
        $display("reader: %0d bursts of 4 reads; clocks from cyc to the first read taken: at most %0d, mean %0d.%02d",
                 bursts, wait_max, wait_sum / bursts, (wait_sum * 100 / bursts) % 100);
        $display("disparity since the last token, at the end of each character: ch0 %0d to %0d, ch1 %0d to %0d, ch2 %0d to %0d",
                 run_min[0], run_max[0], run_min[1], run_max[1], run_min[2], run_max[2]);
        $display("disparity on the wire over the last frame, tokens included: ch0 %0d, ch1 %0d, ch2 %0d",
                 drift[0], drift[1], drift[2]);
        $display("changes of level inside a character: data at most %0d, control tokens at least %0d",
                 data_changes_max, token_changes_min);
        $display("vblank: %0d edges, %0d handler runs; STATUS %h; UNDERRUN %0d",
                 vblank_edges, handler_runs, {dut.u_display.u_bus.left != 0,
                 dut.u_display.u_bus.bus_error, dut.u_display.u_bus.underrun_s,
                 dut.vblank}, dut.u_display.u_bus.underrun_s);

        // The bound the proof shows, seen in the run.
        for (k = 0; k < 3; k = k + 1)
            if (run_min[k] < -8 || run_max[k] > 8)
                fail($sformatf("channel %0d's disparity left -8 to 8", k));

        if (mode == 2) begin
            // The stall must cause an underrun, spoil that frame, and no other.
            if (hold_frame < 0)
                fail("the stall was never made");
            if (underruns == 0 || dut.u_display.u_bus.underrun_s !== 1'b1)
                fail("the stall caused no underrun");
            if (bad_frames != 1)
                fail($sformatf("%0d frames had wrong pixels, expected 1, frame %0d", bad_frames,
                               hold_frame));
            $display("stall: %0d clocks of the framebuffer in frame %0d", HOLD_CLOCKS, hold_frame);
        end else begin
            if (mismatches != 0)
                fail($sformatf("%0d pixels differ from the framebuffer", mismatches));
            if (underruns != 0 || dut.u_display.u_bus.underrun_s !== 1'b0)
                fail("the FIFO ran empty");
            if (frames_shown < frames_done - first_shown)
                fail("a frame after the first shown was not shown");
        end
        if (handler_runs < 2)
            fail("the vblank handler hardly ran");
        if (dut.u_display.u_bus.bus_error !== 1'b0)
            fail("the display's reader got err");

        if (errors == 0)
            $display("PASS");
        else
            $display("FAIL: %0d errors", errors);
        $finish;
    end

endmodule
