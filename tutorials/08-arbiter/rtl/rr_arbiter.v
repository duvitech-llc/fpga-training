// Round-robin arbiter. N must be at least 2.
//
// grant is combinational: a requester sees it in the same cycle as its request,
// and the arbiter moves on at the next rising edge. req must therefore not
// depend combinationally on grant, or the two would form a loop.
module rr_arbiter #(
    parameter N = 4
) (
    input  wire         clk,
    input  wire         rst,    // synchronous, active high, forces grant to zero
    input  wire [N-1:0] req,    // one bit per requester
    output wire [N-1:0] grant   // one-hot, or zero when nothing is granted
);

    // A 1 means "still has a turn in this round". The bits are always ones above
    // zeros, because the requesters at and below the last winner have had a turn.
    reg [N-1:0] mask;

    wire [N-1:0] masked_grant;
    wire [N-1:0] plain_grant;

    fixed_arbiter #(.N(N)) masked_arbiter (.req(req & mask), .grant(masked_grant));
    fixed_arbiter #(.N(N)) plain_arbiter  (.req(req),        .grant(plain_grant));

    // If nobody who is left in this round is asking, start a new round.
    assign grant = rst             ? {N{1'b0}}    :
                   (|masked_grant) ? masked_grant :
                                     plain_grant;

    // grant - 1 has ones below the winner. With the winner added and everything
    // inverted, only the requesters above the winner remain. The mask holds when
    // nothing is granted, so an idle cycle does not lose anyone's place.
    always @(posedge clk) begin
        if (rst)
            mask <= {N{1'b1}};
        else if (|grant)
            mask <= ~(grant | (grant - 1'b1));
    end

`ifdef FORMAL
    // $past needs one clock of history before it is meaningful.
    reg past_valid = 1'b0;
    always @(posedge clk)
        past_valid <= 1'b1;

    // Without this the solver may start mask at a value reset can never give.
    always @(posedge clk) begin
        if (!past_valid)
            assume (rst);
    end

    // Safety: rules about a single cycle, which need no assumption about req.
    always @(*) begin
        assert ($onehot0(grant));
        assert ((grant & ~req) == 0);
        if (rst)
            assert (grant == 0);
        else if (|req)
            assert (|grant);
    end

    // The solver picks any one requester and keeps it for the whole proof.
    (* anyconst *) reg [$clog2(N)-1:0] watched;
    always @(*)
        assume (watched < N);

    // Fairness needs a promise from the watched requester: once it asks, it
    // keeps asking until it is granted. The other requesters are left free.
    always @(posedge clk) begin
        if (past_valid && !$past(rst) && $past(req[watched]) && !$past(grant[watched]))
            assume (req[watched]);
    end

    // Cycles the watched request has been waiting.
    reg [$clog2(N):0] wait_count;
    always @(posedge clk) begin
        if (rst || grant[watched])
            wait_count <= 0;
        else if (req[watched])
            wait_count <= wait_count + 1'b1;
    end

    // Fairness: no request waits for more than N-1 other grants. A request that
    // is waiting always sees a grant, so cycles waited equal other grants.
    always @(*) begin
        if (past_valid) begin
            assert (wait_count <= N - 1);

            // A helper for induction, which may start in a state that reset
            // could never reach: a wait in progress with no request.
            if (wait_count != 0)
                assert (req[watched]);
        end
    end
`endif

endmodule
