// One SPI flash, two controllers: Tutorial 28's SPI controller, wb_spi, which the
// boot ROM uses to copy the program, and Tutorial 30's XIP slave, wb_xip, which
// the core fetches code through. Both are Tutorial 24's master inside, and both
// expect to own the pins. This module gives the pins to one of them at a time.
//
//   owner   FREE   neither has CS low or work in hand. The pins show the XIP
//                  slave's, which are idle: CS high, SCLK low.
//           SPI    the SPI controller has the pins.
//           XIP    the XIP slave has the pins.
//
// The rule: a controller gets the pins only from FREE, and FREE needs both CS
// high. A controller starts a command only when a bus request reaches it, so
// this module holds back each controller's requests, through spi_go and xip_go
// and two wb_gate modules in soc.v, until it owns the pins:
//
//   FREE -> SPI   a request to the SPI controller is waiting.
//   FREE -> XIP   a request to the XIP slave is waiting, and none to the SPI one.
//   SPI -> FREE   the SPI controller is not busy (no byte waiting in TX, CS high)
//                 and no request to it is waiting.
//   XIP -> FREE   the XIP slave's CS is high and no request to it is waiting.
//
// The XIP slave leaves CS low after a word, to stream the next one, and would
// keep it low until its next read. If a request to the SPI controller waits
// while the XIP slave sits like that, close resets the XIP slave for one clock:
// as in wb_xip's own way of ending a stream, its master's reset raises CS. That
// happens only while no request to the XIP slave is on the bus and none is
// being answered, so no bus transfer is cut short. The XIP slave forgets the
// one word it keeps, and reads it again next time.
//
// So the CS of one is never low while the other has the pins. formal/ proves it,
// given how the two controllers behave, which the assumptions there state.
//
// One thing this cannot fix: code that drives the SPI controller must not be
// fetched from the flash. While the SPI controller holds CS low between two
// bytes, a fetch from the XIP slave waits for the pins, and the core cannot
// fetch the instruction that would send the next byte. The README shows it.
module flash_share (
    input  wire clk,
    input  wire rst,          // synchronous, active high
    // A request to each controller is on the bus
    input  wire spi_req,
    input  wire xip_req,
    // The SPI controller's busy, its STATUS bit 2
    input  wire spi_busy,
    // The XIP slave's answer, so that close never cuts one short
    input  wire xip_ack,
    // Each controller's pins
    input  wire spi_sclk,
    input  wire spi_mosi,
    input  wire spi_cs_n,
    input  wire xip_sclk,
    input  wire xip_mosi,
    input  wire xip_cs_n,
    // Let each controller's requests through
    output wire spi_go,
    output wire xip_go,
    // Reset the XIP slave, to end its open stream
    output wire xip_close,
    // The flash's pins
    output wire flash_sclk,
    output wire flash_mosi,
    output wire flash_cs_n
);

    localparam [1:0] FREE = 2'd0;
    localparam [1:0] SPI  = 2'd1;
    localparam [1:0] XIP  = 2'd2;

    reg [1:0] owner;

    always @(posedge clk) begin
        if (rst) begin
            owner <= FREE;
        end else begin
            case (owner)
                FREE:
                    if (spi_req)
                        owner <= SPI;
                    else if (xip_req)
                        owner <= XIP;
                SPI:
                    if (!spi_busy && !spi_req)
                        owner <= FREE;
                XIP:
                    if (xip_cs_n && !xip_req)
                        owner <= FREE;
                default:
                    owner <= FREE;
            endcase
        end
    end

    assign spi_go    = owner == SPI;
    assign xip_go    = owner == XIP;
    assign xip_close = owner == XIP && spi_req && !xip_req && !xip_ack && !xip_cs_n;

    assign flash_sclk = spi_go ? spi_sclk : xip_sclk;
    assign flash_mosi = spi_go ? spi_mosi : xip_mosi;
    assign flash_cs_n = spi_go ? spi_cs_n : xip_cs_n;

`ifdef FORMAL
    reg f_past_valid = 1'b0;
    always @(posedge clk)
        f_past_valid <= 1'b1;

    always @(*)
        if (!f_past_valid)
            assume (rst);

    // ---- How the two controllers behave, assumed ----
    // These are the facts about wb_spi and wb_xip that this module relies on.
    // Each is true of the RTL by its construction, as the README explains, and
    // the system simulations check the result on every clock.
    //
    // 1. The SPI controller becomes busy only by taking a request, which needs
    //    spi_go and a request in the clock before. CS low means busy.
    // 2. The XIP slave lowers CS only while a request to it is let through: it
    //    starts a command only for a request, and the request stays on the bus
    //    until the word is in, which needs CS low first.
    // 3. close raises the XIP slave's CS at the next edge.
    // 4. Reset leaves both CS high and the SPI controller idle.
    // 5. Only one request is on the bus at a time.
    always @(posedge clk) begin
        if (f_past_valid) begin
            if (!$past(spi_go && spi_req) && !$past(spi_busy))
                assume (!spi_busy);
            if (!$past(xip_go && xip_req) && $past(xip_cs_n))
                assume (xip_cs_n);
            if ($past(xip_close) || $past(rst))
                assume (xip_cs_n);
            if ($past(rst))
                assume (!spi_busy);
        end
    end

    always @(*) begin
        if (!spi_cs_n)
            assume (spi_busy);
        assume (!(spi_req && xip_req));
        if (rst)
            assume (spi_cs_n && xip_cs_n && !spi_busy);
    end

    // ---- What this module promises ----
    always @(*) begin
        if (f_past_valid && !rst) begin
            // The two never have CS low together.
            assert (spi_cs_n || xip_cs_n);
            // Whoever owns the pins, the other is idle.
            if (owner == FREE)
                assert (!spi_busy && xip_cs_n);
            if (owner == SPI)
                assert (xip_cs_n);
            if (owner == XIP)
                assert (!spi_busy);
            assert (owner != 2'd3);
            // The flash sees exactly the controller whose CS is low.
            if (!spi_cs_n)
                assert (flash_cs_n == 1'b0 && flash_sclk == spi_sclk && flash_mosi == spi_mosi);
            if (!xip_cs_n)
                assert (flash_cs_n == 1'b0 && flash_sclk == xip_sclk && flash_mosi == xip_mosi);
            if (spi_cs_n && xip_cs_n)
                assert (flash_cs_n);
            // A request that is let through is never taken back before it is
            // taken, which wb_gate's proof assumes.
        end
    end

    always @(posedge clk) begin
        if (f_past_valid && !$past(rst) && !rst) begin
            if ($past(spi_go && spi_req))
                assert (spi_go);
            if ($past(xip_go && xip_req))
                assert (xip_go);
        end
    end

    // ---- These must be reachable ----
    reg f_spi_after_xip = 1'b0;   // the SPI controller got the pins after an open stream
    reg f_xip_after_spi = 1'b0;
    reg f_was_xip = 1'b0, f_was_spi = 1'b0, f_closed = 1'b0;
    always @(posedge clk) begin
        if (rst) begin
            f_was_xip <= 1'b0;
            f_was_spi <= 1'b0;
            f_closed  <= 1'b0;
            f_spi_after_xip <= 1'b0;
            f_xip_after_spi <= 1'b0;
        end else begin
            if (owner == XIP && !xip_cs_n)
                f_was_xip <= 1'b1;
            if (owner == SPI && !spi_cs_n)
                f_was_spi <= 1'b1;
            if (xip_close)
                f_closed <= 1'b1;
            if (owner == SPI && !spi_cs_n && f_closed)
                f_spi_after_xip <= 1'b1;
            if (owner == XIP && !xip_cs_n && f_was_spi)
                f_xip_after_spi <= 1'b1;
        end
    end

    always @(*) begin
        if (f_past_valid && !rst) begin
            cover (f_spi_after_xip);
            cover (f_xip_after_spi && f_spi_after_xip);
            cover (owner == SPI && xip_req);    // an XIP request waits for the pins
            cover (owner == XIP && spi_req);    // an SPI request waits for the pins
        end
    end
`endif

endmodule
