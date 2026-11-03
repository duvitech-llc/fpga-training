// Moore finite state machine that detects 1011 on the serial input d.
// Matches may overlap, so 1011011 gives two matches.
module seq_detect (
    input  wire clk,
    input  wire rst,    // synchronous, active high, overrides en
    input  wire en,     // d is ignored and the state holds when low
    input  wire d,      // serial data, sampled on the rising edge when en is high
    output wire match   // high while the last four bits taken are 1011
);

    // Each state records how much of the pattern has been seen so far.
    localparam [2:0] IDLE     = 3'd0;
    localparam [2:0] GOT_1    = 3'd1;
    localparam [2:0] GOT_10   = 3'd2;
    localparam [2:0] GOT_101  = 3'd3;
    localparam [2:0] GOT_1011 = 3'd4;

    reg [2:0] state;
    reg [2:0] next_state;

    // Next-state logic: combinational, with no clock and no memory.
    always @(*) begin
        case (state)
            IDLE:     next_state = d ? GOT_1    : IDLE;
            GOT_1:    next_state = d ? GOT_1    : GOT_10;
            GOT_10:   next_state = d ? GOT_101  : IDLE;
            GOT_101:  next_state = d ? GOT_1011 : GOT_10;
            GOT_1011: next_state = d ? GOT_1    : GOT_10;  // the last 1 can start a new match
            default:  next_state = IDLE;                   // codes 5 to 7 are never entered
        endcase
    end

    // State register: the only flip-flops in the design.
    always @(posedge clk) begin
        if (rst)
            state <= IDLE;
        else if (en)
            state <= next_state;
    end

    // Moore output: it depends on the state alone, never directly on d.
    assign match = (state == GOT_1011);

`ifdef FORMAL
    reg past_valid = 1'b0;
    always @(posedge clk)
        past_valid <= 1'b1;

    // Without this the solver may start in a state that no reset can lead to.
    always @(posedge clk) begin
        if (!past_valid)
            assume (rst);
    end

    // The last seven bits taken, newest in bit 0. This describes the same
    // behaviour a second way, with no states at all.
    reg [6:0] history;
    always @(posedge clk) begin
        if (rst)
            history <= 7'b0;
        else if (en)
            history <= {history[5:0], d};
    end

    // The state that the most recent bits call for.
    wire [2:0] expected_state = (history[3:0] == 4'b1011) ? GOT_1011 :
                                (history[2:0] == 3'b101)  ? GOT_101  :
                                (history[1:0] == 2'b10)   ? GOT_10   :
                                history[0]                ? GOT_1    :
                                                            IDLE;

    always @(posedge clk) begin
        if (past_valid) begin
            // The property we care about.
            assert (match == (history[3:0] == 4'b1011));

            // A helper: induction needs it to rule out unreachable starts.
            assert (state == expected_state);
        end
    end

    // Cover asks the opposite question: can this ever happen?
    always @(*) begin
        if (past_valid) begin
            cover (match);
            cover (match && history == 7'b1011011);
        end
    end
`endif

endmodule
