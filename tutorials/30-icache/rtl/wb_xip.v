// Execute in place: a read-only Wishbone B4 pipelined slave that maps an SPI NOR
// flash into the address space. A read of a word becomes an SPI read command,
// 0x03, with the word's byte address, and the four bytes that come back.
//
//   adr     the word within the flash: 22 bits, so 16 MiB, all that 0x03's
//           24-bit address can reach. The bytes are little-endian: the byte at
//           the lowest address is bits 7 to 0.
//   reads   stall until the word is in, then ack on the next clock.
//   writes  err on the next clock. Flash is not written this way.
//
// The slave keeps the last word it read, so a second read of the same word is
// answered at once.
//
// STREAM. With 0, every word is a whole command: CS falls, 0x03 and three
// address bytes go out, four bytes come back, and CS rises. With 1, CS stays low
// after the word. The flash goes on sending the following bytes for as long as
// SCLK runs, so a read of the next word along needs only its four bytes. A read
// of any other word ends the open command first.
//
// Ending a command. Tutorial 24's spi_master raises CS only after a byte marked
// last, and an open stream has none: nobody knew which byte would be the last.
// Sending one more byte only to raise CS would cost a whole byte. So the slave
// resets the master instead, which raises CS on the next clock, then waits DIV + 1
// clocks with CS high before the next command.
//
// hold stalls every request, as in wb_regfile. Tie it low in a real design.
module wb_xip #(
    parameter       STREAM = 1,
    parameter [7:0] DIV    = 8'd1    // each half period of SCLK is DIV + 1 clocks
) (
    input  wire        clk,
    input  wire        rst,     // synchronous, active high
    input  wire        cyc,
    input  wire        stb,
    input  wire        we,
    input  wire [21:0] adr,     // word address within the flash
    output reg         ack,
    output reg         err,     // for every write
    output wire        stall,
    output reg  [31:0] dat_r,
    input  wire        hold,
    // The SPI pins
    output wire        sclk,
    output wire        mosi,
    input  wire        miso,
    output wire        cs_n
);

    // ----- The last word read -----

    reg        buf_valid;
    reg [21:0] buf_addr;
    reg [31:0] buf_word;

    wire want = cyc && stb && !we;
    wire have = buf_valid && buf_addr == adr;

    assign stall = hold || (want && !have);
    wire   accept = cyc && stb && !stall;

    always @(posedge clk) begin
        if (rst || !cyc) begin
            ack <= 1'b0;
            err <= 1'b0;
        end else begin
            ack <= accept && !we;
            err <= accept && we;
        end
        if (accept)
            dat_r <= buf_word;
    end

    // ----- Reading a word from the flash -----

    reg        busy;        // a word is on its way
    reg [21:0] target;      // ... this one
    reg [2:0]  index;       // the byte of the command: 0 is 0x03, 1 to 3 the address, 4 to 7 data
    reg        tx_full;     // the byte at index waits for the master
    reg [23:0] word;        // the data bytes before the last, the newest at the top
    reg        open;        // CS is low, and the next byte is the first of next_addr
    reg [21:0] next_addr;
    reg        closing;     // the master is held in reset for this clock
    reg [7:0]  gap;         // clocks left with CS high before the next command

    wire       m_ready, m_rx_valid;
    wire [7:0] m_rx_data;

    wire [23:0] byte_addr = {target, 2'b00};
    wire [7:0]  tx_byte   = (index == 3'd0) ? 8'h03 :
                            (index == 3'd1) ? byte_addr[23:16] :
                            (index == 3'd2) ? byte_addr[15:8] :
                            (index == 3'd3) ? byte_addr[7:0] :
                                              8'h00;
    wire        tx_last   = (STREAM == 0) && index == 3'd7;

    // Tutorial 24's master, unchanged, in mode 0.
    spi_master #(.DIV_WIDTH(8)) u_spi (
        .clk(clk), .rst(rst || closing),
        .cpol(1'b0), .cpha(1'b0), .clk_div(DIV),
        .tx_valid(tx_full && gap == 8'd0), .tx_data(tx_byte), .tx_last(tx_last),
        .tx_ready(m_ready),
        .rx_valid(m_rx_valid), .rx_data(m_rx_data),
        .sclk(sclk), .mosi(mosi), .miso(miso), .cs_n(cs_n)
    );

    wire start = !busy && want && !have;
    wire sent  = tx_full && gap == 8'd0 && m_ready;

    always @(posedge clk) begin
        if (rst) begin
            buf_valid <= 1'b0;
            buf_addr  <= 22'd0;
            buf_word  <= 32'd0;
            busy      <= 1'b0;
            target    <= 22'd0;
            index     <= 3'd0;
            tx_full   <= 1'b0;
            word      <= 24'd0;
            open      <= 1'b0;
            next_addr <= 22'd0;
            closing   <= 1'b0;
            gap       <= 8'd0;
        end else begin
            closing <= 1'b0;
            if (gap != 8'd0 && !closing)
                gap <= gap - 1'b1;

            if (start) begin
                busy    <= 1'b1;
                target  <= adr;
                tx_full <= 1'b1;
                if (STREAM != 0 && open && adr == next_addr) begin
                    index <= 3'd4;              // the stream is already there
                end else begin
                    index <= 3'd0;              // a new command
                    if (open) begin
                        closing <= 1'b1;        // CS rises at this edge
                        gap     <= DIV + 8'd1;
                        open    <= 1'b0;
                    end
                end
            end

            if (sent)
                tx_full <= 1'b0;

            if (busy && m_rx_valid) begin
                word <= {m_rx_data, word[23:8]};
                if (index == 3'd7) begin
                    busy      <= 1'b0;
                    buf_valid <= 1'b1;
                    buf_addr  <= target;
                    buf_word  <= {m_rx_data, word};
                    open      <= STREAM != 0;
                    next_addr <= target + 1'b1;
                end else begin
                    index   <= index + 1'b1;
                    tx_full <= 1'b1;
                end
            end
        end
    end

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

    always @(*)
        if (f_past_valid && f_past_hold)
            assume (!hold);

    // The master's byte interface, as Tutorial 24 proved it: a byte is taken only
    // when none is on the wire, and each byte taken brings exactly one rx_valid.
    // Reset, which also ends an open stream, forgets the byte on the wire.
    reg f_in_flight = 1'b0;
    always @(posedge clk)
        if (rst || closing)
            f_in_flight <= 1'b0;
        else if (sent)
            f_in_flight <= 1'b1;
        else if (m_rx_valid)
            f_in_flight <= 1'b0;

    always @(*) begin
        if (rst || closing || f_in_flight)
            assume (!m_ready);
        if (rst || closing || !f_in_flight)
            assume (!m_rx_valid);
    end

    // A read stalls for as long as the flash takes, so there is no limit on
    // stalls: MAX_STALL is 0. Once taken, a request is answered on the next clock.
    wire [3:0] f_outstanding;
    wire [7:0] f_waited;
    wire [7:0] f_stalled;

    wb_checker #(
        .AW(22), .DUT_IS_SLAVE(1), .LGDEPTH(4),
        .MAX_OUTSTANDING(1), .MAX_WAIT(1), .MAX_STALL(0)
    ) f_bus (
        .clk(clk), .rst(rst),
        .cyc(cyc), .stb(stb), .we(we), .adr(adr), .sel(4'hF), .dat_w(32'd0),
        .ack(ack), .err(err), .stall(stall),
        .outstanding(f_outstanding), .waited(f_waited), .stalled(f_stalled)
    );

    // The last request taken, to check its answer.
    reg        f_was_write = 1'b0;
    reg [31:0] f_word_q;
    always @(posedge clk) begin
        f_was_write <= accept && we;
        f_word_q    <= buf_word;
    end

    always @(*) begin
        if (f_past_valid && !f_past_rst && f_past_cyc) begin
            assert (f_outstanding == {3'd0, ack || err});
            // A write is never acknowledged, and a read never refused.
            if (ack || err)
                assert (err == f_was_write);
            // A read is answered with the word the slave held for its address.
            if (ack)
                assert (dat_r == f_word_q);
        end else if (f_past_valid) begin
            assert (!ack && !err);
        end
        // A read is only taken when the word for its address is in.
        if (f_past_valid && !rst && accept && !we)
            assert (buf_valid && buf_addr == adr);
        // A byte waits for the master only while a word is on its way, and
        // none is on the wire then.
        if (f_past_valid && !f_past_rst && !busy)
            assert (!tx_full && !f_in_flight);
        if (f_past_valid && !f_past_rst && tx_full)
            assert (!f_in_flight);
    end

    always @(posedge clk) begin
        if (f_past_valid && !f_past_rst && !rst) begin
            // A word in the buffer changes only when the engine finishes one.
            if (buf_valid != $past(buf_valid) || buf_addr != $past(buf_addr)
                || buf_word != $past(buf_word))
                assert ($past(busy && m_rx_valid && index == 3'd7));
            // A new command starts at byte 0, and a stream that goes on at byte 4.
            if ($past(start))
                assert (busy && tx_full && (index == 3'd0 || index == 3'd4));
        end
    end

    always @(*) begin
        if (f_past_valid && !rst) begin
            cover (ack);                     // a read answered
            cover (err);                     // a write refused
            cover (cyc && stb && stall);     // a read waiting for the flash
            cover (closing);                 // an open stream ended
            cover (busy && index == 3'd4 && tx_full && !cs_n);  // a stream carried on
        end
    end
`endif

endmodule
