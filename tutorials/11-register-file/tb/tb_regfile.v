`timescale 1ns/1ps

module tb_regfile;

    parameter WIDTH = 8;
    parameter REGS  = 4;

    localparam integer ADDR_BITS = $clog2(REGS);
    localparam integer SLOTS     = 1 << ADDR_BITS;  // includes addresses with no register
    localparam [ADDR_BITS:0] LIMIT = REGS[ADDR_BITS:0];  // wide enough to compare with an address

    reg                  clk     = 1'b0;
    reg                  rst     = 1'b1;
    reg                  we      = 1'b0;
    reg  [ADDR_BITS-1:0] waddr   = 0;
    reg  [WIDTH-1:0]     wdata   = 0;
    reg  [ADDR_BITS-1:0] raddr_a = 0;
    reg  [ADDR_BITS-1:0] raddr_b = 0;
    wire [WIDTH-1:0]     rdata_a;
    wire [WIDTH-1:0]     rdata_b;

    // What each register should hold.
    reg [WIDTH-1:0] model [0:REGS-1];

    integer errors = 0;
    integer i;
    integer j;
    integer k;

    regfile #(.WIDTH(WIDTH), .REGS(REGS)) dut (
        .clk(clk), .rst(rst), .we(we), .waddr(waddr), .wdata(wdata),
        .raddr_a(raddr_a), .rdata_a(rdata_a),
        .raddr_b(raddr_b), .rdata_b(rdata_b)
    );

    always #5 clk = ~clk;

    // Compares both read ports with the model. !== also catches x or z.
    task check_reads;
        reg [WIDTH-1:0] expected_a;
        reg [WIDTH-1:0] expected_b;
        begin
            expected_a = {WIDTH{1'b0}};
            expected_b = {WIDTH{1'b0}};
            if ({1'b0, raddr_a} < LIMIT)
                expected_a = model[raddr_a];
            if ({1'b0, raddr_b} < LIMIT)
                expected_b = model[raddr_b];
            if (rdata_a !== expected_a) begin
                $display("FAIL t=%0t raddr_a=%0d rdata_a=%h expected=%h",
                         $time, raddr_a, rdata_a, expected_a);
                errors = errors + 1;
            end
            if (rdata_b !== expected_b) begin
                $display("FAIL t=%0t raddr_b=%0d rdata_b=%h expected=%h",
                         $time, raddr_b, rdata_b, expected_b);
                errors = errors + 1;
            end
        end
    endtask

    // Call just after a falling edge, and each call takes one clock cycle. The
    // reads are combinational, so they are checked before the rising edge, which
    // means against the old values, and again after it.
    task step(input r, input w, input [ADDR_BITS-1:0] wa, input [WIDTH-1:0] wd,
              input [ADDR_BITS-1:0] ra, input [ADDR_BITS-1:0] rb);
        begin
            rst     = r;
            we      = w;
            waddr   = wa;
            wdata   = wd;
            raddr_a = ra;
            raddr_b = rb;
            #1;
            check_reads;
            @(negedge clk);
            if (r) begin
                for (j = 0; j < REGS; j = j + 1)
                    model[j] = {WIDTH{1'b0}};
            end else if (w && {1'b0, wa} < LIMIT) begin
                model[wa] = wd;
            end
            check_reads;
        end
    endtask

    // Reads every address on both ports, in opposite orders, with no writes.
    task read_all;
        begin
            for (k = 0; k < SLOTS; k = k + 1)
                step(1'b0, 1'b0, k[ADDR_BITS-1:0], ~wdata,
                     k[ADDR_BITS-1:0], ~k[ADDR_BITS-1:0]);
        end
    endtask

    initial begin
        $dumpfile("build/tb_regfile.vcd");
        $dumpvars(0, tb_regfile);

        for (i = 0; i < REGS; i = i + 1)
            model[i] = {WIDTH{1'b0}};

        // rst is high from time 0, so the first rising edge clears everything.
        @(negedge clk);
        read_all;

        // Two patterns, so that each bit is seen at 0 and at 1. One write at a
        // time, so a write that also lands elsewhere is seen by the read_all.
        for (i = 0; i < REGS; i = i + 1) begin
            step(1'b0, 1'b1, i[ADDR_BITS-1:0], i[WIDTH-1:0] + 1'b1, 0, 0);
            read_all;
        end
        for (i = REGS - 1; i >= 0; i = i - 1) begin
            step(1'b0, 1'b1, i[ADDR_BITS-1:0], ~i[WIDTH-1:0], 0, 0);
            read_all;
        end

        // Read during write: old value before the edge, new value after it.
        for (i = 0; i < REGS; i = i + 1)
            step(1'b0, 1'b1, i[ADDR_BITS-1:0], i[WIDTH-1:0],
                 i[ADDR_BITS-1:0], i[ADDR_BITS-1:0]);

        // A write to an address with no register changes nothing.
        for (i = REGS; i < SLOTS; i = i + 1) begin
            step(1'b0, 1'b1, i[ADDR_BITS-1:0], {WIDTH{1'b1}}, 0, 0);
            read_all;
        end

        // rst beats we, reads keep the old value until the edge, and every
        // register is then 0.
        step(1'b1, 1'b1, 0, {WIDTH{1'b1}}, 1, 0);
        read_all;

        // The registers still work after a reset.
        step(1'b0, 1'b1, 1, {WIDTH{1'b1}}, 1, 1);
        read_all;

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
