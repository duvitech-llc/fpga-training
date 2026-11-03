`timescale 1ns/1ps

// Runs every program from build/*.hex. At each retire the state is compared with the
// reference model's trace, and at the end the results are checked against values worked
// out by hand, and the clocks against a limit. Then it tests illegal words, HALT, and
// reset. The only input a CPU has is rst, driven here on falling edges.
module tb_cpu;

    localparam integer LINES   = 4096;
    localparam integer TIMEOUT = 5000;    // clocks
    localparam integer MAX_GAP = 8;       // most clocks between two retires

    // A trace line, 80 bits: pc, instr, R0 to R3, {z, c, n, v}, write, address, data.
    localparam [79:0] END_OF_TRACE = {80{1'b1}};

    reg clk = 1'b0;
    reg rst = 1'b1;

    wire halted, illegal, retire;

    reg [79:0] trace [0:LINES-1];

    integer errors = 0;
    integer total_retired = 0, total_clocks = 0;
    integer line = 0;          // the next trace line, and so the instructions so far
    integer clocks = 0;        // since reset
    integer gap = 0;           // clocks since the last retire
    integer k;
    reg     use_trace = 1'b0;  // compare retires with the trace
    reg     was_retire = 1'b0;

    // Memory is used in MEM, which is two clocks before that instruction's retire, and
    // nothing can come between. So a memory access with no retire to go with it, or a
    // retire with the wrong access, is an instruction that should not have been there.
    reg       we_1 = 1'b0, we_2 = 1'b0, re_1 = 1'b0, re_2 = 1'b0;
    reg [7:0] addr_1, addr_2, data_1, data_2;

    cpu_top dut (.clk(clk), .rst(rst), .halted(halted), .illegal(illegal), .retire(retire));

    wire [7:0]  pc    = dut.u_cpu.retire_pc;
    wire [15:0] instr = dut.u_cpu.retire_instr;
    wire [3:0]  op    = instr[15:12];
    wire [7:0]  r0    = dut.u_cpu.u_regfile.q[0];
    wire [7:0]  r1    = dut.u_cpu.u_regfile.q[1];
    wire [7:0]  r2    = dut.u_cpu.u_regfile.q[2];
    wire [7:0]  r3    = dut.u_cpu.u_regfile.q[3];
    wire [3:0]  flags = dut.u_cpu.flags_reg;

    wire [15:0] wrote_op = we_2 ? {addr_2, data_2} : 16'd0;
    wire [79:0] got      = {pc, instr, r0, r1, r2, r3, flags, 3'b000, we_2, wrote_op};
    wire [79:0] expected = trace[line];

    wire reads_memory = (op == 4'h6) || (op == 4'hB) || (op == 4'hD);   // LD, RET, POP

    always #5 clk = ~clk;

    // Monitors. They read on the rising edge, before anything changes.
    always @(posedge clk) begin
        we_1   <= !rst && dut.dmem_we === 1'b1;
        we_2   <= we_1;
        re_1   <= !rst && dut.dmem_re === 1'b1;
        re_2   <= re_1;
        addr_1 <= dut.dmem_addr;
        addr_2 <= addr_1;
        data_1 <= dut.dmem_wdata;
        data_2 <= data_1;
        was_retire <= retire;

        if (rst) begin
            gap <= 0;
            if (dut.dmem_we === 1'b1 || dut.dmem_re === 1'b1 || retire === 1'b1) begin
                $display("FAIL t=%0t memory or retire during reset", $time);
                errors = errors + 1;
            end
        end else begin
            clocks <= clocks + 1;

            if (retire === 1'bx || halted === 1'bx || dut.dmem_we === 1'bx || dut.dmem_re === 1'bx) begin
                $display("FAIL t=%0t a control output is x", $time);
                errors = errors + 1;
            end

            if ((we_2 || re_2) && retire !== 1'b1) begin
                $display("FAIL t=%0t memory was used by an instruction that did not retire", $time);
                errors = errors + 1;
            end

            if (retire === 1'b1) begin
                gap <= 0;
                if (re_2 !== reads_memory) begin
                    $display("FAIL t=%0t pc=%h instr=%h memory read=%b", $time, pc, instr, re_2);
                    errors = errors + 1;
                end
                if (use_trace && got !== expected) begin
                    $display("FAIL instruction %0d", line);
                    $display("  model pc=%h instr=%h R=%h %h %h %h zcnv=%b write=%b %h %h",
                             expected[79:72], expected[71:56], expected[55:48], expected[47:40],
                             expected[39:32], expected[31:24], expected[23:20], expected[16],
                             expected[15:8], expected[7:0]);
                    $display("  cpu   pc=%h instr=%h R=%h %h %h %h zcnv=%b write=%b %h %h",
                             pc, instr, r0, r1, r2, r3, flags, we_2, addr_2, data_2);
                    errors = errors + 1;
                end
                line = line + 1;
            end else if (!halted) begin
                gap <= gap + 1;
                if (gap > MAX_GAP) begin
                    $display("FAIL t=%0t nothing retired for %0d clocks", $time, gap);
                    errors = errors + 1;
                end
            end

            if (halted === 1'b1 && retire === 1'b1) begin
                $display("FAIL t=%0t a retire while halted", $time);
                errors = errors + 1;
            end
        end
    end

    task check_reg(input integer n, input [7:0] want);
        begin
            if (dut.u_cpu.u_regfile.q[n] !== want) begin
                $display("FAIL R%0d=%h expected=%h", n, dut.u_cpu.u_regfile.q[n], want);
                errors = errors + 1;
            end
        end
    endtask

    task check_mem(input [7:0] addr, input [7:0] want);
        begin
            if (dut.dmem[addr] !== want) begin
                $display("FAIL mem[%h]=%h expected=%h", addr, dut.dmem[addr], want);
                errors = errors + 1;
            end
        end
    endtask

    task check_flags(input [3:0] want);
        begin
            if (flags !== want) begin
                $display("FAIL zcnv=%b expected=%b", flags, want);
                errors = errors + 1;
            end
        end
    endtask

    // Empties data memory, and holds reset for two clocks.
    task start;
        begin
            @(negedge clk);
            rst = 1'b1;
            $readmemh("build/empty.hex", dut.dmem);
            line = 0;
            @(negedge clk);
            @(negedge clk);
            clocks = 0;
            rst = 1'b0;
        end
    endtask

    // Waits for halted, with a limit so a bad design cannot hang the test.
    task wait_for_halt;
        integer limit;
        begin
            limit = 0;
            while (halted !== 1'b1 && limit < TIMEOUT) begin
                @(negedge clk);
                limit = limit + 1;
            end
            if (halted !== 1'b1) begin
                $display("FAIL no halt after %0d clocks, pc=%h", TIMEOUT, dut.u_cpu.pc);
                errors = errors + 1;
            end
        end
    endtask

    // A run with imem already loaded. The limit is on clocks from reset to halted.
    task run_loaded(input [8*32-1:0] golden, input integer limit);
        integer spent;
        begin
            $readmemh(golden, trace);
            use_trace = 1'b1;
            start;
            wait_for_halt;
            spent = clocks;
            // The monitors have one clock of work left, and four more show that it stays.
            repeat (5) @(negedge clk);
            use_trace = 1'b0;

            if (trace[line] !== END_OF_TRACE) begin
                $display("FAIL stopped after %0d instructions, but the trace goes on", line);
                errors = errors + 1;
            end
            if (halted !== 1'b1 || illegal !== 1'b0) begin
                $display("FAIL halted=%b illegal=%b at the end", halted, illegal);
                errors = errors + 1;
            end
            if (spent > limit) begin
                $display("FAIL %0d clocks, and the limit is %0d", spent, limit);
                errors = errors + 1;
            end
            $display("%0s: %0d instructions, %0d clocks", golden, line, spent);
            total_retired = total_retired + line;
            total_clocks  = total_clocks + spent;
        end
    endtask

    task run(input [8*32-1:0] hex, input [8*32-1:0] golden, input integer limit);
        begin
            $readmemh(hex, dut.imem);
            run_loaded(golden, limit);
        end
    endtask

    // An illegal word at address 0 stops the CPU at once, and changes nothing.
    task check_illegal(input [15:0] word);
        begin
            $readmemh("build/stack_r3.hex", dut.imem);
            dut.imem[0] = word;
            start;
            wait_for_halt;
            repeat (3) @(negedge clk);
            if (illegal !== 1'b1 || halted !== 1'b1 || pc !== 8'h00 || line !== 1 ||
                dut.u_cpu.pc !== 8'h00) begin
                $display("FAIL word %h: illegal=%b halted=%b pc=%h retired=%0d",
                         word, illegal, halted, pc, line);
                errors = errors + 1;
            end
            if (flags !== 4'b0000 || r3 !== 8'h00) begin
                $display("FAIL word %h changed the state", word);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("build/tb_cpu.vcd");
        $dumpvars(0, tb_cpu);

        // The limits are what this design measures. Every extra stall fails.
        run("build/demo.hex", "build/demo.trace", 99);
        check_mem(8'h80, 8'd30);
        check_mem(8'hEF, 8'h05);   // the return address
        check_mem(8'hEE, 8'h80);   // the saved R2
        check_reg(0, 8'd0);
        check_reg(1, 8'd30);
        check_reg(2, 8'h80);
        check_reg(3, 8'hF0);
        check_flags(4'b1100);      // ADDI R0, -1 from 1: zero, with a carry out

        // 0xE2F0FF + 0x1E0F01 = 0x01010000.
        run("build/add_multi.hex", "build/add_multi.trace", 37);
        check_mem(8'h18, 8'h00);
        check_mem(8'h19, 8'h00);
        check_mem(8'h1A, 8'h01);
        check_mem(8'h1B, 8'h01);

        // Fourteen numbers. The sum that stops it is 144 + 233 = 377, or 121.
        run("build/fibonacci.hex", "build/fibonacci.trace", 125);
        check_mem(8'h40, 8'd0);
        check_mem(8'h44, 8'd3);
        check_mem(8'h4C, 8'd144);
        check_mem(8'h4D, 8'd233);
        check_mem(8'h4E, 8'd0);
        check_reg(1, 8'd121);

        // Seven nested calls: sum(6) down to sum(0).
        run("build/recursive_sum.hex", "build/recursive_sum.trace", 129);
        check_mem(8'h80, 8'd21);
        check_reg(1, 8'd21);
        check_reg(3, 8'hF0);
        check_mem(8'hEF, 8'h03);   // return to the main program
        check_mem(8'hE3, 8'h0D);   // the deepest return address
        check_mem(8'hE2, 8'h00);   // and nothing below it

        // 8 bytes, copied.
        run("build/memcpy.hex", "build/memcpy.trace", 129);
        for (k = 0; k < 8; k = k + 1) begin
            check_mem(8'h10 + k[7:0], 8'd7 + 8'd31 * k[7:0]);
            check_mem(8'h30 + k[7:0], 8'd7 + 8'd31 * k[7:0]);
        end

        // All twelve conditions, taken and not taken.
        run("build/branches.hex", "build/branches.trace", 104);
        check_mem(8'h80, 8'hAA);
        check_mem(8'h81, 8'h00);

        // The two rulings on R3.
        run("build/stack_r3.hex", "build/stack_r3.trace", 16);
        check_reg(0, 8'hF0);
        check_reg(1, 8'hEF);
        check_reg(2, 8'h55);
        check_reg(3, 8'h55);
        check_mem(8'hEF, 8'hF0);
        check_mem(8'hEE, 8'h55);

        run("build/overwrite.hex", "build/overwrite.trace", 14);
        run("build/corners.hex", "build/corners.trace", 61);

        // This lesson's programs.
        run("build/hazard_alu.hex", "build/hazard_alu.trace", 23);
        check_mem(8'h40, 8'd3);
        check_mem(8'h41, 8'd13);
        check_mem(8'h42, 8'd23);
        check_mem(8'h43, 8'd33);

        run("build/hazard_load.hex", "build/hazard_load.trace", 23);
        check_mem(8'h40, 8'd7);
        check_mem(8'h41, 8'd8);
        check_mem(8'h42, 8'd7);
        check_mem(8'h43, 8'h40);
        check_mem(8'h44, 8'd8);

        run("build/hazard_flags.hex", "build/hazard_flags.trace", 24);
        check_mem(8'h40, 8'h01);
        check_mem(8'h41, 8'h00);
        check_mem(8'h42, 8'hAA);

        run("build/hazard_branch.hex", "build/hazard_branch.trace", 45);
        check_mem(8'h40, 8'h00);
        check_mem(8'h41, 8'h77);

        // The same again, with illegal words over the wrong-path HALTs. They are fetched
        // and flushed, so nothing may change. There are four, at 0C, 0F, 16 and 23, and
        // each gets a different kind of illegal word.
        $readmemh("build/hazard_branch.hex", dut.imem);
        for (k = 0; k < 256; k = k + 1)
            if (dut.imem[k] == 16'h0001) begin
                if (k != 29)               // the one real HALT
                    dut.imem[k] = (k < 8'h0E) ? 16'hF000 : (k < 8'h10) ? 16'h0002 :
                                  (k < 8'h18) ? 16'h100F : 16'h9C10;
            end
        run_loaded("build/hazard_branch.trace", 45);
        check_mem(8'h40, 8'h00);
        check_mem(8'h41, 8'h77);

        run("build/hazard_stack.hex", "build/hazard_stack.trace", 43);
        check_mem(8'h40, 8'h12);
        check_mem(8'h41, 8'h34);
        check_mem(8'h42, 8'h12);
        check_mem(8'h43, 8'hEE);
        check_mem(8'h44, 8'hF0);
        check_reg(3, 8'hF0);

        // The four kinds of illegal word.
        check_illegal(16'h0002);   // op 0 with imm above 1
        check_illegal(16'h100F);   // op 1 with funct 15
        check_illegal(16'h9C10);   // op 9 with cond 12
        check_illegal(16'hF000);   // op F

        // HALT with junk in the fields it ignores.
        $readmemh("build/stack_r3.hex", dut.imem);
        dut.imem[0] = 16'h0701;
        start;
        wait_for_halt;
        repeat (3) @(negedge clk);
        if (illegal !== 1'b0 || pc !== 8'h00 || dut.u_cpu.pc !== 8'h00 || line !== 1) begin
            $display("FAIL HALT with junk fields");
            errors = errors + 1;
        end

        // Reset leaves HALT, and works at every point of a run, so a reset arrives with
        // every mix of instructions in the pipeline. The monitors check that none of
        // them writes memory or retires, and the run after each one must still be right.
        $readmemh("build/demo.hex", dut.imem);
        for (k = 0; k < 100; k = k + 1) begin
            start;
            repeat (k) @(negedge clk);
            rst = 1'b1;
            @(negedge clk);
            if (dut.u_cpu.pc !== 8'd0 || flags !== 4'd0 || r0 !== 8'd0 || r1 !== 8'd0 ||
                r2 !== 8'd0 || r3 !== 8'd0 || halted !== 1'b0) begin
                $display("FAIL reset after %0d clocks", k);
                errors = errors + 1;
            end
        end

        // And a full run still works after all that.
        run("build/demo.hex", "build/demo.trace", 99);
        check_mem(8'h80, 8'd30);

        if (errors == 0)
            $display("PASS: %0d instructions retired in %0d clocks", total_retired, total_clocks);
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
