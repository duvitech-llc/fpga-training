// A small interrupt controller: three devices share the core's one external
// interrupt line, MEIP. A Wishbone B4 pipelined slave:
//
//   BASE + 0x0  PENDING  read: bit 0 UART, a received byte is waiting. Bit 1 DMA,
//                        a copy has ended, with DONE or ERROR. Bit 2 VBLANK, the
//                        display has started a vertical blank. The other bits
//                        read 0.
//                        write: a 1 in bit 1 clears the DMA bit, a 1 in bit 2
//                        the VBLANK bit. Bit 0 cannot be cleared here: reading
//                        the UART's data register clears it.
//   BASE + 0x4  ENABLE   read/write: bit 0 UART, bit 1 DMA, bit 2 VBLANK. Reset:
//                        0, all off.
//   BASE + 0x8,
//   BASE + 0xC           nothing: err.
//
//   irq = PENDING & ENABLE, any bit.
//
// Tutorial 33 added bit 2. The sources are not alike, so they are not handled
// alike:
//
//   UART    a level. The line is high while a byte waits, and reading the byte
//           clears it. Bit 0 is that line, as a wire, with nothing latched.
//   DMA     wb_dma's DONE and ERROR stay set until the next START, so as a level
//           the line would stay high after the handler had seen it. Instead, the
//           edge where DONE or ERROR rises sets bit 1, and only the handler
//           clears it. The edge is taken from the DMA engine's own lines, never
//           from the shared line: while the UART holds the shared line high, an
//           edge on it would be lost.
//   VBLANK  the display's vblank, already synchronised to this clock, is high
//           for the whole vertical blanking, thousands of clocks. As a level it
//           would interrupt again and again. So, like the DMA engine's, its
//           rising edge sets bit 2 and only the handler clears it.
//
// If an edge comes on the same clock as the write that clears its bit, the edge
// wins, so none is ever lost. A START that ends at once, with LEN 0 or a
// misaligned word copy, while DONE or ERROR is still set from the last copy,
// makes no edge, and so no interrupt: START clears and sets the bit on one edge.
//
// Each request gets ack or err on the next clock. hold stalls requests, as in
// wb_regfile. Tie it low in a real design.
module wb_intc (
    input  wire        clk,
    input  wire        rst,       // synchronous, active high
    input  wire        cyc,
    input  wire        stb,
    input  wire        we,
    input  wire [1:0]  adr,       // the word: 0 PENDING, 1 ENABLE
    input  wire [3:0]  sel,
    input  wire [31:0] dat_w,
    output reg         ack,
    output reg         err,
    output wire        stall,
    output reg  [31:0] dat_r,
    input  wire        hold,
    // The sources
    input  wire        uart_irq,  // level: a byte is waiting
    input  wire        dma_done,  // wb_dma's DONE and ERROR
    input  wire        dma_error,
    input  wire        vblank,    // the display's, synchronised to clk
    // To the core's irq_external
    output wire        irq
);

    assign stall = hold;

    wire accept = cyc && stb && !stall;
    wire bad    = adr[1];

    // The DMA engine's end, as an edge of its own two lines.
    wire dma_end = dma_done || dma_error;
    reg  dma_end_q;
    wire dma_rise = dma_end && !dma_end_q;

    // The start of a vertical blank, as an edge.
    reg  vblank_q;
    wire vblank_rise = vblank && !vblank_q;

    reg       dma_pending, vblank_pending;
    reg [2:0] enable;

    wire [2:0] pending = {vblank_pending, dma_pending, uart_irq};
    assign irq = |(pending & enable);

    wire write_pending = accept && we && adr == 2'd0 && sel[0];
    wire clear         = write_pending && dat_w[1];
    wire clear_vblank  = write_pending && dat_w[2];

    always @(posedge clk) begin
        if (rst) begin
            dma_end_q      <= 1'b0;
            dma_pending    <= 1'b0;
            vblank_q       <= 1'b0;
            vblank_pending <= 1'b0;
            enable         <= 3'b000;
        end else begin
            dma_end_q <= dma_end;
            if (dma_rise)
                dma_pending <= 1'b1;
            else if (clear)
                dma_pending <= 1'b0;
            vblank_q <= vblank;
            if (vblank_rise)
                vblank_pending <= 1'b1;
            else if (clear_vblank)
                vblank_pending <= 1'b0;
            if (accept && we && adr == 2'd1 && sel[0])
                enable <= dat_w[2:0];
        end

        if (rst || !cyc) begin
            ack <= 1'b0;
            err <= 1'b0;
        end else begin
            ack <= accept && !bad;
            err <= accept && bad;
        end

        if (accept)
            dat_r <= (adr == 2'd0) ? {29'd0, pending} :
                     (adr == 2'd1) ? {29'd0, enable} :
                                     32'd0;
    end

    // Only bits 2 to 0 of a write are used.
    wire unused = &{1'b0, sel[3:1], dat_w[31:3]};

`ifdef FORMAL
    reg f_past_valid = 1'b0;
    reg f_past_rst, f_past_cyc, f_past_hold;
    always @(posedge clk) begin
        f_past_valid <= 1'b1;
        f_past_rst   <= rst;
        f_past_cyc   <= cyc;
        f_past_hold  <= hold;
    end

    always @(*)
        if (!f_past_valid)
            assume (rst);

    // hold is for testing. Assume it never lasts two clocks, so every request
    // ends, as wb_spi's proof does.
    always @(*)
        if (f_past_valid && f_past_hold)
            assume (!hold);

    wire [3:0] f_outstanding;
    wire [7:0] f_waited;
    wire [7:0] f_stalled;

    wb_checker #(
        .AW(2), .DUT_IS_SLAVE(1), .LGDEPTH(4),
        .MAX_OUTSTANDING(1), .MAX_WAIT(1), .MAX_STALL(2)
    ) f_bus (
        .clk(clk), .rst(rst),
        .cyc(cyc), .stb(stb), .we(we), .adr(adr), .sel(sel), .dat_w(dat_w),
        .ack(ack), .err(err), .stall(stall),
        .outstanding(f_outstanding), .waited(f_waited), .stalled(f_stalled)
    );

    // The last request taken, to check its answer.
    reg f_was_bad = 1'b0;
    always @(posedge clk)
        f_was_bad <= accept && bad;

    always @(*) begin
        if (f_past_valid && !f_past_rst && f_past_cyc) begin
            assert (f_outstanding == {3'd0, ack || err});
            if (ack || err)
                assert (err == f_was_bad);
        end else if (f_past_valid) begin
            assert (!ack && !err);
        end
        // The line is exactly the enabled pending bits.
        assert (irq == ((uart_irq && enable[0]) || (dma_pending && enable[1])
                        || (vblank_pending && enable[2])));
    end

    // Each edge, worked out here from the source's own lines, so that the
    // checks below do not trust dma_end_q or vblank_q.
    reg  f_end_q = 1'b0;
    reg  f_vb_q  = 1'b0;
    always @(posedge clk) begin
        f_end_q <= !rst && (dma_done || dma_error);
        f_vb_q  <= !rst && vblank;
    end
    wire f_end = (dma_done || dma_error) && !f_end_q;
    wire f_vb  = vblank && !f_vb_q;

    always @(posedge clk) begin
        if (f_past_valid && !f_past_rst && !$past(rst)) begin
            // No end of a DMA copy and no vertical blank is ever lost, whatever
            // else is pending, and even if the handler clears its bit on that
            // very clock.
            if ($past(f_end))
                assert (dma_pending);
            if ($past(f_vb))
                assert (vblank_pending);
            // A bit never rises without its edge, and never falls without a
            // clear.
            if (dma_pending && !$past(dma_pending))
                assert ($past(f_end));
            if (!dma_pending && $past(dma_pending))
                assert ($past(clear));
            if (vblank_pending && !$past(vblank_pending))
                assert ($past(f_vb));
            if (!vblank_pending && $past(vblank_pending))
                assert ($past(clear_vblank));
            // Tutorial 33: and a clear works, unless an edge came on the same
            // clock. Without this, a bit set by the level, not the edge, would
            // pass every check above: it would rise only with the line and fall
            // only on a clear, but no clear could take it down while the line
            // stayed high, so the handler would be entered again and again.
            if ($past(clear) && !$past(f_end))
                assert (!dma_pending);
            if ($past(clear_vblank) && !$past(f_vb))
                assert (!vblank_pending);
            // A read of PENDING returns the bits as they were when it was taken.
            if (ack && $past(!we && adr == 2'd0))
                assert (dat_r == {29'd0, $past(vblank_pending), $past(dma_pending),
                                  $past(uart_irq)});
        end
    end

    // These must be reachable.
    reg f_both = 1'b0;   // the DMA ended while the UART's byte was waiting
    reg f_cleared = 1'b0;
    reg f_vb_cleared = 1'b0;
    always @(posedge clk) begin
        f_cleared    <= !rst && clear && dma_pending && !dma_rise;
        f_vb_cleared <= !rst && clear_vblank && vblank_pending && !vblank_rise;
    end
    always @(posedge clk)
        if (rst)
            f_both <= 1'b0;
        else if (dma_rise && uart_irq)
            f_both <= 1'b1;

    always @(*) begin
        if (f_past_valid && !rst) begin
            cover (irq && dma_pending && uart_irq && enable == 3'b011);
            cover (f_both && dma_pending && irq);
            cover (ack && dat_r == 32'd3);           // a read of PENDING with two bits
            cover (ack && dat_r == 32'd7);           // and with all three
            cover (err);                             // the hole
            cover (f_cleared);                       // the handler cleared bit 1
            cover (f_vb_cleared);                    // and bit 2
            cover (irq && vblank_pending && enable == 3'b100 && !vblank);
        end
    end
`endif

endmodule
