`timescale 1ns/1ps

module tb_sync_ram;

    parameter WIDTH = 8;
    parameter DEPTH = 256;

    localparam integer ADDR_BITS = $clog2(DEPTH);
    localparam integer LAST      = DEPTH - 1;

    reg                  clk   = 1'b0;
    reg                  we    = 1'b0;
    reg  [ADDR_BITS-1:0] waddr = 0;
    reg  [WIDTH-1:0]     wdata = 0;
    reg                  re    = 1'b0;
    reg  [ADDR_BITS-1:0] raddr = 0;
    wire [WIDTH-1:0]     rdata;

    reg  [WIDTH-1:0]     held;  // what rdata should show until the next read

    integer errors = 0;
    integer i;

    sync_ram #(.WIDTH(WIDTH), .DEPTH(DEPTH)) dut (
        .clk(clk), .we(we), .waddr(waddr), .wdata(wdata),
        .re(re), .raddr(raddr), .rdata(rdata)
    );

    always #5 clk = ~clk;

    // A different word at each address, as long as WIDTH covers the address.
    function [WIDTH-1:0] pattern(input integer addr);
        pattern = ~addr[WIDTH-1:0];
    endfunction

    // Call just after a falling edge, and each call takes one clock cycle.
    // rdata must not move before the rising edge, or the read has no latency.
    task step(input w, input integer wa, input [WIDTH-1:0] wd,
              input r, input integer ra, input [WIDTH-1:0] expected);
        begin
            we    = w;
            waddr = wa[ADDR_BITS-1:0];
            wdata = wd;
            re    = r;
            raddr = ra[ADDR_BITS-1:0];
            #1;
            if (rdata !== held) begin
                $display("FAIL t=%0t rdata=%h moved before the clock edge, expected=%h",
                         $time, rdata, held);
                errors = errors + 1;
            end
            @(negedge clk);
            if (rdata !== expected) begin
                $display("FAIL t=%0t we=%b waddr=%0d wdata=%h re=%b raddr=%0d rdata=%h expected=%h",
                         $time, w, wa, wd, r, ra, rdata, expected);
                errors = errors + 1;
            end
            held = expected;
        end
    endtask

    initial begin
        $dumpfile("build/tb_sync_ram.vcd");
        $dumpvars(0, tb_sync_ram);

        @(negedge clk);

        // Nothing has been written, so this word has no known value. Icarus
        // shows x. Verilator has no x, so it can only be displayed there.
        re = 1'b1;
        @(negedge clk);
        $display("Read of an unwritten word: rdata=%h", rdata);
`ifndef VERILATOR
        if (rdata !== {WIDTH{1'bx}}) begin
            $display("FAIL an unwritten word should read as x");
            errors = errors + 1;
        end
`endif
        held = rdata;

        //   we    waddr  wdata          re    raddr  expected rdata
        // Every address, with two patterns so each bit is seen at 0 and at 1.
        for (i = 0; i <= LAST; i = i + 1)
            step(1'b1, i, pattern(i),    1'b0, 0,     held);
        for (i = 0; i <= LAST; i = i + 1)
            step(1'b0, 0, 0,             1'b1, i,     pattern(i));
        for (i = 0; i <= LAST; i = i + 1)
            step(1'b1, i, ~pattern(i),   1'b0, 0,     held);
        for (i = 0; i <= LAST; i = i + 1)
            step(1'b0, 0, 0,             1'b1, i,     ~pattern(i));

        // re low holds rdata, whatever raddr does.
        step(1'b0, 0, 0,                 1'b0, LAST,  held);

        // we low writes nothing. The word has to be read a cycle later, because
        // a read in the same cycle would see the old data anyway.
        step(1'b0, LAST, pattern(LAST),  1'b0, 0,     held);
        step(1'b0, 0, 0,                 1'b1, LAST,  ~pattern(LAST));

        // Read during a write of the same address: old data, then the new data.
        // Each read follows a read of another word, so rdata has to change.
        step(1'b0, 0, 0,                 1'b1, 0,     ~pattern(0));
        step(1'b1, LAST, pattern(LAST),  1'b1, LAST,  ~pattern(LAST));
        step(1'b0, 0, 0,                 1'b1, LAST,  pattern(LAST));

        // A write to another address does not disturb the read. pattern() is
        // ~addr, so the words at 0 and LAST are both 00 by now. These steps use
        // addresses 1 and LAST/2, so every word involved differs, and a read of
        // the wrong address or a missed read shows up.
        step(1'b0, 0, 0,                 1'b1, LAST/2, ~pattern(LAST/2));
        step(1'b1, 1, pattern(1),        1'b1, LAST,  pattern(LAST));
        step(1'b0, 0, 0,                 1'b1, 1,     pattern(1));

        // With re low, a write to the read address leaves rdata alone.
        step(1'b1, 1, ~pattern(1),       1'b0, 1,     pattern(1));

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
