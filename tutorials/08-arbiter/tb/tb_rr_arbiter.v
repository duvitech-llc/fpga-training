`timescale 1ns/1ps

module tb_rr_arbiter;

    parameter N = 4;

    localparam [N-1:0] NONE = {N{1'b0}};
    localparam [N-1:0] ALL  = {N{1'b1}};
    localparam integer ROUNDS = 100;

    reg          clk = 1'b0;
    reg          rst = 1'b1;
    reg  [N-1:0] req = NONE;
    wire [N-1:0] grant;
    wire [N-1:0] fixed_grant;

    integer errors = 0;
    integer i;
    integer j;
    integer rr_count    [0:N-1];
    integer fixed_count [0:N-1];

    rr_arbiter    #(.N(N)) dut   (.clk(clk), .rst(rst), .req(req), .grant(grant));
    fixed_arbiter #(.N(N)) fixed (.req(req), .grant(fixed_grant));

    always #5 clk = ~clk;

    // A vector with only bit n set.
    function [N-1:0] one(input integer n);
        begin
            one = NONE;
            one[n] = 1'b1;
        end
    endfunction

    // Call just after a falling edge, and each call takes one clock cycle.
    // grant is combinational, so it is checked before the rising edge.
    task step(input r, input [N-1:0] rq, input [N-1:0] expected);
        begin
            rst = r;
            req = rq;
            #1;
            if (grant !== expected) begin
                $display("FAIL t=%0t rst=%b req=%b grant=%b expected=%b",
                         $time, r, rq, grant, expected);
                errors = errors + 1;
            end
            @(negedge clk);
        end
    endtask

    initial begin
        $dumpfile("build/tb_rr_arbiter.vcd");
        $dumpvars(0, tb_rr_arbiter);

        @(negedge clk);

        //   rst   req    expected grant
        step(1'b1, ALL,   NONE);    // reset blocks every request
        step(1'b0, NONE,  NONE);    // no request, no grant

        // One requester at a time.
        for (i = 0; i < N; i = i + 1)
            step(1'b0, one(i), one(i));

        // Every request held: the grant visits each requester in turn.
        step(1'b1, NONE, NONE);
        for (i = 0; i < 3 * N; i = i + 1)
            step(1'b0, ALL, one(i % N));

        // Reset in the middle of a round restarts from requester 0.
        step(1'b1, ALL, NONE);
        step(1'b0, ALL, one(0));
        step(1'b0, ALL, one(1));
        step(1'b1, ALL, NONE);
        step(1'b0, ALL, one(0));

        // A lone requester is served every cycle, even straight after a grant.
        step(1'b1, NONE, NONE);
        step(1'b0, one(0), one(0));
        step(1'b0, one(0), one(0));

        // Idle cycles do not lose the place in the round.
        step(1'b1, NONE, NONE);
        step(1'b0, one(1), one(1));
        step(1'b0, NONE, NONE);
        step(1'b0, NONE, NONE);
        step(1'b0, ALL, one(2 % N));

        // A request above the last winner beats a lower-numbered one.
        step(1'b1, NONE, NONE);
        step(1'b0, one(N - 2), one(N - 2));
        step(1'b0, one(0) | one(N - 1), one(N - 1));
        step(1'b0, one(0) | one(N - 1), one(0));

        // Compare both arbiters with every request held.
        step(1'b1, NONE, NONE);
        for (i = 0; i < N; i = i + 1) begin
            rr_count[i] = 0;
            fixed_count[i] = 0;
        end
        for (j = 0; j < ROUNDS * N; j = j + 1) begin
            step(1'b0, ALL, one(j % N));
            // Sampled after the step's rising edge, while req is still ALL.
            for (i = 0; i < N; i = i + 1) begin
                if (grant[i])
                    rr_count[i] = rr_count[i] + 1;
                if (fixed_grant[i])
                    fixed_count[i] = fixed_count[i] + 1;
            end
        end

        $display("Grants in %0d cycles with every request held:", ROUNDS * N);
        for (i = 0; i < N; i = i + 1) begin
            $display("  requester %0d: fixed %0d, round-robin %0d",
                     i, fixed_count[i], rr_count[i]);
            if (rr_count[i] != ROUNDS) begin
                $display("FAIL requester %0d had %0d round-robin grants, expected %0d",
                         i, rr_count[i], ROUNDS);
                errors = errors + 1;
            end
        end

        if (fixed_count[0] != ROUNDS * N) begin
            $display("FAIL fixed arbiter gave requester 0 %0d grants", fixed_count[0]);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
