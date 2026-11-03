// wb_gate with Tutorial 22's bus checker on both sides, for formal verification
// only. The master side is the interconnect's port for one slave: the gate is
// the slave there. The slave side goes to the SPI controller or the XIP slave:
// the gate is the master there. go is free, except for the one promise that
// flash_share.v makes and proves: go never falls while a request waits to be
// taken.
module gate_check (
    input  wire        clk,
    input  wire        rst,
    input  wire        go,
    input  wire        m_cyc,
    input  wire        m_stb,
    input  wire        m_we,
    input  wire [29:0] m_adr,
    input  wire [3:0]  m_sel,
    input  wire [31:0] m_dat_w,
    input  wire        s_stall,
    input  wire        s_ack,
    input  wire        s_err
);

    wire m_stall, m_ack, m_err, s_cyc, s_stb;

    wb_gate u_gate (
        .go(go),
        .m_cyc(m_cyc), .m_stb(m_stb), .m_stall(m_stall), .m_ack(m_ack), .m_err(m_err),
        .s_cyc(s_cyc), .s_stb(s_stb), .s_stall(s_stall), .s_ack(s_ack), .s_err(s_err)
    );

    reg f_past_valid = 1'b0;
    reg f_past_waits = 1'b0;     // go and a request not yet taken, on the last clock
    always @(posedge clk) begin
        f_past_valid <= 1'b1;
        f_past_waits <= !rst && go && m_cyc && m_stb && s_stall;
    end

    always @(*) begin
        if (!f_past_valid)
            assume (rst);
        // flash_share's promise.
        if (f_past_waits)
            assume (go);
    end

    // The gate's stalls last as long as go stays low, so there is no limit on
    // stalls. The slave behind answers within 4 clocks.
    wire [3:0] f_m_outstanding, f_s_outstanding;
    wire [7:0] f_m_waited, f_m_stalled, f_s_waited, f_s_stalled;

    wb_checker #(
        .AW(30), .DUT_IS_SLAVE(1), .LGDEPTH(4),
        .MAX_OUTSTANDING(4), .MAX_WAIT(4), .MAX_STALL(0)
    ) f_master_side (
        .clk(clk), .rst(rst),
        .cyc(m_cyc), .stb(m_stb), .we(m_we), .adr(m_adr), .sel(m_sel), .dat_w(m_dat_w),
        .ack(m_ack), .err(m_err), .stall(m_stall),
        .outstanding(f_m_outstanding), .waited(f_m_waited), .stalled(f_m_stalled)
    );

    wb_checker #(
        .AW(30), .DUT_IS_SLAVE(0), .LGDEPTH(4),
        .MAX_OUTSTANDING(4), .MAX_WAIT(4), .MAX_STALL(0)
    ) f_slave_side (
        .clk(clk), .rst(rst),
        .cyc(s_cyc), .stb(s_stb), .we(m_we), .adr(m_adr), .sel(m_sel), .dat_w(m_dat_w),
        .ack(s_ack), .err(s_err), .stall(s_stall),
        .outstanding(f_s_outstanding), .waited(f_s_waited), .stalled(f_s_stalled)
    );

    // What the gate promises: no request reaches the slave without go, and the
    // two sides agree on what is owed.
    always @(*) begin
        if (s_stb)
            assert (go);
        if (f_past_valid && !rst)
            assert (f_m_outstanding == f_s_outstanding);
    end

    always @(*) begin
        if (f_past_valid && !rst) begin
            cover (m_cyc && m_stb && !go);                       // held back
            cover (s_ack);                                       // answered
            cover (f_m_outstanding == 2);                        // two in flight
        end
    end

endmodule
