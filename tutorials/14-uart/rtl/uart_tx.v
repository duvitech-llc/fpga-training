// Sends bytes in 8N1 format, least significant bit first. Each bit lasts
// CLKS_PER_BIT clocks, which must be at least 4.
module uart_tx #(
    parameter CLKS_PER_BIT = 16
) (
    input  wire       clk,
    input  wire       rst,       // synchronous, active high
    input  wire       tx_valid,  // tx_data holds a byte to send
    input  wire [7:0] tx_data,
    output wire       tx_ready,  // a byte moves when tx_valid and tx_ready are both high
    output reg        tx         // the serial line, high when idle
);

    localparam [1:0] IDLE  = 2'd0;
    localparam [1:0] START = 2'd1;
    localparam [1:0] DATA  = 2'd2;
    localparam [1:0] STOP  = 2'd3;

    localparam integer LAST = CLKS_PER_BIT - 1;

    reg [1:0]                      state;
    reg [$clog2(CLKS_PER_BIT)-1:0] timer;      // clocks left in this bit
    reg [3:0]                      bits_left;  // data bits still to finish
    reg [7:0]                      shifter;

    assign tx_ready = !rst && (state == IDLE);

    always @(posedge clk) begin
        if (rst) begin
            state     <= IDLE;
            tx        <= 1'b1;
            timer     <= 0;
            bits_left <= 4'd0;
            shifter   <= 8'd0;
        end else if (state == IDLE) begin
            if (tx_valid) begin
                state     <= START;
                tx        <= 1'b0;
                timer     <= LAST[$clog2(CLKS_PER_BIT)-1:0];
                bits_left <= 4'd8;
                shifter   <= tx_data;
            end
        end else if (timer != 0) begin
            timer <= timer - 1'b1;
        end else begin
            // The current bit has lasted CLKS_PER_BIT clocks.
            timer <= LAST[$clog2(CLKS_PER_BIT)-1:0];
            case (state)
                START: begin
                    state <= DATA;
                    tx    <= shifter[0];
                end
                DATA: begin
                    shifter   <= {1'b0, shifter[7:1]};
                    bits_left <= bits_left - 1'b1;
                    if (bits_left == 4'd1) begin
                        state <= STOP;
                        tx    <= 1'b1;
                    end else begin
                        tx <= shifter[1];
                    end
                end
                default: state <= IDLE;  // the end of STOP
            endcase
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

    // Records the accepted byte, and counts clocks from the start of the frame.
    reg [7:0]  f_byte;
    reg [15:0] f_clocks;
    always @(posedge clk) begin
        f_clocks <= f_clocks + 1'b1;
        if (tx_valid && tx_ready) begin
            f_byte   <= tx_data;
            f_clocks <= 16'd0;
        end
    end

    // Which of the frame's ten bits is on the line.
    wire [3:0] f_bit = (state == START) ? 4'd0 :
                       (state == STOP)  ? 4'd9 : 4'd9 - bits_left;

    always @(posedge clk) begin
        if (past_valid) begin
            assert (timer < CLKS_PER_BIT);

            // What the line and the bit counter must be in each state. All four
            // codes of state are legal, so there is no illegal state to rule out.
            case (state)
                IDLE: begin
                    assert (tx);
                    assert (bits_left == 0);
                end
                START: begin
                    assert (!tx);
                    assert (bits_left == 8);
                    assert (shifter == f_byte);
                end
                DATA: begin
                    assert (bits_left >= 1 && bits_left <= 8);
                    assert (shifter == (f_byte >> (8 - bits_left)));
                    assert (tx == shifter[0]);
                end
                STOP: begin
                    assert (tx);
                    assert (bits_left == 0);
                end
            endcase

            // Every bit lasts CLKS_PER_BIT clocks, so a frame lasts ten of them.
            if (state != IDLE)
                assert (f_clocks == f_bit * CLKS_PER_BIT + (CLKS_PER_BIT - 1 - timer));

            // The line only changes at the end of a bit.
            if (!$past(rst) && $past(state) != IDLE && $past(timer) != 0)
                assert (tx == $past(tx));

            // tx_ready is high exactly when a frame can start.
            assert (tx_ready == (!rst && state == IDLE));

            // A frame starts only after a transfer.
            if (!$past(rst) && $past(state) == IDLE)
                assert ((state == START) == $past(tx_valid));
        end
    end

    // Shows that a whole frame can happen, so the proof is not vacuous.
    always @(posedge clk)
        cover (past_valid && !rst && state == STOP && timer == 0);
`endif

endmodule
