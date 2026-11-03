`timescale 1ns/1ps

// Measures every program at one value of STEP. "make cpi" runs this at each value.
// A build with hazards left in is expected to go wrong, so this one does not stop at a
// difference. It compares each retire with the reference model's trace, and reports what
// happened. The only input a CPU has is rst, driven here on falling edges.
//
// At the end it fails unless the number of programs right is the one in the README for
// this STEP, and for STEP 2 to 4, where all 14 are right, unless the clocks for all of
// them are within what this design measures. So a slower CPU fails, as in tb_cpu.v.
module tb_cpi;

    parameter STEP = 4;

    localparam integer PROGRAMS = 14;
    localparam integer EXPECT_RIGHT = (STEP == 0) ? 0 : (STEP == 1) ? 1 : PROGRAMS;
    localparam integer MAX_CLOCKS   = (STEP == 2) ? 1404 : (STEP == 3) ? 1033 :
                                      (STEP == 4) ? 872  : 0;

    localparam integer LINES   = 4096;
    localparam integer TIMEOUT = 6000;    // clocks. A build that goes wrong may never halt

    localparam [79:0] END_OF_TRACE = {80{1'b1}};

    reg clk = 1'b0;
    reg rst = 1'b1;

    wire halted, illegal, retire;

    reg [79:0] trace [0:LINES-1];

    integer line = 0;              // the next trace line
    integer clocks = 0;
    integer wrong_at = -1;         // the first line that differed
    reg [79:0] wrong_got, wrong_exp;
    integer good_runs = 0, all_instructions = 0, all_clocks = 0;

    // A write reaches retire two clocks after MEM. These line the two up.
    reg       we_1 = 1'b0, we_2 = 1'b0;
    reg [7:0] addr_1, addr_2, data_1, data_2;

    cpu_top #(.STEP(STEP)) dut (.clk(clk), .rst(rst), .halted(halted), .illegal(illegal),
                                .retire(retire));

    wire [7:0]  pc    = dut.u_cpu.retire_pc;
    wire [15:0] instr = dut.u_cpu.retire_instr;
    wire [7:0]  r0    = dut.u_cpu.u_regfile.q[0];
    wire [7:0]  r1    = dut.u_cpu.u_regfile.q[1];
    wire [7:0]  r2    = dut.u_cpu.u_regfile.q[2];
    wire [7:0]  r3    = dut.u_cpu.u_regfile.q[3];
    wire [3:0]  flags = dut.u_cpu.flags_reg;

    wire [15:0] wrote_op = we_2 ? {addr_2, data_2} : 16'd0;
    wire [79:0] got      = {pc, instr, r0, r1, r2, r3, flags, 3'b000, we_2, wrote_op};

    always #5 clk = ~clk;

    always @(posedge clk) begin
        we_1   <= !rst && dut.dmem_we === 1'b1;
        we_2   <= we_1;
        addr_1 <= dut.dmem_addr;
        addr_2 <= addr_1;
        data_1 <= dut.dmem_wdata;
        data_2 <= data_1;

        if (!rst) begin
            clocks <= clocks + 1;
            if (retire === 1'b1) begin
                if (wrong_at < 0 && got !== trace[line]) begin
                    wrong_at  = line;
                    wrong_got = got;
                    wrong_exp = trace[line];
                end
                if (line < LINES - 1)
                    line = line + 1;
            end
        end
    end

    task run(input [8*32-1:0] hex, input [8*32-1:0] golden);
        integer limit;
        begin
            @(negedge clk);
            rst = 1'b1;
            $readmemh(hex, dut.imem);
            $readmemh(golden, trace);
            $readmemh("build/empty.hex", dut.dmem);
            line = 0;
            wrong_at = -1;
            @(negedge clk);
            @(negedge clk);
            clocks = 0;
            rst = 1'b0;

            limit = 0;
            while (halted !== 1'b1 && limit < TIMEOUT) begin
                @(negedge clk);
                limit = limit + 1;
            end

            if (halted !== 1'b1)
                $display("STEP=%0d %0s: WRONG, did not halt in %0d clocks", STEP, hex, TIMEOUT);
            else if (wrong_at >= 0)
                $display("STEP=%0d %0s: WRONG at instruction %0d", STEP, hex, wrong_at);
            else if (trace[line] !== END_OF_TRACE)
                $display("STEP=%0d %0s: WRONG, stopped at instruction %0d", STEP, hex, line);
            else begin
                $display("STEP=%0d %0s: right, %0d instructions, %0d clocks, CPI %0d.%02d", STEP,
                         hex, line, limit, limit / line, (limit * 100 / line) % 100);
                good_runs = good_runs + 1;
                all_instructions = all_instructions + line;
                all_clocks = all_clocks + limit;
            end

            if (wrong_at >= 0) begin
                $display("  model pc=%h instr=%h R0-R3=%h %h %h %h zcnv=%b write=%b %h %h",
                         wrong_exp[79:72], wrong_exp[71:56], wrong_exp[55:48], wrong_exp[47:40],
                         wrong_exp[39:32], wrong_exp[31:24], wrong_exp[23:20], wrong_exp[16],
                         wrong_exp[15:8], wrong_exp[7:0]);
                $display("  cpu   pc=%h instr=%h R0-R3=%h %h %h %h zcnv=%b write=%b %h %h",
                         wrong_got[79:72], wrong_got[71:56], wrong_got[55:48], wrong_got[47:40],
                         wrong_got[39:32], wrong_got[31:24], wrong_got[23:20], wrong_got[16],
                         wrong_got[15:8], wrong_got[7:0]);
            end
        end
    endtask

    initial begin
        run("build/demo.hex", "build/demo.trace");
        run("build/add_multi.hex", "build/add_multi.trace");
        run("build/fibonacci.hex", "build/fibonacci.trace");
        run("build/recursive_sum.hex", "build/recursive_sum.trace");
        run("build/memcpy.hex", "build/memcpy.trace");
        run("build/branches.hex", "build/branches.trace");
        run("build/stack_r3.hex", "build/stack_r3.trace");
        run("build/overwrite.hex", "build/overwrite.trace");
        run("build/corners.hex", "build/corners.trace");
        run("build/hazard_alu.hex", "build/hazard_alu.trace");
        run("build/hazard_load.hex", "build/hazard_load.trace");
        run("build/hazard_flags.hex", "build/hazard_flags.trace");
        run("build/hazard_branch.hex", "build/hazard_branch.trace");
        run("build/hazard_stack.hex", "build/hazard_stack.trace");

        if (good_runs > 0)
            $display("STEP=%0d: %0d of %0d programs right, %0d instructions, %0d clocks, CPI %0d.%02d",
                     STEP, good_runs, PROGRAMS, all_instructions, all_clocks,
                     all_clocks / all_instructions, (all_clocks * 100 / all_instructions) % 100);
        else
            $display("STEP=%0d: 0 of %0d programs right", STEP, PROGRAMS);

        if (good_runs != EXPECT_RIGHT)
            $fatal(1, "FAIL STEP=%0d: %0d programs right, and there should be %0d", STEP,
                   good_runs, EXPECT_RIGHT);
        if (MAX_CLOCKS > 0 && all_clocks > MAX_CLOCKS)
            $fatal(1, "FAIL STEP=%0d: %0d clocks, and the limit is %0d", STEP, all_clocks,
                   MAX_CLOCKS);
        $finish;
    end

endmodule
