`timescale 1ns/1ps

// Runs each program from build/*.hex and checks the final state against values
// worked out by hand. Then it tests illegal words, HALT and reset. Monitors below
// count clocks per instruction class, and check them against the table in the
// README. The only input a CPU has is rst, driven here on falling edges.
module tb_cpu;

    localparam integer TIMEOUT = 20000;

    // Instruction classes for the cycle table.
    localparam integer C_NOP = 0, C_HALT = 1, C_ALU = 2, C_CMP = 3, C_LD = 4, C_ST = 5,
                       C_JUMP = 6, C_BRANCH = 7, C_CALL = 8, C_RET = 9, C_PUSH = 10,
                       C_POP = 11, C_ILLEGAL = 12, CLASSES = 13;

    reg clk = 1'b0;
    reg rst = 1'b1;

    wire halted, illegal, retire;

    integer errors = 0;
    integer retired = 0;          // since the last reset
    integer clocks = 0;           // since the last reset
    integer since_retire = 0;     // clocks so far in this instruction
    integer total_retired = 0;
    integer seen, k, i;

    // Per class: how many ran, and the fewest and most clocks they took.
    integer class_seen[0:CLASSES-1];
    integer class_min[0:CLASSES-1];
    integer class_max[0:CLASSES-1];
    integer class_expected[0:CLASSES-1];

    // Each branch condition: seen taken, and seen not taken.
    reg [11:0] cond_taken = 12'd0;
    reg [11:0] cond_not_taken = 12'd0;

    reg        was_branch = 1'b0;
    reg [7:0]  branch_pc = 8'd0;
    reg [3:0]  branch_cond = 4'd0;
    reg        was_retire = 1'b0;

    cpu_top dut (.clk(clk), .rst(rst), .halted(halted), .illegal(illegal), .retire(retire));

    wire [7:0]  pc    = dut.u_cpu.retire_pc;
    wire [15:0] instr = dut.u_cpu.retire_instr;
    wire [3:0]  op    = instr[15:12];

    // Flags as one number: {z, c, n, v}.
    wire [3:0] flags = {dut.u_cpu.flag_z, dut.u_cpu.flag_c, dut.u_cpu.flag_n, dut.u_cpu.flag_v};

    always #5 clk = ~clk;

    function integer class_of(input [15:0] word);
        begin
            case (word[15:12])
                4'h0:    class_of = word[0] ? C_HALT : C_NOP;
                4'h1:    class_of = (word[3:0] == 4'd14) ? C_CMP : C_ALU;
                4'h4:    class_of = C_CMP;
                4'h6:    class_of = C_LD;
                4'h7:    class_of = C_ST;
                4'h8:    class_of = C_JUMP;
                4'h9:    class_of = C_BRANCH;
                4'hA:    class_of = C_CALL;
                4'hB:    class_of = C_RET;
                4'hC:    class_of = C_PUSH;
                4'hD:    class_of = C_POP;
                4'hE:    class_of = C_JUMP;
                default: class_of = C_ALU;  // LDI, ADDI, ANDI
            endcase
        end
    endfunction

    function [8*8-1:0] class_name(input integer index);
        begin
            case (index)
                C_NOP:     class_name = "NOP";
                C_HALT:    class_name = "HALT";
                C_ALU:     class_name = "ALU";
                C_CMP:     class_name = "CMP";
                C_LD:      class_name = "LD";
                C_ST:      class_name = "ST";
                C_JUMP:    class_name = "JMP/JR";
                C_BRANCH:  class_name = "Bcc";
                C_CALL:    class_name = "CALL";
                C_RET:     class_name = "RET";
                C_PUSH:    class_name = "PUSH";
                C_POP:     class_name = "POP";
                default:   class_name = "illegal";
            endcase
        end
    endfunction

    // Monitors. They read on the rising edge, before anything changes.
    always @(posedge clk) begin
        if (rst) begin
            since_retire <= 0;
            was_retire   <= 1'b0;
            was_branch   <= 1'b0;
            retired      <= 0;
            clocks       <= 0;
            if (dut.dmem_we === 1'b1 || retire === 1'b1) begin
                $display("FAIL t=%0t memory write or retire during reset", $time);
                errors = errors + 1;
            end
        end else begin
            if (!halted)
                clocks <= clocks + 1;
            was_retire <= retire;

            if (retire === 1'bx || halted === 1'bx) begin
                $display("FAIL t=%0t retire or halted is x", $time);
                errors = errors + 1;
            end

            if (retire && was_retire) begin
                $display("FAIL t=%0t retire high for two clocks", $time);
                errors = errors + 1;
            end

            if (retire) begin
                since_retire  <= 0;
                retired       <= retired + 1;
                total_retired <= total_retired + 1;

                seen = dut.u_cpu.dec_illegal ? C_ILLEGAL : class_of(instr);
                class_seen[seen] = class_seen[seen] + 1;
                if (since_retire + 1 < class_min[seen])
                    class_min[seen] = since_retire + 1;
                if (since_retire + 1 > class_max[seen])
                    class_max[seen] = since_retire + 1;

                // The instruction after a branch shows which way it went.
                if (was_branch) begin
                    if (pc == branch_pc + 8'd1)
                        cond_not_taken[branch_cond] = 1'b1;
                    else
                        cond_taken[branch_cond] = 1'b1;
                end
                was_branch  <= (op == 4'h9);
                branch_pc   <= pc;
                branch_cond <= instr[11:8];
            end else begin
                since_retire <= since_retire + 1;
            end
        end
    end

    task check_reg(input integer n, input [7:0] expected);
        begin
            if (dut.u_cpu.u_regfile.q[n] !== expected) begin
                $display("FAIL R%0d=%h expected=%h", n, dut.u_cpu.u_regfile.q[n], expected);
                errors = errors + 1;
            end
        end
    endtask

    task check_mem(input [7:0] addr, input [7:0] expected);
        begin
            if (dut.dmem[addr] !== expected) begin
                $display("FAIL mem[%h]=%h expected=%h", addr, dut.dmem[addr], expected);
                errors = errors + 1;
            end
        end
    endtask

    task check_flags(input [3:0] expected);
        begin
            if (flags !== expected) begin
                $display("FAIL zcnv=%b expected=%b", flags, expected);
                errors = errors + 1;
            end
        end
    endtask

    task check_end(input [7:0] expected_pc, input integer expected_retired);
        begin
            if (pc !== expected_pc || retired !== expected_retired) begin
                $display("FAIL pc=%h expected=%h, retired %0d expected=%0d",
                         pc, expected_pc, retired, expected_retired);
                errors = errors + 1;
            end
            if (halted !== 1'b1 || illegal !== 1'b0) begin
                $display("FAIL halted=%b illegal=%b", halted, illegal);
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
            @(negedge clk);
            @(negedge clk);
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

    task run(input [8*32-1:0] hex);
        begin
            $readmemh(hex, dut.imem);
            start;
            wait_for_halt;
            // One more edge, so the monitors see everything.
            @(negedge clk);
            $display("%0s: %0d instructions, %0d clocks", hex, retired, clocks);
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
            if (illegal !== 1'b1 || halted !== 1'b1 || pc !== 8'h00 || retired !== 1) begin
                $display("FAIL word %h: illegal=%b halted=%b pc=%h retired=%0d",
                         word, illegal, halted, pc, retired);
                errors = errors + 1;
            end
            if (flags !== 4'b0000 || dut.u_cpu.u_regfile.q[3] !== 8'h00) begin
                $display("FAIL word %h changed the state", word);
                errors = errors + 1;
            end
        end
    endtask

    initial begin
        $dumpfile("build/tb_cpu.vcd");
        $dumpvars(0, tb_cpu);

        // From the table in the README.
        class_expected[C_NOP]    = 4;
        class_expected[C_HALT]   = 4;
        class_expected[C_ALU]    = 6;
        class_expected[C_CMP]    = 5;
        class_expected[C_LD]     = 8;
        class_expected[C_ST]     = 6;
        class_expected[C_JUMP]   = 4;
        class_expected[C_BRANCH] = 4;
        class_expected[C_CALL]   = 7;
        class_expected[C_RET]    = 8;
        class_expected[C_PUSH]   = 7;
        class_expected[C_POP]    = 9;
        class_expected[C_ILLEGAL] = 4;

        for (i = 0; i < CLASSES; i = i + 1) begin
            class_seen[i] = 0;
            class_min[i]  = 1000;
            class_max[i]  = 0;
        end

        // 2 * (5 + 4 + 3 + 2 + 1), from Tutorial 16.
        run("build/demo.hex");
        check_end(8'h08, 51);
        check_mem(8'h80, 8'd30);
        check_mem(8'hEF, 8'h05);   // the return address
        check_mem(8'hEE, 8'h80);   // the saved R2
        check_reg(0, 8'd0);
        check_reg(1, 8'd30);
        check_reg(2, 8'h80);
        check_reg(3, 8'hF0);
        check_flags(4'b1100);      // ADDI R0, -1 from 1: zero, with a carry out

        // 0xE2F0FF + 0x1E0F01 = 0x01010000.
        run("build/add_multi.hex");
        check_end(8'h1C, 29);
        check_mem(8'h18, 8'h00);
        check_mem(8'h19, 8'h00);
        check_mem(8'h1A, 8'h01);
        check_mem(8'h1B, 8'h01);

        // Fourteen numbers. The sum that stops it is 144 + 233 = 377, or 121.
        run("build/fibonacci.hex");
        check_end(8'h0B, 94);      // 3 + 12 * 7 + 5 + 2
        check_mem(8'h40, 8'd0);
        check_mem(8'h41, 8'd1);
        check_mem(8'h42, 8'd1);
        check_mem(8'h43, 8'd2);
        check_mem(8'h44, 8'd3);
        check_mem(8'h45, 8'd5);
        check_mem(8'h46, 8'd8);
        check_mem(8'h47, 8'd13);
        check_mem(8'h48, 8'd21);
        check_mem(8'h49, 8'd34);
        check_mem(8'h4A, 8'd55);
        check_mem(8'h4B, 8'd89);
        check_mem(8'h4C, 8'd144);
        check_mem(8'h4D, 8'd233);
        check_mem(8'h4E, 8'd0);
        check_reg(0, 8'd144);
        check_reg(1, 8'd121);
        check_reg(2, 8'h4D);
        check_reg(3, 8'd233);

        // Seven nested calls: sum(6) down to sum(0).
        run("build/recursive_sum.hex");
        check_end(8'h05, 58);      // 6 + 6 * 8 + 4
        check_mem(8'h80, 8'd21);
        check_reg(0, 8'd6);
        check_reg(1, 8'd21);
        check_reg(3, 8'hF0);
        check_mem(8'hEF, 8'h03);   // return to the main program
        check_mem(8'hEE, 8'd6);    // the first saved R0
        check_mem(8'hED, 8'h0D);   // return into sum
        check_mem(8'hE4, 8'd1);    // the last saved R0
        check_mem(8'hE3, 8'h0D);   // the deepest return address
        check_mem(8'hE2, 8'h00);   // and nothing below it

        // 8 bytes, copied.
        run("build/memcpy.hex");
        check_end(8'h11, 88);      // 3 + 8 * 5 + 2 + 8 * 5 + 3
        for (k = 0; k < 8; k = k + 1) begin
            check_mem(8'h10 + k[7:0], 8'd7 + 8'd31 * k[7:0]);
            check_mem(8'h30 + k[7:0], 8'd7 + 8'd31 * k[7:0]);
        end
        check_reg(3, 8'd7);

        // All twelve conditions, taken and not taken.
        run("build/branches.hex");
        check_mem(8'h80, 8'hAA);
        check_mem(8'h81, 8'h00);
        if (cond_taken !== 12'hFFF || cond_not_taken !== 12'hFFF) begin
            $display("FAIL taken=%h not taken=%h", cond_taken, cond_not_taken);
            errors = errors + 1;
        end

        // The two rulings on R3.
        run("build/stack_r3.hex");
        check_end(8'h08, 9);
        check_reg(0, 8'hF0);
        check_reg(1, 8'hEF);
        check_reg(2, 8'h55);
        check_reg(3, 8'h55);
        check_mem(8'hEF, 8'hF0);
        check_mem(8'hEE, 8'h55);

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
        if (illegal !== 1'b0 || pc !== 8'h00) begin
            $display("FAIL HALT with junk fields");
            errors = errors + 1;
        end

        // Reset leaves HALT, and works in every state of a run. Each pass stops the
        // demo one clock later than the last, so all states are hit, and the
        // monitor checks that no reset ever writes memory.
        $readmemh("build/demo.hex", dut.imem);
        for (k = 0; k < 120; k = k + 1) begin
            start;
            repeat (k) @(negedge clk);
            rst = 1'b1;
            @(negedge clk);
            if (dut.u_cpu.pc !== 8'd0 || dut.u_cpu.state !== 4'd0 || flags !== 4'd0 ||
                dut.u_cpu.u_regfile.q[0] !== 8'd0 || dut.u_cpu.u_regfile.q[1] !== 8'd0 ||
                dut.u_cpu.u_regfile.q[2] !== 8'd0 || dut.u_cpu.u_regfile.q[3] !== 8'd0 ||
                halted !== 1'b0) begin
                $display("FAIL reset after %0d clocks", k);
                errors = errors + 1;
            end
        end

        // And a full run still works after all that.
        run("build/demo.hex");
        check_end(8'h08, 51);
        check_mem(8'h80, 8'd30);

        // Clocks per instruction, seen in the runs above.
        for (i = 0; i < CLASSES; i = i + 1) begin
            $display("%0s: %0d seen, %0d to %0d clocks", class_name(i), class_seen[i],
                     class_min[i], class_max[i]);
            if (class_seen[i] == 0 || class_min[i] != class_expected[i] ||
                class_max[i] != class_expected[i]) begin
                $display("FAIL class %0d expected %0d clocks", i, class_expected[i]);
                errors = errors + 1;
            end
        end

        if (errors == 0)
            $display("PASS: %0d instructions retired", total_retired);
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
