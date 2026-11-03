// A Wishbone B4 pipelined slave: 2**AW registers of 32 bits.
//
// A request is accepted at a rising edge where cyc and stb are high and stall is
// low. Its ack comes LATENCY clocks later, and the slave can take a new request
// on every clock meanwhile, so up to LATENCY requests can be in flight. The ack
// and dat_r come straight from flip-flops.
//
// hold makes the device slow. While it is high, stall is high, and the requests in
// flight wait where they are: each clock of hold adds one wait state to each of
// them. Tie it low for a device that is never busy.
//
// adr is a word address: bits [AW+1:2] of the byte address. A write changes only
// the bytes whose sel bit is high. A read always returns the whole word, whatever
// sel says. This slave never answers with err.
module wb_regfile #(
    parameter AW      = 2,  // 2**AW registers
    parameter LATENCY = 1   // clocks from a request to its ack, with hold low. At least 1
) (
    input  wire          clk,
    input  wire          rst,     // synchronous, active high
    // Wishbone slave port
    input  wire          cyc,     // a bus cycle is in progress
    input  wire          stb,     // a request is on the bus
    input  wire          we,      // the request is a write
    input  wire [AW-1:0] adr,     // word address
    input  wire [3:0]    sel,     // byte enables for a write: bit k is dat_w[8k+7:8k]
    input  wire [31:0]   dat_w,   // write data, master to slave
    output wire          ack,     // the oldest request is done, for one clock
    output wire          err,     // never: every address here exists
    output wire          stall,   // the request on the bus is not taken at this edge
    output wire [31:0]   dat_r,   // read data, valid while ack is high
    // The device is busy: stall, and add a wait state to every request in flight
    input  wire          hold
);

    reg [31:0] regs [0:(1<<AW)-1];

    // The requests in flight, newest in stage 0. Stage LATENCY-1 is the answer.
    reg [LATENCY-1:0] busy;
    reg [31:0]        data [0:LATENCY-1];

    assign ack   = busy[LATENCY-1];
    assign dat_r = data[LATENCY-1];
    assign stall = hold;
    assign err   = 1'b0;

    wire accept = cyc && stb && !stall;

    integer k;

    always @(posedge clk) begin
        if (rst || !cyc) begin
            // A master that drops cyc abandons the cycle, and gets no more answers.
            busy <= {LATENCY{1'b0}};
        end else if (hold) begin
            // The answer on the bus now is taken at this edge. The rest wait.
            busy[LATENCY-1] <= 1'b0;
        end else begin
            for (k = LATENCY - 1; k > 0; k = k - 1) begin
                busy[k] <= busy[k-1];
                data[k] <= data[k-1];
            end
            busy[0] <= accept;
            data[0] <= regs[adr];
        end

        if (accept && we) begin
            for (k = 0; k < 4; k = k + 1)
                if (sel[k])
                    regs[adr][8*k +: 8] <= dat_w[8*k +: 8];
        end
    end

`ifdef FORMAL
    // The previous clock, for the checks below. The checker keeps its own copy.
    reg f_past_valid = 1'b0;
    reg f_past_rst, f_past_cyc, f_past_hold;
    always @(posedge clk) begin
        f_past_valid <= 1'b1;
        f_past_rst   <= rst;
        f_past_cyc   <= cyc;
        f_past_hold  <= hold;
    end

    // The bus rules, from the slave's side: the master's rules are assumed, and
    // this slave's rules are asserted. See formal/wb_checker.v. hold is never
    // high on two clocks in a row, so the slave is slow but not stuck, and a
    // request is answered at most 2 * LATENCY - 1 clocks after it was accepted.
    always @(*)
        if (f_past_valid && f_past_hold)
            assume (!hold);

    wire [3:0] f_outstanding;
    wire [7:0] f_waited;
    wire [7:0] f_stalled;

    wb_checker #(
        .AW(AW), .DUT_IS_SLAVE(1), .LGDEPTH(4),
        .MAX_OUTSTANDING(LATENCY), .MAX_WAIT(2 * LATENCY - 1), .MAX_STALL(2)
    ) f_bus (
        .clk(clk), .rst(rst),
        .cyc(cyc), .stb(stb), .we(we), .adr(adr), .sel(sel), .dat_w(dat_w),
        .ack(ack), .err(err), .stall(stall),
        .outstanding(f_outstanding), .waited(f_waited), .stalled(f_stalled)
    );

    // Induction needs the checker's count tied to this slave's own state.
    reg [3:0] f_busy_count;
    integer   m, n, q;  // one loop variable for each always block
    always @(*) begin
        f_busy_count = 0;
        for (m = 0; m < LATENCY; m = m + 1)
            f_busy_count = f_busy_count + {3'd0, busy[m]};
    end

    always @(*) begin
        if (!f_past_valid) begin
            // The first clock is in reset, and nothing has been loaded yet.
        end else if (f_past_rst || !f_past_cyc) begin
            assert (busy == 0);
        end else begin
            assert (f_outstanding == f_busy_count);
            if (busy == 0)
                assert (f_waited == 0);
        end
    end

    // The data: pick any one register, and keep a copy of what it should hold.
    // A read of it must return the copy, byte lanes and all, with its own ack.
    (* anyconst *) reg [AW-1:0] f_adr;
    reg [31:0]        f_word;
    reg               f_known   = 1'b0;  // f_word has been written in full
    reg               f_partial = 1'b0;  // and then in part
    reg [LATENCY-1:0] f_read;            // which stages hold a read of f_adr
    reg [31:0]        f_expect [0:LATENCY-1];

    always @(posedge clk) begin
        if (accept && we && adr == f_adr) begin
            for (n = 0; n < 4; n = n + 1)
                if (sel[n])
                    f_word[8*n +: 8] <= dat_w[8*n +: 8];
            if (sel == 4'hF)
                f_known <= 1'b1;
            else if (f_known && sel != 4'h0)
                f_partial <= 1'b1;
        end

        if (!hold) begin
            for (n = LATENCY - 1; n > 0; n = n - 1) begin
                f_read[n]   <= f_read[n-1];
                f_expect[n] <= f_expect[n-1];
            end
            f_read[0]   <= accept && !we && adr == f_adr && f_known;
            f_expect[0] <= f_word;
        end
    end

    always @(*) begin
        if (f_known)
            assert (regs[f_adr] == f_word);
        for (q = 0; q < LATENCY; q = q + 1)
            if (f_past_valid && busy[q] && f_read[q])
                assert (data[q] == f_expect[q]);
    end

    // These must be reachable, or an assumption has ruled them out.
    always @(*) begin
        if (f_past_valid && !rst) begin
            cover (ack && f_outstanding == LATENCY);       // the pipeline full
            cover (ack && f_waited == 2 * LATENCY - 2);    // the longest wait
            cover (cyc && stb && stall && busy != 0);      // a request held back
            cover (f_partial && ack && f_read[LATENCY-1]); // a read after a partial write
            cover (f_past_cyc && !cyc && busy != 0);       // a cycle abandoned
        end
    end
`endif

endmodule
