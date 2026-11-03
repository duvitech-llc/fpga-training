`timescale 1ns/1ps

module tb_wishbone;

    localparam integer WORDS = 32;  // requests in each throughput run

    // Word addresses: byte address bits [31:2].
    localparam [29:0] SLAVE0 = 30'h0400_0000;  // byte address 0x1000_0000
    localparam [29:0] SLAVE1 = 30'h0800_0000;  // byte address 0x2000_0000

    reg         clk           = 1'b0;
    reg         rst           = 1'b1;
    reg         one_at_a_time = 1'b0;
    reg         hold0         = 1'b0;
    reg         hold1         = 1'b0;
    reg         cmd_valid     = 1'b0;
    reg         cmd_we        = 1'b0;
    reg  [29:0] cmd_adr       = 30'd0;
    reg  [3:0]  cmd_sel       = 4'd0;
    reg  [31:0] cmd_dat       = 32'd0;
    wire        cmd_ready;
    wire        rsp_valid;
    wire        rsp_err;
    wire [31:0] rsp_dat;

    wb_system dut (
        .clk(clk), .rst(rst), .one_at_a_time(one_at_a_time), .hold0(hold0), .hold1(hold1),
        .cmd_valid(cmd_valid), .cmd_ready(cmd_ready), .cmd_we(cmd_we), .cmd_adr(cmd_adr),
        .cmd_sel(cmd_sel), .cmd_dat(cmd_dat),
        .rsp_valid(rsp_valid), .rsp_err(rsp_err), .rsp_dat(rsp_dat)
    );

    always #5 clk = ~clk;

    // A bus that never answers would otherwise leave the loops below waiting forever.
    initial begin
        #100000;
        $fatal(1, "FAIL: timed out");
    end

    // What the two slaves should hold: word {slave, register}.
    reg [31:0] model [0:7];

    // Answers still owed, oldest first. Answers come back in order, so a queue
    // of expectations is the whole scoreboard.
    reg        q_err  [0:255];
    reg        q_read [0:255];
    reg [31:0] q_dat  [0:255];
    reg [7:0]  q_head = 0;
    reg [7:0]  q_tail = 0;

    integer errors  = 0;
    integer cycle   = 0;
    integer first   = -1;  // clock of the first request in a measured run
    integer last    = -1;  // clock of the last answer
    integer answers = 0;
    integer checked = 0;  // answers compared with the scoreboard
    integer errs    = 0;  // of those, answers with err
    integer issued;
    integer i;
    reg [15:0] lfsr = 16'hACE1;
    reg        toggle_hold1 = 1'b0;  // make slave 1 busy on every other clock
    real    rate;

    task fail(input [8*64-1:0] what);
        begin
            $display("FAIL t=%0t %0s", $time, what);
            errors = errors + 1;
        end
    endtask

    function mapped(input [29:0] a);
        mapped = (a[29:2] == SLAVE0[29:2]) || (a[29:2] == SLAVE1[29:2]);
    endfunction

    // The word address of register r in the 16-byte region at base.
    function [29:0] reg_at(input [29:0] base, input [1:0] r);
        reg_at = {base[29:2], r};
    endfunction

    function [2:0] slot(input [29:0] a);
        slot = {a[29:2] == SLAVE1[29:2], a[1:0]};
    endfunction

    function [31:0] merge(input [31:0] old, input [31:0] dat, input [3:0] sel);
        integer k;
        begin
            merge = old;
            for (k = 0; k < 4; k = k + 1)
                if (sel[k])
                    merge[8*k +: 8] = dat[8*k +: 8];
        end
    endfunction

    // Call just after a falling edge, and each call takes one clock. The inputs
    // change at the falling edge, and 1 ns later everything read here is what the
    // next rising edge samples.
    task step(input valid, input we, input [29:0] adr, input [3:0] sel, input [31:0] dat);
        begin
            cmd_valid = valid;
            cmd_we    = we;
            cmd_adr   = adr;
            cmd_sel   = sel;
            cmd_dat   = dat;
            if (toggle_hold1)
                hold1 = !hold1;
            // hold reaches stall and cmd_ready through logic, so let it settle.
            #1;

            // An answer from the last rising edge.
            if (rsp_valid !== 1'b0) begin
                if (rsp_valid !== 1'b1) begin
                    fail("rsp_valid is x");
                end else if (q_head == q_tail) begin
                    fail("an answer with nothing outstanding");
                end else begin
                    if (rsp_err !== q_err[q_head]) begin
                        $display("FAIL t=%0t err=%b expected=%b", $time, rsp_err, q_err[q_head]);
                        errors = errors + 1;
                    end else if (q_read[q_head] && !q_err[q_head] && rsp_dat !== q_dat[q_head]) begin
                        $display("FAIL t=%0t read %h expected %h", $time, rsp_dat, q_dat[q_head]);
                        errors = errors + 1;
                    end
                    if (rsp_err === 1'b1)
                        errs = errs + 1;
                    q_head  = q_head + 1'b1;
                    checked = checked + 1;
                end
            end

            // A command taken at the next rising edge. Its answer is worked out
            // now, from the model, since the bus keeps everything in order.
            if (valid && cmd_ready === 1'b1) begin
                q_read[q_tail] = !we;
                q_err[q_tail]  = !mapped(adr);
                if (mapped(adr)) begin
                    q_dat[q_tail] = model[slot(adr)];
                    if (we)
                        model[slot(adr)] = merge(model[slot(adr)], dat, sel);
                end
                q_tail = q_tail + 1'b1;
            end

            // The bus itself, for measuring throughput.
            if (dut.m_cyc && dut.m_stb && !dut.m_stall && first < 0)
                first = cycle;
            if (dut.m_cyc && (dut.m_ack || dut.m_err)) begin
                last    = cycle;
                answers = answers + 1;
            end
            if (dut.m_stb && !dut.m_cyc)
                fail("stb without cyc");

            @(negedge clk);
            cycle = cycle + 1;
        end
    endtask

    // Wait for every answer that is owed.
    task drain;
        begin
            while (q_head != q_tail)
                step(1'b0, 1'b0, 30'd0, 4'd0, 32'd0);
            step(1'b0, 1'b0, 30'd0, 4'd0, 32'd0);
            if (dut.m_cyc !== 1'b0)
                fail("cyc stayed high with nothing owed");
        end
    endtask

    // Offers one command until it is taken.
    task send(input we, input [29:0] adr, input [3:0] sel, input [31:0] dat);
        begin
            while (cmd_ready !== 1'b1)
                step(1'b0, 1'b0, 30'd0, 4'd0, 32'd0);
            step(1'b1, we, adr, sel, dat);
        end
    endtask

    // WORDS reads as fast as the master will take them, then a drain. pattern 0
    // reads slave 0, 1 reads slave 1, and 2 takes turns.
    task measure(input integer pattern);
        reg [29:0] a;
        begin
            first   = -1;
            answers = 0;
            issued  = 0;
            while (issued < WORDS) begin
                a = (pattern == 0) ? SLAVE0 : (pattern == 1) ? SLAVE1 :
                    (issued % 2 == 0) ? SLAVE0 : SLAVE1;
                a[1:0] = issued[1:0];
                if (cmd_ready === 1'b1)
                    issued = issued + 1;
                step(1'b1, 1'b0, a, 4'hF, 32'd0);
            end
            drain;
            rate = 1.0 * WORDS / (last - first);
            $display("  %0d reads in %0d clocks: %0.2f per clock", answers, last - first, rate);
            if (answers != WORDS)
                fail("wrong number of answers");
        end
    endtask

    initial begin
        $dumpfile("build/tb_wishbone.vcd");
        $dumpvars(0, tb_wishbone);

        @(negedge clk);
        @(negedge clk);
        rst = 1'b0;
        step(1'b0, 1'b0, 30'd0, 4'd0, 32'd0);

        // Fill all eight registers, then read them back.
        $display("write and read back:");
        for (i = 0; i < 8; i = i + 1)
            send(1'b1, reg_at(i < 4 ? SLAVE0 : SLAVE1, i[1:0]), 4'hF, 32'h1111_1111 * (i + 1));
        for (i = 0; i < 8; i = i + 1)
            send(1'b0, reg_at(i < 4 ? SLAVE0 : SLAVE1, i[1:0]), 4'hF, 32'd0);
        drain;
        $display("  8 writes and 8 reads, all answered");

        // Byte enables: each write changes only the lanes that sel picks.
        $display("partial-word writes:");
        send(1'b1, SLAVE0 + 1, 4'b0001, 32'hAAAA_AA01);
        send(1'b1, SLAVE0 + 1, 4'b0100, 32'hAA02_AAAA);
        send(1'b1, SLAVE0 + 1, 4'b1100, 32'h0403_AAAA);
        send(1'b1, SLAVE0 + 1, 4'b0000, 32'hFFFF_FFFF);
        send(1'b0, SLAVE0 + 1, 4'b0000, 32'd0);
        drain;
        $display("  slave 0 register 1 is %h", dut.u_slave0.regs[1]);
        if (dut.u_slave0.regs[1] !== 32'h0403_2201)
            fail("byte lanes");

        // A write followed straight away by a read of the same register.
        send(1'b1, SLAVE1 + 2, 4'hF, 32'hCAFE_F00D);
        send(1'b0, SLAVE1 + 2, 4'hF, 32'd0);
        drain;

        // Nobody owns these: each must get err, and change nothing.
        $display("unmapped addresses:");
        i = errs;
        send(1'b1, SLAVE0 + 4, 4'hF, 32'hDEAD_BEEF);  // byte address 0x1000_0010
        send(1'b0, 30'd0, 4'hF, 32'd0);               // byte address 0x0000_0000
        send(1'b0, 30'h0C00_0000, 4'hF, 32'd0);       // byte address 0x3000_0000
        send(1'b0, SLAVE0, 4'hF, 32'd0);
        drain;
        $display("  %0d of 4 requests answered with err", errs - i);

        // Throughput. Slave 0 answers 1 clock after each request, slave 1 after 3.
        $display("pipelined, slave 0 (latency 1):");
        measure(0);
        $display("one at a time, slave 0 (latency 1):");
        one_at_a_time = 1'b1;
        step(1'b0, 1'b0, 30'd0, 4'd0, 32'd0);
        measure(0);
        $display("pipelined, slave 1 (latency 3):");
        one_at_a_time = 1'b0;
        step(1'b0, 1'b0, 30'd0, 4'd0, 32'd0);
        measure(1);
        $display("one at a time, slave 1 (latency 3):");
        one_at_a_time = 1'b1;
        step(1'b0, 1'b0, 30'd0, 4'd0, 32'd0);
        measure(1);
        $display("pipelined, slave 1 (latency 3) with hold1 high every other clock:");
        one_at_a_time = 1'b0;
        step(1'b0, 1'b0, 30'd0, 4'd0, 32'd0);
        toggle_hold1 = 1'b1;
        measure(1);
        toggle_hold1 = 1'b0;
        hold1 = 1'b0;
        $display("pipelined, taking turns between slaves 0 and 1:");
        step(1'b0, 1'b0, 30'd0, 4'd0, 32'd0);
        measure(2);

        // A mixed run: every address kind, both slaves busy at random, both modes.
        $display("mixed traffic:");
        for (i = 0; i < 400; i = i + 1) begin
            lfsr  = {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            hold0 = lfsr[1] & lfsr[0];
            hold1 = lfsr[3] & lfsr[2];
            if (i % 100 == 0)
                one_at_a_time = lfsr[4];
            step(lfsr[5] | lfsr[6],
                 lfsr[7],
                 (lfsr[9:8] == 2'd0) ? reg_at(SLAVE0, lfsr[11:10]) :
                 (lfsr[9:8] == 2'd1) ? reg_at(SLAVE1, lfsr[11:10]) :
                 (lfsr[9:8] == 2'd2) ? reg_at(SLAVE0 + 30'd4, lfsr[11:10]) : reg_at(30'h0C00_0000, lfsr[11:10]),
                 lfsr[15:12],
                 {lfsr, ~lfsr});
        end
        drain;
        $display("  %0d answers checked in all, %0d of them err", checked, errs);

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
