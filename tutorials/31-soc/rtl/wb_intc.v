// A small interrupt controller: two devices share the core's one external
// interrupt line, MEIP. A Wishbone B4 pipelined slave:
//
//   BASE + 0x0  PENDING  read: bit 0 UART, a received byte is waiting. Bit 1 DMA,
//                        a copy has ended, with DONE or ERROR. The other bits
//                        read 0.
//                        write: a 1 in bit 1 clears the DMA bit. Bit 0 cannot be
//                        cleared here: reading the UART's data register clears it.
//   BASE + 0x4  ENABLE   read/write: bit 0 UART, bit 1 DMA. Reset: 0, both off.
//   BASE + 0x8,
//   BASE + 0xC           nothing: err.
//
//   irq = PENDING & ENABLE, either bit.
//
// The two sources are not alike, so they are not handled alike:
//
//   UART  a level. The line is high while a byte waits, and reading the byte
//         clears it. Bit 0 is that line, as a wire, with nothing latched.
//   DMA   wb_dma's DONE and ERROR stay set until the next START, so as a level
//         the line would stay high after the handler had seen it. Instead, the
//         edge where DONE or ERROR rises sets bit 1, and only the handler clears
//         it. The edge is taken from the DMA engine's own lines, never from the
//         shared line: while the UART holds the shared line high, an edge on it
//         would be lost. "Try it yourself" shows that bug.
//
// If the DMA's edge comes on the same clock as the write that clears bit 1, the
// edge wins, so an end is never lost. A START that ends at once, with LEN 0 or a
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

    reg       dma_pending;
    reg [1:0] enable;

    wire [1:0] pending = {dma_pending, uart_irq};
    assign irq = |(pending & enable);

    wire clear = accept && we && adr == 2'd0 && sel[0] && dat_w[1];

    always @(posedge clk) begin
        if (rst) begin
            dma_end_q   <= 1'b0;
            dma_pending <= 1'b0;
            enable      <= 2'b00;
        end else begin
            dma_end_q <= dma_end;
            if (dma_rise)
                dma_pending <= 1'b1;
            else if (clear)
                dma_pending <= 1'b0;
            if (accept && we && adr == 2'd1 && sel[0])
                enable <= dat_w[1:0];
        end

        if (rst || !cyc) begin
            ack <= 1'b0;
            err <= 1'b0;
        end else begin
            ack <= accept && !bad;
            err <= accept && bad;
        end

        if (accept)
            dat_r <= (adr == 2'd0) ? {30'd0, pending} :
                     (adr == 2'd1) ? {30'd0, enable} :
                                     32'd0;
    end

    // Only bits 1 and 0 of a write are used.
    wire unused = &{1'b0, sel[3:1], dat_w[31:2]};

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
        assert (irq == ((uart_irq && enable[0]) || (dma_pending && enable[1])));
    end

    // The DMA engine's end, as an edge, worked out here from its own two lines,
    // so that the checks below do not trust dma_end_q.
    reg  f_end_q = 1'b0;
    always @(posedge clk)
        f_end_q <= !rst && (dma_done || dma_error);
    wire f_end = (dma_done || dma_error) && !f_end_q;

    always @(posedge clk) begin
        if (f_past_valid && !f_past_rst && !$past(rst)) begin
            // An end of a DMA copy is never lost, whatever else is pending, and
            // even if the handler clears the bit on that very clock.
            if ($past(f_end))
                assert (dma_pending);
            // The DMA bit never rises without an end, and never falls without a
            // clear.
            if (dma_pending && !$past(dma_pending))
                assert ($past(f_end));
            if (!dma_pending && $past(dma_pending))
                assert ($past(clear));
            // A read of PENDING returns both bits as they were when it was taken.
            if (ack && $past(!we && adr == 2'd0))
                assert (dat_r == {30'd0, $past(dma_pending), $past(uart_irq)});
        end
    end

    // These must be reachable.
    reg f_both = 1'b0;   // the DMA ended while the UART's byte was waiting
    reg f_cleared = 1'b0;
    always @(posedge clk)
        f_cleared <= !rst && clear && dma_pending && !dma_rise;
    always @(posedge clk)
        if (rst)
            f_both <= 1'b0;
        else if (dma_rise && uart_irq)
            f_both <= 1'b1;

    always @(*) begin
        if (f_past_valid && !rst) begin
            cover (irq && dma_pending && uart_irq && enable == 2'b11);
            cover (f_both && dma_pending && irq);
            cover (ack && dat_r == 32'd3);           // a read of PENDING with both bits
            cover (err);                             // the hole
            cover (f_cleared);                       // the handler cleared bit 1
        end
    end
`endif

endmodule
