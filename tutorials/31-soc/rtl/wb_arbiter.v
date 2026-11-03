// N Wishbone B4 pipelined masters sharing one bus, in front of wb_interconnect.
//
// Tutorial 8's round-robin arbiter picks the owner, but only between Wishbone
// cycles. Once a master is granted, it keeps the bus for the whole of its cycle,
// for as long as its cyc stays high. A cycle may have requests in flight, and
// their answers carry nothing that says whose they are, so the bus cannot change
// hands until they are all in. A master that drops cyc has either had every
// answer, or has abandoned the cycle.
//
// When the owner drops cyc, the bus stays with it for that one clock, so that
// the slaves see cyc low between two owners. A slave may still be about to answer
// a request from an abandoned cycle, and cyc low is what tells it not to. So a
// change of owner costs one clock. A master that is alone on the bus loses
// nothing: the clock it does not use is its own.
//
// Master i uses bit i of each 1-bit vector, bits [30i+29:30i] of m_adr, and so
// on, as in wb_interconnect. A master that is not granted sees stall high and
// no answers. m_dat_r goes to every master, and means something only with ack.
//
// Paths: grant is combinational from m_cyc, as in Tutorial 8, so a master alone
// on the bus is granted in the first clock of its cycle. s_cyc, s_stb and the
// request come through logic from m_cyc, and m_stall from s_stall.
module wb_arbiter #(
    parameter N = 2      // at least 2
) (
    input  wire            clk,
    input  wire            rst,      // synchronous, active high
    // Slave ports, one per master
    input  wire [N-1:0]    m_cyc,
    input  wire [N-1:0]    m_stb,
    input  wire [N-1:0]    m_we,
    input  wire [30*N-1:0] m_adr,
    input  wire [4*N-1:0]  m_sel,
    input  wire [32*N-1:0] m_dat_w,
    output wire [N-1:0]    m_ack,
    output wire [N-1:0]    m_err,
    output wire [N-1:0]    m_stall,
    output wire [31:0]     m_dat_r,
    // Master port, to the interconnect
    output wire            s_cyc,
    output wire            s_stb,
    output wire            s_we,
    output wire [29:0]     s_adr,
    output wire [3:0]      s_sel,
    output wire [31:0]     s_dat_w,
    input  wire            s_ack,
    input  wire            s_err,
    input  wire            s_stall,
    input  wire [31:0]     s_dat_r
);

    // active: the owner had cyc high on the last clock, so its cycle may still be
    // going. The bus stays with it until it has dropped cyc for a clock.
    reg         active;
    reg [N-1:0] owner;

    // Tutorial 8's arbiter only sees requests between cycles. While a cycle runs
    // its request input is zero, so its mask holds, and the next pick starts from
    // the master after the last owner.
    wire [N-1:0] rr_grant;

    rr_arbiter #(.N(N)) u_rr (
        .clk(clk), .rst(rst),
        .req(active ? {N{1'b0}} : m_cyc),
        .grant(rr_grant)
    );

    wire [N-1:0] grant = rst ? {N{1'b0}} : active ? owner : rr_grant;

    always @(posedge clk) begin
        if (rst) begin
            active <= 1'b0;
            owner  <= {N{1'b0}};
        end else begin
            active <= |(grant & m_cyc);
            owner  <= grant;
        end
    end

    // The granted master's request, by AND and OR, as in wb_interconnect's read mux.
    wire [30*(N+1)-1:0] adr_or;
    wire [4*(N+1)-1:0]  sel_or;
    wire [32*(N+1)-1:0] dat_or;
    assign adr_or[29:0] = 30'd0;
    assign sel_or[3:0]  = 4'd0;
    assign dat_or[31:0] = 32'd0;

    genvar i;
    generate
        for (i = 0; i < N; i = i + 1) begin : request_mux
            assign adr_or[30*(i+1) +: 30] = adr_or[30*i +: 30] | (m_adr[30*i +: 30] & {30{grant[i]}});
            assign sel_or[4*(i+1) +: 4]   = sel_or[4*i +: 4] | (m_sel[4*i +: 4] & {4{grant[i]}});
            assign dat_or[32*(i+1) +: 32] = dat_or[32*i +: 32] | (m_dat_w[32*i +: 32] & {32{grant[i]}});
        end
    endgenerate

    assign s_cyc   = |(grant & m_cyc);
    assign s_stb   = |(grant & m_stb);
    assign s_we    = |(grant & m_we);
    assign s_adr   = adr_or[30*N +: 30];
    assign s_sel   = sel_or[4*N +: 4];
    assign s_dat_w = dat_or[32*N +: 32];

    assign m_stall = ~grant | {N{s_stall}};
    assign m_ack   = grant & {N{s_ack}};
    assign m_err   = grant & {N{s_err}};
    assign m_dat_r = s_dat_r;

`ifdef FORMAL
    // Read rr_arbiter.v and fixed_arbiter.v without -formal, so that Tutorial 8's
    // own assumption does not apply here. That assumption holds a request until it
    // is granted, and here requests are hidden from it while a cycle runs.

    reg f_past_valid = 1'b0;
    reg f_past_rst   = 1'b1;
    always @(posedge clk) begin
        f_past_valid <= 1'b1;
        f_past_rst   <= rst;
    end

    // ---- The bus rules: Tutorial 22's checker on every port ----
    // Each master is assumed to keep the master's rules. The slave behind is
    // assumed to answer within 4 clocks and stall for fewer than 4.
    localparam F_LIMIT = 4;

    wire [4*N-1:0] f_m_outstanding;
    wire [8*N-1:0] f_m_waited;
    wire [8*N-1:0] f_m_stalled;
    wire [3:0]     f_s_outstanding;
    wire [7:0]     f_s_waited;
    wire [7:0]     f_s_stalled;

    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : f_master
            wb_checker #(
                .AW(30), .DUT_IS_SLAVE(1), .LGDEPTH(4),
                .MAX_OUTSTANDING(F_LIMIT), .MAX_WAIT(F_LIMIT), .MAX_STALL(0)
            ) f_port (
                .clk(clk), .rst(rst),
                .cyc(m_cyc[g]), .stb(m_stb[g]), .we(m_we[g]), .adr(m_adr[30*g +: 30]),
                .sel(m_sel[4*g +: 4]), .dat_w(m_dat_w[32*g +: 32]),
                .ack(m_ack[g]), .err(m_err[g]), .stall(m_stall[g]),
                .outstanding(f_m_outstanding[4*g +: 4]), .waited(f_m_waited[8*g +: 8]),
                .stalled(f_m_stalled[8*g +: 8])
            );
        end
    endgenerate

    wb_checker #(
        .AW(30), .DUT_IS_SLAVE(0), .LGDEPTH(4),
        .MAX_OUTSTANDING(F_LIMIT), .MAX_WAIT(F_LIMIT), .MAX_STALL(F_LIMIT)
    ) f_slave (
        .clk(clk), .rst(rst),
        .cyc(s_cyc), .stb(s_stb), .we(s_we), .adr(s_adr), .sel(s_sel), .dat_w(s_dat_w),
        .ack(s_ack), .err(s_err), .stall(s_stall),
        .outstanding(f_s_outstanding), .waited(f_s_waited), .stalled(f_s_stalled)
    );

    // ---- Each master holds the bus for a bounded time ----
    // Fairness in clocks needs a promise from the masters: none keeps cyc high
    // for more than F_MAXCYC clocks in a row while it owns the bus. A master that
    // never let go would starve the others under any arbiter.
    localparam F_MAXCYC = 6;

    reg [7:0] f_held [0:N-1];   // clocks in a row that master i has owned the bus with cyc high
    integer k;
    initial
        for (k = 0; k < N; k = k + 1)
            f_held[k] = 8'd0;

    generate
        for (g = 0; g < N; g = g + 1) begin : f_hold
            always @(posedge clk) begin
                if (rst || !(grant[g] && m_cyc[g]))
                    f_held[g] <= 8'd0;
                else if (f_held[g] != 8'hFF)
                    f_held[g] <= f_held[g] + 1'b1;
            end
            always @(*)
                if (f_past_valid)
                    assume (!(grant[g] && m_cyc[g]) || f_held[g] < F_MAXCYC);
        end
    endgenerate

    // ---- What the arbiter promises ----
    always @(*) begin
        if (f_past_valid) begin
            // At most one master owns the bus.
            assert ((grant & (grant - 1'b1)) == 0);
            if (rst)
                assert (grant == 0);
            // A cycle is never interrupted: while the owner's cycle runs, the
            // grant does not move.
            if (active && !rst)
                assert (grant == owner && owner != 0);
            // Nobody is left waiting while the bus is free.
            if (!rst && !active && m_cyc != 0)
                assert (grant != 0);
        end
    end

    // Induction: the counts on every port agree with who owns the bus.
    generate
        for (g = 0; g < N; g = g + 1) begin : f_link
            always @(*) begin
                if (f_past_valid && !f_past_rst) begin
                    if (active && owner[g]) begin
                        assert (f_m_outstanding[4*g +: 4] == f_s_outstanding);
                        if (f_s_outstanding != 0)
                            assert (f_m_waited[8*g +: 8] == f_s_waited);
                    end else begin
                        assert (f_m_outstanding[4*g +: 4] == 0);
                        assert (f_held[g] == 0 || (active && owner[g]));
                    end
                end
            end
        end
    endgenerate

    always @(*) begin
        if (f_past_valid && !f_past_rst) begin
            if (!active)
                assert (f_s_outstanding == 0);
            assert ((owner & (owner - 1'b1)) == 0);
        end
        if (f_past_valid && f_past_rst)
            assert (!active && f_s_outstanding == 0);
    end

    // ---- Fairness ----
    // The solver picks any one master to watch. While it waits with cyc high,
    // count the cycles granted to anyone else, and the clocks it has waited.
    (* anyconst *) reg [$clog2(N)-1:0] f_watched;
    always @(*)
        assume (f_watched < N);

    wire f_waiting = m_cyc[f_watched] && !grant[f_watched];
    wire f_start   = !active && |(grant & m_cyc);   // a cycle begins on this clock

    reg [7:0] f_wait   = 8'd0;   // clocks waited
    reg [3:0] f_others = 4'd0;   // other masters' cycles begun while it waited
    always @(posedge clk) begin
        if (rst || !f_waiting) begin
            f_wait   <= 8'd0;
            f_others <= 4'd0;
        end else begin
            if (f_wait != 8'hFF)
                f_wait <= f_wait + 1'b1;
            if (f_start && f_others != 4'hF)
                f_others <= f_others + 1'b1;
        end
    end

    // The bounds. In cycles, Tutorial 8's N-1, with no assumption about how long
    // a cycle is. In clocks, each of those N-1 cycles plus its clock of cyc low.
    // f_wait holds the whole wait on the clock after it ends, so the bound is on
    // the total. The cover below shows the total is reached.
    always @(*) begin
        if (f_past_valid && !rst) begin
            assert (f_others + (f_waiting && f_start ? 1 : 0) <= N - 1);
            assert (f_wait <= (N - 1) * (F_MAXCYC + 1));
        end
    end

    // ---- These must be reachable ----
    reg [N-1:0] f_owned = 0;      // which masters have owned the bus since reset
    reg         f_switched = 1'b0; // a master took the bus straight after another's cycle
    always @(posedge clk) begin
        if (rst) begin
            f_owned    <= 0;
            f_switched <= 1'b0;
        end else begin
            f_owned <= f_owned | (grant & m_cyc);
            if (f_start && !(grant & owner) && owner != 0)
                f_switched <= 1'b1;
        end
    end

    always @(*) begin
        if (f_past_valid && !rst) begin
            cover (f_owned == {N{1'b1}});                    // every master has had the bus
            cover (f_switched && s_ack);                     // a change of owner, then an answer
            cover (f_wait == (N - 1) * (F_MAXCYC + 1));      // the longest wait
            cover (f_others == N - 1 && f_waiting);          // N-1 other cycles before it
            cover (m_err[N-1] && f_owned[0]);                // an err to the last master
            cover (f_m_outstanding[4*(N-1) +: 4] == 2);      // two in flight from the last master
        end
    end
`endif

endmodule
