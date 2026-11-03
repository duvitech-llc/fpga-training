`timescale 1ns/1ps

module tb_axil_regs;

    parameter BUFFERED = 1;

    localparam integer N    = 32;   // transactions in each measured burst
    localparam integer QMAX = 512;  // room in the script queues
    localparam [1:0] OKAY   = 2'b00;
    localparam [1:0] SLVERR = 2'b10;
    localparam [1:0] DECERR = 2'b11;
    localparam [31:0] ID    = 32'h4158_494C;

    reg         clk     = 1'b0;
    reg         rst     = 1'b1;
    reg         awvalid = 1'b0;
    reg  [31:0] awaddr  = 32'd0;
    reg         wvalid  = 1'b0;
    reg  [31:0] wdata   = 32'd0;
    reg  [3:0]  wstrb   = 4'd0;
    reg         bready  = 1'b0;
    reg         arvalid = 1'b0;
    reg  [31:0] araddr  = 32'd0;
    reg         rready  = 1'b0;
    reg  [2:0]  hold    = 3'd0;
    wire        awready, wready, bvalid, arready, rvalid;
    wire [1:0]  bresp, rresp;
    wire [31:0] rdata;

    axil_regs #(.BUFFERED(BUFFERED)) dut (
        .clk(clk), .rst(rst),
        .awvalid(awvalid), .awready(awready), .awaddr(awaddr), .awprot(3'd0),
        .wvalid(wvalid), .wready(wready), .wdata(wdata), .wstrb(wstrb),
        .bvalid(bvalid), .bready(bready), .bresp(bresp),
        .arvalid(arvalid), .arready(arready), .araddr(araddr), .arprot(3'd0),
        .rvalid(rvalid), .rready(rready), .rdata(rdata), .rresp(rresp),
        .hold(hold)
    );

    always #5 clk = ~clk;

    // A slave or master that deadlocks would otherwise leave the loops waiting forever.
    initial begin
        #200000;
        $fatal(1, "FAIL: timed out");
    end

    integer errors = 0;

    task fail(input [8*64-1:0] what);
        begin
            $display("FAIL t=%0t %0s", $time, what);
            errors = errors + 1;
        end
    endtask

    // ---- The script: what the master will send, and what must come back ----
    reg [31:0] wq_addr [0:QMAX-1];
    reg [31:0] wq_data [0:QMAX-1];
    reg [3:0]  wq_strb [0:QMAX-1];
    reg [1:0]  wq_resp [0:QMAX-1];
    reg [31:0] rq_addr [0:QMAX-1];
    reg [31:0] rq_data [0:QMAX-1];
    reg [1:0]  rq_resp [0:QMAX-1];
    integer wq_n = 0, aw_i = 0, w_i = 0, b_i = 0;  // queued, AW taken, W taken, B taken
    integer rq_n = 0, ar_i = 0, r_i = 0;           // queued, AR taken, R taken

    // What the registers should hold, in script order. A read that is queued
    // in the same run as a write to its register would race it, so the script
    // never does that.
    reg [31:0] model [0:3];
    integer k;

    task queue_write(input [31:0] addr, input [31:0] data, input [3:0] strb);
        begin
            wq_addr[wq_n] = addr;
            wq_data[wq_n] = data;
            wq_strb[wq_n] = strb;
            if (addr[31:5] != 0 || addr[4:2] > 4)
                wq_resp[wq_n] = DECERR;
            else if (addr[4])
                wq_resp[wq_n] = SLVERR;
            else begin
                wq_resp[wq_n] = OKAY;
                for (k = 0; k < 4; k = k + 1)
                    if (strb[k])
                        model[addr[3:2]][8*k +: 8] = data[8*k +: 8];
            end
            wq_n = wq_n + 1;
        end
    endtask

    task queue_read(input [31:0] addr);
        begin
            rq_addr[rq_n] = addr;
            if (addr[31:5] != 0 || addr[4:2] > 4) begin
                rq_resp[rq_n] = DECERR;
                rq_data[rq_n] = 32'd0;
            end else begin
                rq_resp[rq_n] = OKAY;
                rq_data[rq_n] = addr[4] ? ID : model[addr[3:2]];
            end
            rq_n = rq_n + 1;
        end
    endtask

    // ---- How the master and the slave behave in a run ----
    // order: 0 offers AW and W together, 1 offers AW LAG clocks before W,
    // 2 offers W LAG clocks before AW, 3 picks a random delay for each.
    integer order  = 0;
    integer p_hold = 0;   // percent of clocks with each slave ready held low
    integer p_busy = 0;   // percent of clocks with bready and rready low
    localparam integer LAG = 2;
    integer aw_wait = 0, w_wait = 0, ar_wait = 0;  // clocks before the next offer

    // The readys as the last rising edge saw them.
    reg awready_seen = 1'b0, wready_seen = 1'b0, arready_seen = 1'b0;

    // Statistics for one run.
    integer clocks, now, first_resp, last_resp, offered_at, b_at, r_at;

    // Call just after a falling edge, and each call takes one clock cycle.
    task step;
        begin
            // The previous rising edge took these, so move on to the next item.
            if (awvalid && awready_seen) begin
                aw_i    = aw_i + 1;
                awvalid = 1'b0;
                aw_wait = (order == 2) ? LAG : (order == 3) ? $urandom % 4 : 0;
            end
            if (wvalid && wready_seen) begin
                w_i    = w_i + 1;
                wvalid = 1'b0;
                w_wait = (order == 1) ? LAG : (order == 3) ? $urandom % 4 : 0;
            end
            if (arvalid && arready_seen) begin
                ar_i    = ar_i + 1;
                arvalid = 1'b0;
                ar_wait = (order == 3) ? $urandom % 4 : 0;
            end

            // Offer the next item on each request channel, after its delay.
            // valid never waits for ready.
            if (!awvalid && aw_i < wq_n) begin
                if (aw_wait > 0)
                    aw_wait = aw_wait - 1;
                else begin
                    awvalid = 1'b1;
                    awaddr  = wq_addr[aw_i];
                end
            end
            if (!wvalid && w_i < wq_n) begin
                if (w_wait > 0)
                    w_wait = w_wait - 1;
                else begin
                    wvalid = 1'b1;
                    wdata  = wq_data[w_i];
                    wstrb  = wq_strb[w_i];
                end
            end
            if (!arvalid && ar_i < rq_n) begin
                if (ar_wait > 0)
                    ar_wait = ar_wait - 1;
                else begin
                    arvalid = 1'b1;
                    araddr  = rq_addr[ar_i];
                end
            end
            if (offered_at < 0 && (awvalid || wvalid || arvalid))
                offered_at = now;

            hold[0] = ($urandom % 100) < p_hold;
            hold[1] = ($urandom % 100) < p_hold;
            hold[2] = ($urandom % 100) < p_hold;
            bready  = ($urandom % 100) >= p_busy;
            rready  = ($urandom % 100) >= p_busy;

            // The waiting slave's readys depend on the valids, so let them settle.
            #1;
            awready_seen = awready;
            wready_seen  = wready;
            arready_seen = arready;

            // Score the responses that the next rising edge takes. Each needs
            // its request taken at an earlier edge.
            if (bvalid === 1'b1 && bready) begin
                if (b_i >= aw_i || b_i >= w_i)
                    fail("a write response came before its request");
                else if (bresp !== wq_resp[b_i]) begin
                    $display("FAIL t=%0t write %0h: bresp=%0d expected %0d",
                             $time, wq_addr[b_i], bresp, wq_resp[b_i]);
                    errors = errors + 1;
                end
                b_i = b_i + 1;
                if (first_resp < 0)
                    first_resp = now;
                last_resp = now;
                if (b_at < 0)
                    b_at = now;
            end
            if (rvalid === 1'b1 && rready) begin
                if (r_i >= ar_i)
                    fail("a read response came before its request");
                else if (rdata !== rq_data[r_i] || rresp !== rq_resp[r_i]) begin
                    $display("FAIL t=%0t read %0h: rdata=%h rresp=%0d expected %h %0d",
                             $time, rq_addr[r_i], rdata, rresp, rq_data[r_i], rq_resp[r_i]);
                    errors = errors + 1;
                end
                r_i = r_i + 1;
                if (first_resp < 0)
                    first_resp = now;
                last_resp = now;
                if (r_at < 0)
                    r_at = now;
            end
            now = now + 1;
            @(negedge clk);
        end
    endtask

    // Runs until everything queued has been answered.
    task run;
        begin
            now        = 0;
            first_resp = -1;
            last_resp  = -1;
            offered_at = -1;
            b_at       = -1;
            r_at       = -1;
            while (b_i < wq_n || r_i < rq_n)
                step;
            // Let the last valids fall, with the ready signals quiet.
            p_hold = 0;
            p_busy = 0;
            step;
            // From the clock where the first request was offered to the clock
            // where the last response was taken, both counted.
            clocks = last_resp - offered_at + 1;
        end
    endtask

    // Prints the rate of the run that just finished.
    task report(input integer count);
        begin
            $display("  %0d transactions in %0d clocks: %0.2f per clock",
                     count, clocks, 1.0 * count / clocks);
        end
    endtask

    integer i, count;
    reg [31:0] rnd;

    initial begin
        if (BUFFERED)
            $dumpfile("build/tb_axil_regs_1.vcd");
        else
            $dumpfile("build/tb_axil_regs_0.vcd");
        $dumpvars(0, tb_axil_regs);
        for (i = 0; i < 4; i = i + 1)
            model[i] = 32'd0;

        $display("slave: BUFFERED=%0d", BUFFERED);
        @(negedge clk);
        @(negedge clk);
        rst = 1'b0;
        if (bvalid !== 1'b0 || rvalid !== 1'b0)
            fail("a response is on offer after reset");

        // One write and one read, alone, to see how long each takes.
        queue_write(32'h0, 32'h1234_5678, 4'hF);
        run;
        $display("one write: response taken %0d clocks after the request was offered",
                 b_at - offered_at);
        queue_read(32'h0);
        run;
        $display("one read: response taken %0d clocks after the request was offered",
                 r_at - offered_at);

        // Byte lanes.
        queue_write(32'h4, 32'h1122_3344, 4'hF);
        run;
        queue_write(32'h4, 32'hAAAA_AAAA, 4'b0001);
        run;
        queue_read(32'h4);
        run;
        queue_write(32'h4, 32'hBBBB_BBBB, 4'b0110);
        run;
        queue_read(32'h4);
        run;
        queue_write(32'h4, 32'hCCCC_CCCC, 4'b0000);  // no bytes: OKAY, nothing changes
        run;
        queue_write(32'h7, 32'hDDDD_DDDD, 4'b1000);  // bits [1:0] of the address are ignored
        run;
        queue_read(32'h5);
        run;
        if (model[1] !== 32'hDDBB_BBAA)
            fail("the testbench's own model is wrong");

        // ID, and the error responses.
        queue_read(32'h10);
        queue_write(32'h10, 32'hFFFF_FFFF, 4'hF);     // read-only: SLVERR
        queue_write(32'h14, 32'h1, 4'hF);             // nothing there: DECERR
        queue_write(32'h0000_1000, 32'h1, 4'hF);      // nothing there: DECERR
        queue_read(32'h14);
        queue_read(32'h8000_0000);
        run;
        queue_read(32'h10);
        queue_read(32'h0);
        run;

        // Throughput, with nothing stalled.
        $display("writes, nothing stalled:");
        for (i = 0; i < N; i = i + 1)
            queue_write({28'd0, i[1:0], 2'b00}, 32'h100 + i, 4'hF);
        run;
        report(N);
        $display("reads, nothing stalled:");
        for (i = 0; i < N; i = i + 1)
            queue_read({28'd0, i[1:0], 2'b00});
        run;
        report(N);
        $display("reads and writes together, nothing stalled:");
        for (i = 0; i < N; i = i + 1) begin
            queue_write({28'd0, 1'b1, i[0], 2'b00}, 32'h200 + i, 4'hF);  // reg2, reg3
            queue_read({27'd0, i[0], 4'b0000});                            // reg0 or ID
        end
        run;
        report(2 * N);

        // The order of AW and W.
        $display("AW offered %0d clocks before W:", LAG);
        order = 1;
        for (i = 0; i < 8; i = i + 1)
            queue_write({28'd0, i[1:0], 2'b00}, 32'h300 + i, 4'hF);
        run;
        report(8);
        $display("W offered %0d clocks before AW:", LAG);
        order = 2;
        for (i = 0; i < 8; i = i + 1)
            queue_write({28'd0, i[1:0], 2'b00}, 32'h400 + i, 4'hF);
        run;
        report(8);
        order = 0;
        for (i = 0; i < 4; i = i + 1)
            queue_read({28'd0, i[1:0], 2'b00});
        run;

        // Random backpressure on every channel, and a random order of AW and W.
        $display("random delays, ready held low 30%% and bready/rready low 30%% of clocks:");
        order  = 3;
        count  = 200;
        for (i = 0; i < count; i = i + 1) begin
            rnd = $urandom;
            queue_write({28'd0, 1'b1, rnd[0], 2'b00}, rnd, rnd[7:4]);   // reg2, reg3
            queue_read({27'd0, rnd[9], 1'b0, rnd[8] & ~rnd[9], 2'b00});   // reg0, reg1, ID
        end
        p_hold = 30;
        p_busy = 30;
        run;
        report(2 * count);
        order = 0;
        queue_read(32'h8);
        queue_read(32'hC);
        run;

        // Reset clears the registers.
        rst = 1'b1;
        @(negedge clk);
        rst = 1'b0;
        for (i = 0; i < 4; i = i + 1)
            model[i] = 32'd0;
        for (i = 0; i < 4; i = i + 1)
            queue_read({28'd0, i[1:0], 2'b00});
        run;

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
