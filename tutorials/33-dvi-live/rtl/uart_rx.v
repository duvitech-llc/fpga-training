// Receives bytes in 8N1 format, least significant bit first. Each bit lasts
// CLKS_PER_BIT clocks, which must be at least 4. The sender's clock is unrelated
// to clk, so rx is asynchronous.
module uart_rx #(
    parameter CLKS_PER_BIT = 16
) (
    input  wire       clk,
    input  wire       rst,       // synchronous, active high
    input  wire       rx,        // the serial line, high when idle
    output reg        rx_valid,  // high for one clock when rx_data holds a new byte
    output reg  [7:0] rx_data,   // keeps its value until the next good byte
    output reg        rx_error   // high for one clock when a stop bit was low
);

    localparam [1:0] IDLE  = 2'd0;
    localparam [1:0] START = 2'd1;
    localparam [1:0] DATA  = 2'd2;
    localparam [1:0] STOP  = 2'd3;

    localparam integer LAST = CLKS_PER_BIT - 1;
    // Half a bit, rounded up, less the two clocks that seeing the edge and
    // loading timer use.
    localparam integer HALF = (CLKS_PER_BIT + 1) / 2 - 2;

    reg [1:0]                      state;
    reg [$clog2(CLKS_PER_BIT)-1:0] timer;      // clocks until the next sample
    reg [3:0]                      bits_left;  // data bits still to sample
    reg [7:0]                      shifter;

    // Two-flop synchronizer. Nothing else may read rx or rx_meta. rx_prev is one
    // clock older than rx_sync, so the two together show a falling edge.
    reg rx_meta;
    reg rx_sync;
    reg rx_prev;

    always @(posedge clk) begin
        rx_valid <= 1'b0;
        rx_error <= 1'b0;

        if (rst) begin
            rx_meta   <= 1'b1;
            rx_sync   <= 1'b1;
            rx_prev   <= 1'b1;
            state     <= IDLE;
            timer     <= 0;
            bits_left <= 4'd0;
            shifter   <= 8'd0;
            rx_data   <= 8'd0;
        end else begin
            rx_meta <= rx;
            rx_sync <= rx_meta;
            rx_prev <= rx_sync;

            if (state == IDLE) begin
                if (rx_prev && !rx_sync) begin
                    state <= START;
                    timer <= HALF[$clog2(CLKS_PER_BIT)-1:0];
                end
            end else if (timer != 0) begin
                timer <= timer - 1'b1;
            end else begin
                // timer has reached the middle of a bit, so sample rx_sync.
                timer <= LAST[$clog2(CLKS_PER_BIT)-1:0];
                case (state)
                    START: begin
                        if (rx_sync) begin
                            state <= IDLE;  // high again, so it was only a glitch
                        end else begin
                            state     <= DATA;
                            bits_left <= 4'd8;
                        end
                    end
                    DATA: begin
                        shifter   <= {rx_sync, shifter[7:1]};
                        bits_left <= bits_left - 1'b1;
                        if (bits_left == 4'd1)
                            state <= STOP;
                    end
                    default: begin  // STOP
                        state <= IDLE;
                        if (rx_sync) begin
                            rx_valid <= 1'b1;
                            rx_data  <= shifter;
                        end else begin
                            rx_error <= 1'b1;
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

    // Without this the solver may start in any state. rx stays free, so the
    // proof covers every possible waveform on the line.
    always @(posedge clk) begin
        if (!past_valid)
            assume (rst);
    end

    wire f_sample_stop = !rst && (state == STOP) && (timer == 0);

    always @(posedge clk) begin
        if (past_valid) begin
            assert (timer < CLKS_PER_BIT);

            // The bit counter in each state. All four codes of state are legal,
            // so there is no illegal state to rule out.
            case (state)
                IDLE: begin
                    assert (bits_left == 0);
                end
                START: begin
                    assert (bits_left == 0);
                    assert (timer <= HALF);
                end
                DATA: begin
                    assert (bits_left >= 1 && bits_left <= 8);
                end
                STOP: begin
                    assert (bits_left == 0);
                end
            endcase

            // The line reaches the logic only through both synchronizer flops.
            if (!$past(rst)) begin
                assert (rx_meta == $past(rx));
                assert (rx_sync == $past(rx_meta));
                assert (rx_prev == $past(rx_sync));
            end

            // A frame starts only on a falling edge, and goes on to its data
            // only if the middle of the start bit is still low.
            if (!$past(rst) && $past(state) == IDLE && state == START)
                assert ($past(rx_prev) && !$past(rx_sync));
            if (!$past(rst) && $past(state) == START && state == DATA)
                assert (!$past(rx_sync));

            // A result appears only after sampling a stop bit: valid if it was
            // high and error if it was low. Either way it lasts one clock.
            assert (rx_valid == $past(f_sample_stop && rx_sync));
            assert (rx_error == $past(f_sample_stop && !rx_sync));
            assert (!(rx_valid && rx_error));
            if (rx_valid || rx_error)
                assert (state == IDLE);

            // rx_data changes only with rx_valid.
            if (!$past(rst) && !rx_valid)
                assert (rx_data == $past(rx_data));
        end
    end

    // Show that a good byte, a chosen byte and a framing error can all happen.
    always @(posedge clk) begin
        cover (past_valid && rx_valid);
        cover (past_valid && rx_valid && rx_data == 8'hA5);
        cover (past_valid && rx_error);
    end
`endif

endmodule
