// Tutorial 24's SPI master as a Wishbone B4 pipelined slave.
//
//   BASE + 0x00  CTRL    read/write. Bits 7 to 0 the divider, clk_div: each half
//                        period of SCLK is clk_div + 1 clocks. Bit 8 CPOL, bit 9
//                        CPHA. Byte writes change only their own byte. Reset:
//                        DIV_RESET, mode 0. The master reads CPOL while CS is
//                        high, and the divider and CPHA as each byte starts.
//   BASE + 0x04  TX      write: send bits 7 to 0. Bit 8 is "last": CS rises
//                        after this byte. Without it CS stays low and waits for
//                        the next byte. One byte can wait here while another is
//                        on the wire. A write while one is already waiting
//                        stalls until the master takes it. A write with sel[0]
//                        low does nothing. Reads return 0.
//   BASE + 0x08  RX      read: the last byte received, in bits 7 to 0. A read
//                        empties it. A write gets err.
//   BASE + 0x0C  STATUS  read: bit 0 TX is empty, so a write will not stall.
//                        Bit 1 RX holds a byte. Bit 2 busy: a byte waits in TX,
//                        or CS is low. Bit 3 overrun: a byte arrived while RX
//                        was full, and the older one was lost. Any write clears
//                        bit 3.
//   BASE + 0x10  STREAM  read: the next byte, without polling. If RX is empty
//                        and nothing is on its way, the read sends a dummy byte,
//                        0x00 without last. The read then stalls until a byte is
//                        in RX, and takes it like a read of RX. As it does, it
//                        sends the next dummy byte, so that byte is on the wire
//                        while the program works on this one. A write gets err.
//   BASE + 0x14 to 0x1C  nothing: any access gets err.
//
// Every byte sent also receives one, and every byte received lands in RX, even
// when the program does not want it. A program that sends a command reads RX
// after each byte to empty it, or ignores overrun.
//
// adr is three bits: the word within the slave. The interconnect has checked
// the rest. A request that is taken gets ack or err on the next clock. Only TX
// and STREAM add stalls of their own, as described above. hold stalls every
// request, as in wb_regfile. Tie it low in a real design.
//
// Tutorial 31 adds one output, busy: status bit 2, a byte waits in TX or CS is
// low, as a wire. The flash is shared with the XIP slave there, and busy says
// when the SPI controller still needs the pins. Nothing else changed.
module wb_spi #(
    parameter [7:0] DIV_RESET = 8'd1
) (
    input  wire        clk,
    input  wire        rst,     // synchronous, active high
    input  wire        cyc,
    input  wire        stb,
    input  wire        we,
    input  wire [2:0]  adr,     // the word: 0 CTRL, 1 TX, 2 RX, 3 STATUS, 4 STREAM
    input  wire [3:0]  sel,
    input  wire [31:0] dat_w,
    output reg         ack,
    output reg         err,
    output wire        stall,
    output reg  [31:0] dat_r,
    input  wire        hold,
    // The SPI pins
    output wire        sclk,
    output wire        mosi,
    input  wire        miso,
    output wire        cs_n,
    // New in Tutorial 31: status bit 2, a byte waits in TX or CS is low.
    output wire        busy
);

    localparam [2:0] R_CTRL = 3'd0, R_TX = 3'd1, R_RX = 3'd2, R_STATUS = 3'd3, R_STREAM = 3'd4;

    reg [7:0] div;
    reg       cpol, cpha;
    reg       tx_full;     // a byte waits in TX for the master
    reg [7:0] tx_byte;
    reg       tx_last;
    reg       in_flight;   // the master has a byte whose answer has not come back
    reg       rx_full;
    reg [7:0] rx_byte;
    reg       overrun;

    wire       m_ready, m_rx_valid;
    wire [7:0] m_rx_data;

    // Tutorial 24's master, unchanged. TX is its byte interface's buffer.
    spi_master #(.DIV_WIDTH(8)) u_spi (
        .clk(clk), .rst(rst),
        .cpol(cpol), .cpha(cpha), .clk_div(div),
        .tx_valid(tx_full), .tx_data(tx_byte), .tx_last(tx_last), .tx_ready(m_ready),
        .rx_valid(m_rx_valid), .rx_data(m_rx_data),
        .sclk(sclk), .mosi(mosi), .miso(miso), .cs_n(cs_n)
    );

    wire sending = tx_full && m_ready;   // the master takes TX at this edge

    // Requests that must wait. They do not depend on stb.
    wire tx_wait     = we && adr == R_TX && sel[0] && tx_full;
    wire stream_wait = !we && adr == R_STREAM && !rx_full;
    assign stall = hold || tx_wait || stream_wait;

    wire accept = cyc && stb && !stall;
    wire bad    = adr > R_STREAM || (we && (adr == R_RX || adr == R_STREAM));

    wire tx_write   = accept && we && adr == R_TX && sel[0];
    wire rx_take    = accept && !we && (adr == R_RX || adr == R_STREAM);
    wire stream_get = accept && !we && adr == R_STREAM;
    // A STREAM read that waits with nothing on its way sends a dummy byte to
    // start one. Once a STREAM read is taken, the next dummy byte goes too.
    wire stream_kick = cyc && stb && stream_wait && !tx_full && !in_flight;
    wire dummy       = stream_kick || (stream_get && !tx_full);

    assign busy = tx_full || !cs_n;
    wire [31:0] status = {28'd0, overrun, busy, rx_full, !tx_full};

    always @(posedge clk) begin
        if (rst) begin
            div       <= DIV_RESET;
            cpol      <= 1'b0;
            cpha      <= 1'b0;
            tx_full   <= 1'b0;
            tx_byte   <= 8'd0;
            tx_last   <= 1'b0;
            in_flight <= 1'b0;
            rx_full   <= 1'b0;
            rx_byte   <= 8'd0;
            overrun   <= 1'b0;
        end else begin
            if (accept && we && adr == R_CTRL) begin
                if (sel[0])
                    div <= dat_w[7:0];
                if (sel[1])
                    {cpha, cpol} <= dat_w[9:8];
            end

            // TX: filled by a write or a dummy byte, emptied by the master.
            if (tx_write) begin
                tx_full <= 1'b1;
                tx_byte <= dat_w[7:0];
                tx_last <= sel[1] && dat_w[8];
            end else if (dummy) begin
                tx_full <= 1'b1;
                tx_byte <= 8'h00;
                tx_last <= 1'b0;
            end else if (sending) begin
                tx_full <= 1'b0;
            end

            if (sending)
                in_flight <= 1'b1;
            else if (m_rx_valid)
                in_flight <= 1'b0;

            // RX: a new byte wins over a read on the same edge, which returns
            // the older one, as in the UART.
            if (m_rx_valid) begin
                rx_full <= 1'b1;
                rx_byte <= m_rx_data;
            end else if (rx_take) begin
                rx_full <= 1'b0;
            end

            if (m_rx_valid && rx_full && !rx_take)
                overrun <= 1'b1;
            else if (accept && we && adr == R_STATUS)
                overrun <= 1'b0;
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
                R_CTRL:            dat_r <= {22'd0, cpha, cpol, div};
                R_RX, R_STREAM:    dat_r <= {24'd0, rx_byte};
                R_STATUS:          dat_r <= status;
                default:           dat_r <= 32'd0;
            endcase
    end

    // Only bytes 0 and 1 of a write are used.
    wire unused = &{1'b0, sel[3:2], dat_w[31:10]};

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
        if (f_past_valid && f_past_hold)
            assume (!hold);

    // A stalled TX write or STREAM read waits for a whole byte on the wire, so
    // there is no limit on stalls: MAX_STALL is 0. Once taken, every request
    // is answered on the next clock.
    //
    // boot.sby reads spi_master.v without its own checks, which Tutorial 24
    // proved. Without them, induction may start the master in any state, even
    // one it cannot reach. So these checks are about the slave's side only, and
    // hold whatever the master does.
    wire [3:0] f_outstanding;
    wire [7:0] f_waited;
    wire [7:0] f_stalled;

    wb_checker #(
        .AW(3), .DUT_IS_SLAVE(1), .LGDEPTH(4),
        .MAX_OUTSTANDING(1), .MAX_WAIT(1), .MAX_STALL(0)
    ) f_bus (
        .clk(clk), .rst(rst),
        .cyc(cyc), .stb(stb), .we(we), .adr(adr), .sel(sel), .dat_w(dat_w),
        .ack(ack), .err(err), .stall(stall),
        .outstanding(f_outstanding), .waited(f_waited), .stalled(f_stalled)
    );

    // The last request, to check its answer.
    reg       f_bad_q = 1'b0;
    reg       f_take_q = 1'b0;
    reg       f_stream_q = 1'b0;
    reg [7:0] f_rx_q;
    always @(posedge clk) begin
        f_bad_q    <= accept && bad;
        f_take_q   <= rx_take;
        f_stream_q <= stream_get;
        f_rx_q     <= rx_byte;
    end

    always @(*) begin
        if (f_past_valid && !f_past_rst && f_past_cyc) begin
            assert (f_outstanding == {3'd0, ack || err});
            if (ack || err)
                assert (err == f_bad_q);
            // A read of RX or STREAM returns the byte that was waiting.
            if (ack && f_take_q)
                assert (dat_r == {24'd0, f_rx_q});
        end else if (f_past_valid) begin
            assert (!ack && !err);
        end
    end

    always @(posedge clk) begin
        if (f_past_valid && !f_past_rst && !rst) begin
            // A STREAM read is only taken with a byte in RX.
            if ($past(stream_get))
                assert ($past(rx_full));
            // No byte is lost from TX: it is only replaced when it was empty,
            // or was taken by the master on the same edge.
            if ($past(tx_full) && !$past(sending))
                assert (tx_full && tx_byte == $past(tx_byte) && tx_last == $past(tx_last));
            // RX only changes with a byte from the master, and then holds that
            // byte, the one just received.
            if (rx_byte != $past(rx_byte))
                assert ($past(m_rx_valid));
            if ($past(m_rx_valid))
                assert (rx_full && rx_byte == $past(m_rx_data));
            // A STREAM read that waits with nothing on its way starts a byte.
            if ($past(cyc && stb && stream_wait && !tx_full && !in_flight))
                assert (tx_full && tx_byte == 8'h00 && !tx_last);
        end
    end

    always @(*) begin
        if (f_past_valid && !rst) begin
            cover (ack && f_stream_q);                      // a STREAM read answered
            cover (cyc && stb && tx_wait && !hold);         // a TX write held back
            cover (ack && f_take_q && rx_byte != f_rx_q);   // ... while the next one lands
            cover (overrun);                                // a byte lost
            cover (err && f_past_cyc);                      // a write to RX, or the hole
        end
    end
`endif

endmodule
