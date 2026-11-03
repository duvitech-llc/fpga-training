// An SPI master. It sends one byte and receives one byte at the same time, most
// significant bit first, in any of the four SPI modes.
//
// Each half period of SCLK lasts clk_div + 1 clocks, so SCLK runs at
// clk / (2 * (clk_div + 1)). cpol is read only while CS is high. cpha and clk_div
// are read when a byte is accepted. tx_last raises CS after that byte. Without
// it CS stays low and the master waits, with SCLK idle, for the next byte.
module spi_master #(
    parameter DIV_WIDTH = 8
) (
    input  wire                 clk,
    input  wire                 rst,       // synchronous, active high
    input  wire                 cpol,      // the level of SCLK while idle
    input  wire                 cpha,      // 0: sample on the leading edge, 1: on the trailing edge
    input  wire [DIV_WIDTH-1:0] clk_div,   // clocks per half period of SCLK, minus one
    input  wire                 tx_valid,  // tx_data holds a byte to send
    input  wire [7:0]           tx_data,
    input  wire                 tx_last,   // raise CS after this byte
    output wire                 tx_ready,  // a byte moves when tx_valid and tx_ready are both high
    output reg                  rx_valid,  // high for one clock when rx_data has a new byte
    output reg  [7:0]           rx_data,
    output reg                  sclk,
    output reg                  mosi,
    input  wire                 miso,
    output reg                  cs_n       // chip select, active low
);

    localparam [1:0] IDLE   = 2'd0;  // CS high
    localparam [1:0] SHIFT  = 2'd1;  // moving a byte
    localparam [1:0] HOLD   = 2'd2;  // CS low, waiting for the next byte
    localparam [1:0] FINISH = 2'd3;  // CS low for half a period after the last edge

    reg [1:0]           state;
    reg [DIV_WIDTH-1:0] timer;   // clocks left in this half period
    reg [DIV_WIDTH-1:0] div_r;
    reg [3:0]           edges;   // SCLK edges so far in this byte
    reg                 cpha_r;
    reg                 last_r;

    wire [7:0] shift_q;
    wire       shift_out;

    wire accept = tx_valid && tx_ready;
    wire tick   = (state == SHIFT) && (timer == 0);  // SCLK changes on this clock
    // An even count of edges so far means the next edge is a leading edge.
    wire sample = tick && (edges[0] == cpha_r);
    wire launch = tick && (edges[0] != cpha_r);

    // Tutorial 3's shift register, unchanged. It loads the byte to send, and each
    // sampling edge shifts the next MISO bit in at q[0] while q[7] moves up a bit.
    shift_reg #(.WIDTH(8)) u_shift (
        .clk(clk), .rst(rst), .load(accept), .en(sample),
        .parallel_in(tx_data), .serial_in(miso), .serial_out(shift_out), .q(shift_q)
    );

    assign tx_ready = !rst && ((state == IDLE && timer == 0 && sclk == cpol) || state == HOLD);

    always @(posedge clk) begin
        if (rst) begin
            state    <= IDLE;
            cs_n     <= 1'b1;
            sclk     <= cpol;
            mosi     <= 1'b0;
            timer    <= 0;
            div_r    <= 0;
            edges    <= 4'd0;
            cpha_r   <= 1'b0;
            last_r   <= 1'b0;
            rx_valid <= 1'b0;
            rx_data  <= 8'd0;
        end else begin
            rx_valid <= 1'b0;
            if (accept) begin
                // CS falls now, and the first edge comes half a period later.
                state  <= SHIFT;
                cs_n   <= 1'b0;
                timer  <= clk_div;
                div_r  <= clk_div;
                edges  <= 4'd0;
                cpha_r <= cpha;
                last_r <= tx_last;
                // With CPHA 0 the first bit must be on MOSI before the first edge.
                if (!cpha)
                    mosi <= tx_data[7];
            end else begin
                case (state)
                    IDLE: begin
                        // A new CPOL moves SCLK, then CS waits another half period.
                        if (sclk != cpol) begin
                            sclk  <= cpol;
                            timer <= clk_div;
                        end else if (timer != 0) begin
                            timer <= timer - 1'b1;
                        end
                    end
                    SHIFT: begin
                        if (timer != 0) begin
                            timer <= timer - 1'b1;
                        end else begin
                            sclk  <= !sclk;
                            edges <= edges + 1'b1;
                            timer <= div_r;
                            // The last edge of a CPHA 0 byte launches nothing.
                            if (launch && edges != 4'd15)
                                mosi <= shift_out;
                            if (edges == 4'd15) begin
                                rx_valid <= 1'b1;
                                // With CPHA 1 the last bit is sampled on this edge.
                                rx_data  <= cpha_r ? {shift_q[6:0], miso} : shift_q;
                                state    <= last_r ? FINISH : HOLD;
                            end
                        end
                    end
                    HOLD: ;  // accept above is the only way out
                    default: begin  // FINISH
                        if (timer != 0) begin
                            timer <= timer - 1'b1;
                        end else begin
                            cs_n  <= 1'b1;
                            state <= IDLE;
                            timer <= div_r;  // CS stays high for half a period
                        end
                    end
                endcase
            end
        end
    end

`ifdef FORMAL
    // $past needs one clock of history before it is meaningful.
    reg past_valid = 1'b0;
    always @(posedge clk)
        past_valid <= 1'b1;

    // Without this the solver may start in any state.
    always @(posedge clk) begin
        if (!past_valid)
            assume (rst);
    end

    // Recorded when a byte is accepted.
    reg [7:0]           f_byte;
    reg                 f_last;
    reg                 f_cpha;
    reg                 f_idle;   // SCLK when CS fell, which was CPOL then
    reg [DIV_WIDTH-1:0] f_div;
    reg [1:0]           f_bytes;  // bytes in this transaction, stops at 3
    // Counted from then on.
    reg [4:0]           f_edges = 5'd0;  // SCLK edges in this byte
    reg [7:0]           f_rx;     // MISO at each sampling edge, newest in bit 0
    reg [DIV_WIDTH:0]   f_age_q;  // see f_age

    always @(posedge clk) begin
        if (tick && !rst)
            f_edges <= f_edges + 1'b1;
        if (sample && !rst)
            f_rx <= {f_rx[6:0], miso};
        if (accept && !rst) begin
            f_byte  <= tx_data;
            f_last  <= tx_last;
            f_cpha  <= cpha;
            f_div   <= clk_div;
            f_edges <= 5'd0;
            if (cs_n) begin
                f_idle  <= sclk;
                f_bytes <= 2'd1;
            end else if (f_bytes != 2'd3) begin
                f_bytes <= f_bytes + 1'b1;
            end
        end
    end

    // Clocks since SCLK or CS last changed, as seen on the pins. 0 means one of
    // them changed on the last clock edge.
    reg f_sclk_q, f_cs_n_q, f_rst_q;  // the values one clock ago
    always @(posedge clk) begin
        f_sclk_q <= sclk;
        f_cs_n_q <= cs_n;
        f_rst_q  <= rst;
    end
    wire f_pin_moved = past_valid && (sclk != f_sclk_q || cs_n != f_cs_n_q);
    wire [DIV_WIDTH:0] f_age = f_pin_moved ? 0 : f_age_q;
    always @(posedge clk)
        f_age_q <= (&f_age) ? f_age : f_age + 1'b1;

    // Where this byte has got to.
    wire [4:0] f_samples = f_cpha ? (f_edges >> 1) : ((f_edges + 1'b1) >> 1);
    wire [7:0] f_mask    = (8'd1 << f_samples[3:0]) - 1'b1;
    wire [7:0] f_shift   = (f_samples == 5'd8) ? f_rx :
                           (((f_byte << f_samples[3:0]) & ~f_mask) | (f_rx & f_mask));
    wire [2:0] f_mosi_bit = f_cpha ? 3'd7 - f_edges[3:1] + (f_edges[0] ? 3'd0 : 3'd1)
                                   : 3'd7 - f_edges[3:1];
    // Did SCLK just move to the level where both ends sample?
    wire f_sampled = past_valid && !f_rst_q && !cs_n && sclk != f_sclk_q
                     && (f_edges[0] != f_cpha);
    // The sample just taken was number f_edges / 2 - 1 (CPHA 1) or f_edges / 2 (CPHA 0).
    wire [3:0] f_k          = f_cpha ? f_edges[4:1] - 1'b1 : f_edges[4:1];
    wire [2:0] f_sample_bit = 3'd7 - f_k[2:0];

    always @(posedge clk) begin
        if (past_valid && !$past(rst)) begin
            // ----- The ports -----

            // SCLK idles at CPOL. While CS is high it only moves to follow CPOL.
            if (cs_n && $past(cs_n) && sclk != $past(sclk))
                assert (sclk == $past(cpol));
            if (cs_n && tx_ready)
                assert (sclk == cpol);
            // CS falls only when a byte is accepted, and SCLK does not move with it.
            if (!cs_n && $past(cs_n)) begin
                assert ($past(accept));
                assert (sclk == $past(sclk));
                assert (sclk == $past(cpol));
            end
            // While CS is low SCLK leaves its idle level only inside a byte, so it
            // is back at the idle level whenever CS can rise or a byte can start.
            if (!cs_n)
                assert (sclk == (f_idle ^ f_edges[0]));

            // CS is held between the bytes of a transaction, and rises only after
            // all 16 edges of a byte that had tx_last.
            if (cs_n && !$past(cs_n)) begin
                assert ($past(f_edges) == 5'd16);
                assert (f_last);
            end

            // Every SCLK level lasts at least clk_div + 1 clocks while CS is low,
            // and exactly that inside a byte. CS rises half a period after the
            // last edge.
            if (!cs_n && !$past(cs_n) && sclk != $past(sclk)) begin
                assert ($past(f_age) >= f_div);
                if (f_edges != 5'd1)
                    assert ($past(f_age) == f_div);
            end
            if (cs_n && !$past(cs_n))
                assert ($past(f_age) == f_div);

            // MOSI holds the right bit, and does not move, on each sampling edge.
            if (f_sampled) begin
                assert (mosi == $past(mosi));
                assert (mosi == f_byte[f_sample_bit]);
            end

            // The byte interface: no byte is taken in the middle of a byte, and
            // each byte gives exactly one rx_valid, with what MISO carried.
            if (!cs_n && f_edges != 5'd16)
                assert (!tx_ready);
            if (rx_valid) begin
                assert (f_edges == 5'd16 && $past(f_edges) == 5'd15);
                assert (rx_data == f_rx);
            end
            if (!rx_valid)
                assert (rx_data == $past(rx_data));
        end

        if (past_valid) begin
            // tx_ready depends on state, not on tx_valid.
            assert (tx_ready == (!rst && ((state == IDLE && timer == 0 && sclk == cpol)
                                          || state == HOLD)));

            // Exactly 16 edges per byte: 8 that launch and 8 that sample.
            assert (f_edges <= 5'd16);

            // ----- Inside, so that induction can succeed -----
            assert (cs_n == (state == IDLE));
            if (!cs_n) begin
                assert (cpha_r == f_cpha);
                assert (div_r == f_div);
                assert (last_r == f_last);
                assert (shift_q == f_shift);
            end
            if (state == SHIFT) begin
                assert (f_edges < 5'd16);
                assert (edges == f_edges[3:0]);
                assert (timer <= div_r);
                if (f_edges != 5'd0)
                    assert (f_age == div_r - timer);
                else
                    assert (f_age >= div_r - timer);
                if (!f_cpha || f_edges != 5'd0)
                    assert (mosi == f_byte[f_mosi_bit]);
            end
            if (state == HOLD || state == FINISH) begin
                assert (f_edges == 5'd16);
                assert (edges == 4'd0);
            end
            if (state == FINISH) begin
                assert (f_last);
                assert (timer <= div_r);
                assert (f_age == div_r - timer);
            end
            if (state == HOLD)
                assert (!f_last);
        end
    end

    // A transaction of two bytes in each mode, a byte at the slowest divider,
    // and a CPOL change between transactions must all be reachable.
    always @(posedge clk) begin
        if (past_valid && !rst && !$past(rst)) begin
            cover (cs_n && !$past(cs_n) && f_bytes == 2 && !f_idle && !f_cpha);
            cover (cs_n && !$past(cs_n) && f_bytes == 2 && !f_idle &&  f_cpha);
            cover (cs_n && !$past(cs_n) && f_bytes == 2 &&  f_idle && !f_cpha);
            cover (cs_n && !$past(cs_n) && f_bytes == 2 &&  f_idle &&  f_cpha);
            cover (rx_valid && rx_data == 8'hA5 && f_div == {DIV_WIDTH{1'b1}});
            cover (!cs_n && $past(cs_n) && sclk != $past(sclk, 3));
        end
    end
`endif

endmodule
