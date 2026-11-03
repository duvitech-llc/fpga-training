// The display controller's bus side: its registers, a Wishbone slave, and the
// framebuffer reader, a Wishbone master. Everything here runs on the system
// clock. The reader fills the dual-clock FIFO; display_pixel.v empties it on
// the pixel clock.
//
// Registers, a Wishbone B4 pipelined slave, each answered on the next clock:
//
//   +0x00  CTRL     read/write: bit 0 ENABLE. Reset: 0, the screen is black
//   +0x04  BASE     read/write: the framebuffer's byte address for the next
//                   frame, a multiple of 4. Reset: BASE_RESET
//   +0x08  CURRENT  read: BASE as it was taken for the frame now on the screen
//   +0x0C  STATUS   read: bit 0 VBLANK, the pixel side is in vertical blanking.
//                   Bit 1 UNDERRUN, a pixel found the FIFO empty, since reset.
//                   Bit 2 BUS_ERROR, a read got err, since reset. Bit 3
//                   READING, the reader has words of a frame still to fetch
//   +0x10  FRAMES   read: vertical blanks seen since reset
//   +0x14  SIZE     read: HEIGHT in bits 31:16, WIDTH in bits 15:0
//   +0x18, +0x1C    err
//
// Writes to the read-only registers are ignored.
//
// A frame, from the bus side. The pixel side sends two levels across: vblank,
// and show, which says whether the next frame will be shown. Both change on
// the same pixel clock edge, when vertical blanking starts, and then hold
// still for the whole blanking. Each passes a two-flop synchroniser, Tutorial
// 13's sync_2ff. One clock after the synchronised vblank rises, CURRENT takes
// BASE, FRAMES counts, and if show is 1 the reader starts on that frame: WORDS
// words from CURRENT on, in order, into the FIFO. show has been still for at
// least that clock, so it is read safely even if its synchroniser took a clock
// longer than vblank's.
//
// The reader reads in bursts: one Wishbone cycle of BURST reads, pipelined,
// started only when the FIFO has room for all of them. wr_used, the FIFO's
// count on this side, is never less than the truth, so the FIFO never
// overflows. The cycle ends when the last answer is in, so the arbiter can
// hand the bus on. Tutorial 29's round-robin arbiter makes each master wait
// for at most one cycle of each other master.
//
// If the reader is still busy with one frame when the next starts, as after a
// long stall, it queues the new frame and starts it when done. So the bus side
// always sends exactly WORDS words for every frame the pixel side shows, and
// the two sides cannot drift apart for good.
module wb_display #(
    parameter integer WIDTH      = 160,
    parameter integer HEIGHT     = 120,
    parameter integer FIFO_AW    = 4,             // the FIFO holds 2**FIFO_AW words
    parameter integer BURST      = 4,             // reads per bus cycle
    parameter [31:0]  BASE_RESET = 32'h0100_0000
) (
    input  wire               clk,
    input  wire               rst,         // synchronous, active high
    // Slave: the registers
    input  wire               cyc,
    input  wire               stb,
    input  wire               we,
    input  wire [2:0]         adr,
    input  wire [3:0]         sel,
    input  wire [31:0]        dat_w,
    output reg                ack,
    output reg                err,
    output wire               stall,
    output reg  [31:0]        dat_r,
    input  wire               hold,        // testing only: stalls requests. Tie low
    // Master: reads of the framebuffer
    output reg                m_cyc,
    output reg                m_stb,
    output wire               m_we,
    output reg  [29:0]        m_adr,
    output wire [3:0]         m_sel,
    output wire [31:0]        m_dat_w,
    input  wire               m_ack,
    input  wire               m_err,
    input  wire               m_stall,
    input  wire [31:0]        m_dat_r,
    // The FIFO's write side
    output wire               fifo_wr,
    output wire [31:0]        fifo_data,
    input  wire [FIFO_AW:0]   fifo_used,   // never less than the truth
    // From the pixel clock's domain, each a flop there
    input  wire               vblank_p,
    input  wire               show_p,
    input  wire               underrun_p,
    // To the pixel clock's domain
    output reg                enable,
    // vblank, synchronised to clk, for the interrupt controller
    output wire               vblank
);

    localparam integer WORDS = WIDTH * HEIGHT / 4;   // one byte per pixel
    localparam integer DEPTH = 1 << FIFO_AW;
    localparam integer LW    = $clog2(WORDS + 1);
    localparam integer BW    = $clog2(BURST + 1);
    localparam integer ROOM  = DEPTH - BURST;         // the most words held to start a burst

    // ----- The levels from the pixel side -----

    wire show_s, underrun_s;

    sync_2ff u_sync_vblank   (.clk(clk), .rst(rst), .d(vblank_p),   .q(vblank));
    sync_2ff u_sync_show     (.clk(clk), .rst(rst), .d(show_p),     .q(show_s));
    sync_2ff u_sync_underrun (.clk(clk), .rst(rst), .d(underrun_p), .q(underrun_s));

    reg  vblank_q, tick_q;
    wire tick = vblank && !vblank_q;   // the clock vertical blanking is seen to start

    // ----- Registers -----

    reg [29:0] base, current;
    reg [31:0] frames;
    reg        bus_error;

    // ----- The reader -----

    reg [LW-1:0] left;        // words of this frame still to be answered
    reg [7:0]    queued;      // frames to start once this one is done
    reg [BW-1:0] to_send;     // requests left in this burst
    reg [BW-1:0] to_recv;     // answers left in this burst

    wire new_frame   = tick_q && show_s;
    wire idle        = left == {LW{1'b0}} && !m_cyc;
    wire begin_frame = idle && (new_frame || queued != 8'd0);
    wire room        = fifo_used <= ROOM[FIFO_AW:0];

    assign m_we    = 1'b0;
    assign m_sel   = 4'hF;
    assign m_dat_w = 32'd0;

    // An answer goes into the FIFO, err or not, so the count stays right.
    assign fifo_wr   = m_cyc && (m_ack || m_err);
    assign fifo_data = m_err ? 32'd0 : m_dat_r;

    always @(posedge clk) begin
        if (rst) begin
            vblank_q  <= 1'b0;
            tick_q    <= 1'b0;
            frames    <= 32'd0;
            current   <= BASE_RESET[31:2];
            left      <= {LW{1'b0}};
            queued    <= 8'd0;
            m_cyc     <= 1'b0;
            m_stb     <= 1'b0;
            m_adr     <= 30'd0;
            to_send   <= {BW{1'b0}};
            to_recv   <= {BW{1'b0}};
            bus_error <= 1'b0;
        end else begin
            vblank_q <= vblank;
            tick_q   <= tick;

            if (tick_q) begin
                frames  <= frames + 32'd1;
                current <= base;
            end

            if (begin_frame) begin
                left   <= WORDS[LW-1:0];
                // A new frame reads from BASE as it is now; a queued one from
                // CURRENT, the last BASE taken.
                m_adr  <= new_frame ? base : current;
                queued <= queued - {7'd0, !new_frame};
            end else if (new_frame) begin
                queued <= queued + 8'd1;
            end

            if (!m_cyc) begin
                if (left != {LW{1'b0}} && room) begin
                    m_cyc   <= 1'b1;
                    m_stb   <= 1'b1;
                    to_send <= BURST[BW-1:0];
                    to_recv <= BURST[BW-1:0];
                end
            end else begin
                if (m_stb && !m_stall) begin
                    m_adr   <= m_adr + 30'd1;
                    to_send <= to_send - 1'b1;
                    if (to_send == 1)
                        m_stb <= 1'b0;
                end
                if (m_ack || m_err) begin
                    left    <= left - 1'b1;
                    to_recv <= to_recv - 1'b1;
                    if (to_recv == 1)
                        m_cyc <= 1'b0;
                    if (m_err)
                        bus_error <= 1'b1;
                end
            end
        end
    end

    // ----- The slave -----

    assign stall = hold;

    wire accept = cyc && stb && !stall;
    wire bad    = adr[2] && adr[1];      // words 6 and 7

    // BASE, with the bytes of a write that sel names.
    wire [31:0] base_bytes = {base, 2'b00};
    wire [31:0] base_new   = {sel[3] ? dat_w[31:24] : base_bytes[31:24],
                              sel[2] ? dat_w[23:16] : base_bytes[23:16],
                              sel[1] ? dat_w[15:8]  : base_bytes[15:8],
                              sel[0] ? dat_w[7:0]   : base_bytes[7:0]};

    always @(posedge clk) begin
        if (rst) begin
            enable <= 1'b0;
            base   <= BASE_RESET[31:2];
        end else if (accept && we) begin
            if (adr == 3'd0 && sel[0])
                enable <= dat_w[0];
            if (adr == 3'd1)
                base <= base_new[31:2];
        end

        if (rst || !cyc) begin
            ack <= 1'b0;
            err <= 1'b0;
        end else begin
            ack <= accept && !bad;
            err <= accept && bad;
        end

        if (accept)
            case (adr)
                3'd0:    dat_r <= {31'd0, enable};
                3'd1:    dat_r <= {base, 2'b00};
                3'd2:    dat_r <= {current, 2'b00};
                3'd3:    dat_r <= {28'd0, left != {LW{1'b0}}, bus_error, underrun_s, vblank};
                3'd4:    dat_r <= frames;
                3'd5:    dat_r <= {HEIGHT[15:0], WIDTH[15:0]};
                default: dat_r <= 32'd0;
            endcase
    end

    // The low two bits of BASE are always 0.
    wire unused = &{1'b0, base_new[1:0]};

endmodule
