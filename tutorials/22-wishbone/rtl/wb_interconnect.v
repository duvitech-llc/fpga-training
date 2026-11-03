// One Wishbone B4 pipelined master to N slaves.
//
// Each slave owns the byte addresses where (address & MASK) == BASE, with its own
// 32-bit BASE and MASK packed into the parameters, slave 0 in the lowest bits.
// The regions must not overlap. A request that falls in no region gets err on
// the next clock from a default responder inside this module, so a bad address
// can never hang the master, and the master can tell it went wrong.
//
// Answers must reach the master in the order that the requests went out. Two
// slaves could answer out of order, so a request to a different slave from the
// one that still owes answers stalls until those answers are in.
//
// adr is a word address, bits [31:2] of the byte address, on both sides. cyc,
// we, adr, sel and dat_w go to every slave. Only stb is decoded.
module wb_interconnect #(
    parameter N      = 2,
    parameter [32*N-1:0] BASE = {32'h2000_0000, 32'h1000_0000},
    parameter [32*N-1:0] MASK = {32'hFFFF_FFF0, 32'hFFFF_FFF0},
    parameter LGPEND = 3   // width of the count of answers owed: at most 2**LGPEND - 2
) (
    input  wire            clk,
    input  wire            rst,       // synchronous, active high
    // Slave port, to the master
    input  wire            m_cyc,
    input  wire            m_stb,
    input  wire            m_we,
    input  wire [29:0]     m_adr,
    input  wire [3:0]      m_sel,
    input  wire [31:0]     m_dat_w,
    output wire            m_ack,
    output wire            m_err,     // from a slave, or for an address nobody owns
    output wire            m_stall,
    output wire [31:0]     m_dat_r,
    // Master ports, to the slaves. Slave i uses bit i of each vector, and bits
    // [32*i+31:32*i] of s_dat_r.
    output wire            s_cyc,
    output wire [N-1:0]    s_stb,
    output wire            s_we,
    output wire [29:0]     s_adr,
    output wire [3:0]      s_sel,
    output wire [31:0]     s_dat_w,
    input  wire [N-1:0]    s_ack,
    input  wire [N-1:0]    s_err,
    input  wire [N-1:0]    s_stall,
    input  wire [32*N-1:0] s_dat_r
);

    // The address decoder: hit[i] is high when slave i owns the address. The low
    // two bits of BASE and MASK are byte offsets, and are not compared.
    wire [N-1:0] hit;
    genvar i;
    generate
        for (i = 0; i < N; i = i + 1) begin : decode
            assign hit[i] = (m_adr & MASK[32*i+2 +: 30]) == BASE[32*i+2 +: 30];
        end
    endgenerate

    // Where this request goes, one-hot. Bit N is the default responder.
    wire [N:0] dest = {~|hit, hit};

    reg [N:0]        owner;    // where the requests still owed an answer went
    reg [LGPEND-1:0] pending;  // how many answers are owed
    reg              def_err;  // the default responder's answer

    // A request may go out unless answers are owed by somewhere else, or the
    // count is full. go does not depend on stb.
    wire elsewhere = (pending != 0) && (dest != owner);
    wire full      = (pending == {LGPEND{1'b1}} - 1'b1);
    wire go        = !elsewhere && !full;

    assign s_cyc   = m_cyc;
    assign s_stb   = (m_cyc && m_stb && go) ? hit : {N{1'b0}};
    assign s_we    = m_we;
    assign s_adr   = m_adr;
    assign s_sel   = m_sel;
    assign s_dat_w = m_dat_w;

    // Stall when the interconnect holds the request back, or the slave does.
    // The default responder never stalls.
    assign m_stall = !go || |(hit & s_stall);

    // Answers are only taken from the owner. Anyone else has nothing to answer.
    assign m_ack = |(s_ack & owner[N-1:0]);
    assign m_err = |(s_err & owner[N-1:0]) || def_err;

    // The read data, from the owner: each slave's data masked by its owner bit,
    // then ORed together, one stage per slave.
    wire [32*(N+1)-1:0] dat_or;
    assign dat_or[31:0] = 32'd0;
    generate
        for (i = 0; i < N; i = i + 1) begin : read_mux
            assign dat_or[32*(i+1) +: 32] = dat_or[32*i +: 32] |
                                            (s_dat_r[32*i +: 32] & {32{owner[i]}});
        end
    endgenerate
    assign m_dat_r = dat_or[32*N +: 32];

    wire request = m_cyc && m_stb && !m_stall;
    wire answer  = m_cyc && (m_ack || m_err);

    always @(posedge clk) begin
        if (rst || !m_cyc) begin
            pending <= 0;
            def_err <= 1'b0;
            owner   <= {(N+1){1'b0}};
        end else begin
            if (request && !answer)
                pending <= pending + 1'b1;
            else if (answer && !request)
                pending <= pending - 1'b1;
            if (request)
                owner <= dest;
            def_err <= request && dest[N];
        end
    end

`ifdef FORMAL
    // The previous clock, for the checks below. The checker keeps its own copy.
    reg f_past_valid = 1'b0;
    reg f_past_rst, f_past_cyc, f_past_stb;
    always @(posedge clk) begin
        f_past_valid <= 1'b1;
        f_past_rst   <= rst;
        f_past_cyc   <= m_cyc;
        f_past_stb   <= m_stb;
    end

    // One checker on the master's port, where this module is the slave, and one
    // on each slave's port, where it is the master.
    localparam F_WAIT = 4;  // what each slave is assumed to promise
    localparam F_DEPTH = 4;

    wire [3:0] f_m_outstanding;
    wire [7:0] f_m_waited;
    wire [7:0] f_m_stalled;
    wire [4*N-1:0] f_s_outstanding;
    wire [8*N-1:0] f_s_waited;
    wire [8*N-1:0] f_s_stalled;

    wb_checker #(
        .AW(30), .DUT_IS_SLAVE(1), .LGDEPTH(4),
        .MAX_OUTSTANDING(F_DEPTH), .MAX_WAIT(F_WAIT), .MAX_STALL(0)
    ) f_master_port (
        .clk(clk), .rst(rst),
        .cyc(m_cyc), .stb(m_stb), .we(m_we), .adr(m_adr), .sel(m_sel), .dat_w(m_dat_w),
        .ack(m_ack), .err(m_err), .stall(m_stall),
        .outstanding(f_m_outstanding), .waited(f_m_waited), .stalled(f_m_stalled)
    );

    genvar g;
    generate
        for (g = 0; g < N; g = g + 1) begin : f_slave
            wb_checker #(
                .AW(30), .DUT_IS_SLAVE(0), .LGDEPTH(4),
                .MAX_OUTSTANDING(F_DEPTH), .MAX_WAIT(F_WAIT), .MAX_STALL(F_WAIT)
            ) f_port (
                .clk(clk), .rst(rst),
                .cyc(s_cyc), .stb(s_stb[g]), .we(s_we), .adr(s_adr), .sel(s_sel),
                .dat_w(s_dat_w), .ack(s_ack[g]), .err(s_err[g]), .stall(s_stall[g]),
                .outstanding(f_s_outstanding[4*g +: 4]), .waited(f_s_waited[8*g +: 8]),
                .stalled(f_s_stalled[8*g +: 8])
            );
        end
    endgenerate

    // The map must not overlap, or two slaves would take one request.
    always @(*)
        assert ((hit & (hit - 1'b1)) == 0);

    // Induction needs the counts tied to this module's state.
    always @(*) begin
        if (!f_past_valid) begin
            // The first clock is in reset, and nothing has been loaded yet.
        end else if (!f_past_rst && f_past_cyc) begin
            assert (f_m_outstanding == {{(4-LGPEND){1'b0}}, pending});
            assert (pending == 0 || owner != 0);
            assert (owner == 0 || (owner & (owner - 1'b1)) == 0);
            if (owner[N])
                assert (pending == {{(LGPEND-1){1'b0}}, def_err});
            else
                assert (!def_err);
            if (pending == 0)
                assert (f_m_waited == 0);
        end else begin
            assert (pending == 0 && !def_err && f_m_outstanding == 0);
        end
    end

    generate
        for (g = 0; g < N; g = g + 1) begin : f_count
            always @(*) begin
                if (!f_past_valid) begin
                    // Nothing loaded yet.
                end else if (owner[g])
                    assert (f_s_outstanding[4*g +: 4] == {{(4-LGPEND){1'b0}}, pending});
                else
                    assert (f_s_outstanding[4*g +: 4] == 0);
                if (f_past_valid && owner[g] && pending != 0)
                    assert (f_m_waited == f_s_waited[8*g +: 8]);
            end
        end
    endgenerate

    // These must be reachable, or an assumption has ruled them out.
    reg [N:0] f_answered = 0;  // which targets have answered
    always @(posedge clk) begin
        if (rst || !m_cyc)
            f_answered <= 0;
        else if (answer)
            f_answered <= f_answered | owner;
    end

    always @(*) begin
        if (f_past_valid && !rst) begin
            cover (m_err && owner[N]);                         // an unmapped address
            cover (m_ack && owner[1] && f_m_outstanding == 2); // two in flight to slave 1
            cover (m_cyc && m_stb && elsewhere);               // held back for ordering
            cover (f_answered == {(N+1){1'b1}} && m_cyc);      // all three in one cycle
            cover (m_err && owner[0]);                         // a slave's own err
        end
    end
`endif

endmodule
