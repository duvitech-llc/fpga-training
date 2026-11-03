`timescale 1ps/1ps

module tb_async_fifo;

    parameter WIDTH      = 8;
    parameter ADDR_WIDTH = 4;

    localparam integer DEPTH = 1 << ADDR_WIDTH;

    reg              wr_clk  = 1'b0;
    reg              wr_rst  = 1'b1;
    reg              wr_en   = 1'b0;
    reg  [WIDTH-1:0] wr_data = 0;
    wire             full;
    reg              rd_clk  = 1'b0;
    reg              rd_rst  = 1'b1;
    reg              rd_en   = 1'b0;
    wire [WIDTH-1:0] rd_data;
    wire             empty;

    // Half periods in ps. They share no common factor, so the clocks drift past
    // each other.
    integer wr_half = 5003;
    integer rd_half = 3137;

    integer errors  = 0;
    integer wr_seq  = 0;    // words accepted, used only by the write side
    integer rd_seq  = 0;    // words read, used only by the read side
    integer wr_rand = 1;    // each side has its own random numbers too
    integer rd_rand = 7;
    integer blocked_wr = 0;
    integer blocked_rd = 0;
    integer total_blocked_wr = 0;
    integer total_blocked_rd = 0;
    integer total_words = 0;
    integer count;

    async_fifo #(.WIDTH(WIDTH), .ADDR_WIDTH(ADDR_WIDTH)) dut (
        .wr_clk(wr_clk), .wr_rst(wr_rst), .wr_en(wr_en), .wr_data(wr_data), .full(full),
        .rd_clk(rd_clk), .rd_rst(rd_rst), .rd_en(rd_en), .rd_data(rd_data), .empty(empty)
    );

    always #wr_half wr_clk = ~wr_clk;
    always #rd_half rd_clk = ~rd_clk;

    // Each word is worked out from its position in the stream. The reader can
    // predict it without looking at anything the writer owns, so the two
    // processes share no variables. Two edges can land at the same instant, and
    // a shared variable would then depend on which process the simulator ran
    // first, which simulators are free to choose.
    function [WIDTH-1:0] word(input integer seq);
        integer value;
        begin
            value = seq * 167 + 13;
            word = value[WIDTH-1:0];
        end
    endfunction

    // A small generator rather than $random, since each side needs its own.
    function integer next_rand(input integer state);
        next_rand = state * 1103515245 + 12345;
    endfunction

    function chance(input integer state, input integer pct);
        integer high;
        begin
            high = (state >> 16) & 32'h7fff;
            chance = (high % 100) < pct;
        end
    endfunction

    // Call just after a falling edge of wr_clk. full cannot change before the
    // next rising edge, so it says now what that edge is going to do.
    task writer(input integer words, input integer pct);
        integer sent;
        begin
            sent = 0;
            while (sent < words) begin
                wr_rand = next_rand(wr_rand);
                wr_en   = chance(wr_rand, pct);
                wr_data = word(wr_seq);
                if (wr_en && !full) begin
                    wr_seq = wr_seq + 1;
                    sent   = sent + 1;
                end else if (wr_en) begin
                    blocked_wr = blocked_wr + 1;
                end
                @(negedge wr_clk);
            end
            wr_en = 1'b0;
        end
    endtask

    // The same on rd_clk. rd_data is checked one clock after the read.
    task reader(input integer words, input integer pct);
        integer got;
        reg     pending;
        begin
            got     = 0;
            pending = 1'b0;
            while (got < words || pending) begin
                if (pending) begin
                    if (rd_data !== word(rd_seq)) begin
                        $display("FAIL t=%0t word %0d rd_data=%h expected=%h",
                                 $time, rd_seq, rd_data, word(rd_seq));
                        errors = errors + 1;
                    end
                    rd_seq = rd_seq + 1;
                end
                rd_rand = next_rand(rd_rand);
                rd_en   = (got < words) && chance(rd_rand, pct);
                pending = rd_en && !empty;
                if (pending)
                    got = got + 1;
                else if (rd_en)
                    blocked_rd = blocked_rd + 1;
                @(negedge rd_clk);
            end
            rd_en = 1'b0;
        end
    endtask

    // Both resets at once, for several rising edges of each clock.
    task reset_both;
        begin
            wr_rst = 1'b1;
            rd_rst = 1'b1;
            wr_en  = 1'b0;
            rd_en  = 1'b0;
            repeat (3) @(negedge wr_clk);
            repeat (3) @(negedge rd_clk);
            @(negedge wr_clk);
            wr_rst = 1'b0;
            @(negedge rd_clk);
            rd_rst = 1'b0;
            wr_seq = 0;
            rd_seq = 0;
        end
    endtask

    // Long enough for a moved pointer to reach the other side and be seen.
    task settle;
        begin
            repeat (3) @(negedge wr_clk);
            repeat (3) @(negedge rd_clk);
            repeat (3) @(negedge wr_clk);
        end
    endtask

    task expect_flags(input expected_full, input expected_empty);
        begin
            if (full !== expected_full || empty !== expected_empty) begin
                $display("FAIL t=%0t full=%b expected=%b empty=%b expected=%b",
                         $time, full, expected_full, empty, expected_empty);
                errors = errors + 1;
            end
        end
    endtask

    // One clock ratio with one traffic pattern. The two sides run at once, and
    // each waits only on its own clock.
    task run(input integer wr_h, input integer rd_h, input integer wr_pct, input integer rd_pct);
        begin
            settle;
            wr_half    = wr_h;
            rd_half    = rd_h;
            blocked_wr = 0;
            blocked_rd = 0;
            fork
                begin
                    @(negedge wr_clk);
                    writer(40 * DEPTH, wr_pct);
                end
                begin
                    @(negedge rd_clk);
                    reader(40 * DEPTH, rd_pct);
                end
            join
            settle;
            expect_flags(1'b0, 1'b1);
            $display("half periods %0d and %0d ps, enables %0d%% and %0d%%: %0d blocked writes, %0d blocked reads",
                     wr_h, rd_h, wr_pct, rd_pct, blocked_wr, blocked_rd);
            // The side in a hurry must run into full or empty in every ratio, or
            // this ratio never tested the flag that should stop it.
            if (wr_pct > rd_pct && blocked_wr == 0) begin
                $display("FAIL this ratio never reached full");
                errors = errors + 1;
            end
            if (wr_pct < rd_pct && blocked_rd == 0) begin
                $display("FAIL this ratio never reached empty");
                errors = errors + 1;
            end
            total_blocked_wr = total_blocked_wr + blocked_wr;
            total_blocked_rd = total_blocked_rd + blocked_rd;
            total_words      = total_words + 40 * DEPTH;
        end
    endtask

    initial begin
        $dumpfile("build/tb_async_fifo.vcd");
        $dumpvars(0, tb_async_fifo);

        reset_both;
        expect_flags(1'b0, 1'b1);

        // The reader is idle, so the writer's copy of its pointer is up to date.
        // full must rise after exactly DEPTH words, and then a write must fail.
        @(negedge wr_clk);
        writer(DEPTH, 100);
        settle;
        expect_flags(1'b1, 1'b0);
        @(negedge wr_clk);
        wr_en   = 1'b1;
        wr_data = ~word(wr_seq);
        @(negedge wr_clk);
        wr_en   = 1'b0;

        // Pessimism: one read frees a slot, but full stays high until the news
        // has crossed the synchronizer, two write clocks later.
        @(negedge rd_clk);
        count = 0;
        fork
            begin
                rd_en = 1'b1;
                @(negedge rd_clk);
                rd_en = 1'b0;
            end
            begin
                @(posedge rd_clk);
                #1;
                while (full === 1'b1) begin
                    @(posedge wr_clk);
                    #1;
                    count = count + 1;
                end
            end
        join
        $display("full stayed high for %0d write clocks after a read freed a slot", count);
        if (count !== 2) begin
            $display("FAIL full took %0d write clocks to fall, expected 2", count);
            errors = errors + 1;
        end
        @(negedge rd_clk);
        if (rd_data !== word(rd_seq)) begin
            $display("FAIL first word rd_data=%h expected=%h", rd_data, word(rd_seq));
            errors = errors + 1;
        end
        rd_seq = rd_seq + 1;

        // Drain the rest. A word lost or added by the blocked write shows here.
        reader(DEPTH - 1, 100);
        settle;
        expect_flags(1'b0, 1'b1);

        // The same measurement for empty.
        @(negedge wr_clk);
        count = 0;
        fork
            begin
                wr_en   = 1'b1;
                wr_data = word(wr_seq);
                @(negedge wr_clk);
                wr_en   = 1'b0;
            end
            begin
                @(posedge wr_clk);
                #1;
                while (empty === 1'b1) begin
                    @(posedge rd_clk);
                    #1;
                    count = count + 1;
                end
            end
        join
        $display("empty stayed high for %0d read clocks after a write", count);
        if (count !== 2) begin
            $display("FAIL empty took %0d read clocks to fall, expected 2", count);
            errors = errors + 1;
        end

        // A reset with words inside must leave an empty FIFO.
        settle;
        expect_flags(1'b0, 1'b0);
        reset_both;
        settle;
        expect_flags(1'b0, 1'b1);

        // At each ratio, first the writer is in a hurry, then the reader.
        //  wr half  rd half  wr %  rd %
        run(   5003,    3137,  100,   10);  // write about 1.6 times faster
        run(   5003,    3137,   10,  100);
        run(   3137,    5003,  100,   10);  // read about 1.6 times faster
        run(   3137,    5003,   10,  100);
        run(   1009,    7001,  100,   10);  // write about 7 times faster
        run(   1009,    7001,   10,  100);
        run(   7001,    1009,  100,   10);  // read about 7 times faster
        run(   7001,    1009,   10,  100);
        run(   5003,    5021,  100,   10);  // nearly equal, so the edges slide past
        run(   5003,    5021,   10,  100);

        $display("%0d words, %0d blocked writes, %0d blocked reads",
                 total_words, total_blocked_wr, total_blocked_rd);
        if (total_blocked_wr == 0 || total_blocked_rd == 0) begin
            $display("FAIL the traffic never reached full or never reached empty");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

    // A FIFO that stops moving data would otherwise hang the processes forever.
    initial begin
        #2000000000;
        $fatal(1, "FAIL: timed out");
    end

endmodule
