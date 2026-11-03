// The rules of a Wishbone B4 pipelined bus, for formal verification only.
//
// Attach one of these to every bus port of the design being proved. It watches
// the port and never drives it. The rules split into the master's rules and the
// slave's rules, and DUT_IS_SLAVE picks which side is being proved:
//
//   DUT_IS_SLAVE = 1  the design is the slave on this port.
//                     The master's rules are assumed, the slave's are asserted.
//   DUT_IS_SLAVE = 0  the design is the master on this port.
//                     The master's rules are asserted, the slave's are assumed.
//
// Some rules are this course's choices, stricter than the spec allows, and are
// marked so. The proof starts in reset.
module wb_checker #(
    parameter AW              = 30,  // address width: word address
    parameter DUT_IS_SLAVE    = 1,
    parameter LGDEPTH         = 4,   // width of the outstanding count
    parameter MAX_OUTSTANDING = 4,   // the slave never holds more requests than this
    parameter MAX_WAIT        = 4,   // nor waits this many clocks without an answer
    parameter MAX_STALL       = 4    // nor stalls a request this many clocks. 0: no limit
) (
    input  wire               clk,
    input  wire               rst,
    input  wire               cyc,
    input  wire               stb,
    input  wire               we,
    input  wire [AW-1:0]      adr,
    input  wire [3:0]         sel,
    input  wire [31:0]        dat_w,
    input  wire               ack,
    input  wire               err,
    input  wire               stall,
    output reg  [LGDEPTH-1:0] outstanding = 0,  // requests accepted and not yet answered
    output reg  [7:0]         waited      = 0,  // clocks since the last answer, with one due
    output reg  [7:0]         stalled     = 0   // clocks the request on the bus has stalled
);

    // The previous clock's values. Everything below is written with these, so
    // that each rule is a plain expression about two neighbouring clocks.
    reg          past_valid = 1'b0;
    reg          past_rst;
    reg          past_cyc;
    reg          past_stb;
    reg          past_we;
    reg          past_stall;
    reg [AW-1:0] past_adr;
    reg [3:0]    past_sel;
    reg [31:0]   past_dat_w;

    always @(posedge clk) begin
        past_valid <= 1'b1;
        past_rst   <= rst;
        past_cyc   <= cyc;
        past_stb   <= stb;
        past_we    <= we;
        past_stall <= stall;
        past_adr   <= adr;
        past_sel   <= sel;
        past_dat_w <= dat_w;
    end

    // A request is accepted at an edge with cyc and stb high and stall low.
    // An answer is an ack or an err while cyc is high. Answers come back in the
    // order that the requests went out, so a count is all the bookkeeping needed.
    wire request = cyc && stb && !stall;
    wire answer  = cyc && (ack || err);

    always @(posedge clk) begin
        if (rst || !cyc)
            outstanding <= 0;        // dropping cyc abandons whatever was in flight
        else if (request && !answer)
            outstanding <= outstanding + 1'b1;
        else if (answer && !request)
            outstanding <= outstanding - 1'b1;

        if (rst || !cyc || answer || outstanding == 0)
            waited <= 0;
        else if (waited != 8'hFF)
            waited <= waited + 1'b1;

        if (rst || !(cyc && stb && stall))
            stalled <= 0;
        else if (stalled != 8'hFF)
            stalled <= stalled + 1'b1;
    end

    // A request that stalled on the last clock, in a cycle that is still going.
    wire held = past_valid && !past_rst && past_cyc && past_stb && past_stall && cyc && !rst;

    // ---- The master's rules ----
    // M1. cyc is low on the clock after reset.
    wire m_reset = !(past_valid && past_rst) || !cyc;
    // M2. stb is only high inside a cycle.
    wire m_stb   = !stb || cyc;
    // M3. A stalled request stays on the bus, unchanged, until it is accepted.
    //     The master may still drop cyc to abandon the whole cycle.
    wire m_hold  = !held || (stb && we == past_we && adr == past_adr && sel == past_sel &&
                             (!past_we || dat_w == past_dat_w));

    // ---- The slave's rules ----
    // S1. No answer on the clock after reset, or after a clock with cyc low.
    wire s_idle  = !(past_valid && (past_rst || !past_cyc)) || (!ack && !err);
    // S2. Never ack and err together.
    wire s_one   = !(ack && err);
    // S3. No answer without a request outstanding. A request counts from the
    //     edge that accepts it, so an answer can come on the next clock at the
    //     earliest. The spec also allows an answer in the same clock. This course
    //     does not, so that every slave's answer comes from a flip-flop.
    wire s_asked = !cyc || outstanding != 0 || (!ack && !err);
    // S4. A bounded number of requests in flight.
    wire s_depth = outstanding <= MAX_OUTSTANDING;
    // S5. An answer is never more than MAX_WAIT clocks away. A slave that never
    //     answers would hang the master forever.
    wire s_wait  = waited < MAX_WAIT;
    // S6. A request is never stalled for MAX_STALL clocks.
    wire s_stall = (MAX_STALL == 0) || (stalled < MAX_STALL);

    always @(*) begin
        // The first clock is in reset, so nothing is checked until the second.
        if (!past_valid)
            assume (rst);
        else if (DUT_IS_SLAVE) begin
            assume (m_reset);
            assume (m_stb);
            assume (m_hold);
            assert (s_idle);
            assert (s_one);
            assert (s_asked);
            assert (s_depth);
            assert (s_wait);
            assert (s_stall);
        end else begin
            assert (m_reset);
            assert (m_stb);
            assert (m_hold);
            assume (s_idle);
            assume (s_one);
            assume (s_asked);
            assume (s_depth);
            assume (s_wait);
            assume (s_stall);
        end
    end

endmodule
