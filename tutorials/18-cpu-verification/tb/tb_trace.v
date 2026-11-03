`timescale 1ns/1ps

// Replays what the reference model did. tools/iss.py runs each program and writes one
// trace line per instruction. This testbench runs the same program on the CPU, and at
// every retire compares the state with the next line. It stops a program at its first
// difference. The only input a CPU has is rst, driven here on falling edges.
module tb_trace;

    localparam integer LINES   = 4096;
    localparam integer TIMEOUT = 40;      // most clocks between two retires

    // A trace line, 80 bits: pc, instr, R0 to R3, {z, c, n, v}, write, address, data.
    localparam [79:0] END_OF_TRACE = {80{1'b1}};

    reg clk = 1'b0;
    reg rst = 1'b1;

    wire halted, illegal, retire;

    reg [79:0] trace [0:LINES-1];

    integer errors = 0;
    integer total  = 0;
    integer line   = 0;       // the next trace line
    integer idle   = 0;       // clocks since the last retire
    reg     stop   = 1'b0;    // this program is finished, or has failed

    // A memory write waits here for its instruction to retire.
    reg       wrote      = 1'b0;
    reg [7:0] wrote_addr = 8'd0;
    reg [7:0] wrote_data = 8'd0;

    cpu_top dut (.clk(clk), .rst(rst), .halted(halted), .illegal(illegal), .retire(retire));

    // Paths into the design, as in the Python checker.
    wire [7:0]  pc    = dut.u_cpu.retire_pc;
    wire [15:0] instr = dut.u_cpu.retire_instr;
    wire [7:0]  r0    = dut.u_cpu.u_regfile.q[0];
    wire [7:0]  r1    = dut.u_cpu.u_regfile.q[1];
    wire [7:0]  r2    = dut.u_cpu.u_regfile.q[2];
    wire [7:0]  r3    = dut.u_cpu.u_regfile.q[3];
    wire [3:0]  flags = {dut.u_cpu.flag_z, dut.u_cpu.flag_c, dut.u_cpu.flag_n, dut.u_cpu.flag_v};

    wire [15:0] wrote_op = wrote ? {wrote_addr, wrote_data} : 16'd0;
    wire [79:0] got      = {pc, instr, r0, r1, r2, r3, flags, 3'b000, wrote, wrote_op};
    wire [79:0] expected = trace[line];

    always #5 clk = ~clk;

    // Monitors. They read on the rising edge, before anything changes.
    always @(posedge clk) begin
        if (rst) begin
            wrote <= 1'b0;
            idle  <= 0;
        end else if (!stop) begin
            if (dut.dmem_we === 1'b1) begin
                wrote      <= 1'b1;
                wrote_addr <= dut.dmem_addr;
                wrote_data <= dut.dmem_wdata;
            end

            if (retire === 1'b1) begin
                idle  <= 0;
                wrote <= 1'b0;
                if (got !== expected) begin
                    $display("FAIL instruction %0d", line);
                    $display("  model pc=%h instr=%h R=%h %h %h %h zcnv=%b write=%b %h %h",
                             expected[79:72], expected[71:56], expected[55:48], expected[47:40],
                             expected[39:32], expected[31:24], expected[23:20], expected[16],
                             expected[15:8], expected[7:0]);
                    $display("  cpu   pc=%h instr=%h R=%h %h %h %h zcnv=%b write=%b %h %h",
                             pc, instr, r0, r1, r2, r3, flags, wrote, wrote_addr, wrote_data);
                    errors = errors + 1;
                    stop = 1'b1;
                end
                line  = line + 1;
                total = total + 1;
            end else begin
                idle <= idle + 1;
                if (idle > TIMEOUT) begin
                    $display("FAIL nothing retired for %0d clocks at line %0d", TIMEOUT, line);
                    errors = errors + 1;
                    stop = 1'b1;
                end
            end

            if (halted === 1'b1)
                stop = 1'b1;
        end
    end

    // Runs one program from reset, and checks that the whole trace was used.
    task run(input [8*32-1:0] hex, input [8*32-1:0] golden);
        begin
            @(negedge clk);
            rst = 1'b1;
            $readmemh(hex, dut.imem);
            $readmemh(golden, trace);
            $readmemh("build/empty.hex", dut.dmem);
            line = 0;
            stop = 1'b0;
            @(negedge clk);
            @(negedge clk);
            rst = 1'b0;

            while (!stop)
                @(negedge clk);

            if (errors == 0 && expected !== END_OF_TRACE) begin
                $display("FAIL halted after %0d instructions, but the trace goes on", line);
                errors = errors + 1;
            end
            if (errors == 0 && (halted !== 1'b1 || illegal !== 1'b0)) begin
                $display("FAIL halted=%b illegal=%b at the end", halted, illegal);
                errors = errors + 1;
            end
            $display("%0s: %0d instructions compared", hex, line);
        end
    endtask

    initial begin
        $dumpfile("build/tb_trace.vcd");
        $dumpvars(0, tb_trace);

        run("build/demo.hex", "build/demo.trace");
        run("build/add_multi.hex", "build/add_multi.trace");
        run("build/fibonacci.hex", "build/fibonacci.trace");
        run("build/recursive_sum.hex", "build/recursive_sum.trace");
        run("build/memcpy.hex", "build/memcpy.trace");
        run("build/branches.hex", "build/branches.trace");
        run("build/stack_r3.hex", "build/stack_r3.trace");
        run("build/overwrite.hex", "build/overwrite.trace");
        run("build/corners.hex", "build/corners.trace");

        if (errors == 0)
            $display("PASS: %0d instructions matched the model", total);
        else
            $fatal(1, "FAIL: %0d programs differed", errors);
        $finish;
    end

endmodule
