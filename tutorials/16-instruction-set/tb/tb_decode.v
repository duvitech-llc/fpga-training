`timescale 1ns/1ps

// Tries every 16-bit instruction word with every value of the four flags, and
// compares every output against a table written from the spec. The table uses
// plain integers and rows of constants, so it shares no expression with decode.
module tb_decode;

    // decode has no clock. This one only paces the test: a new input on each
    // falling edge, checked before the next, as with the clocked designs.
    reg         clk = 1'b0;
    reg  [15:0] instr;
    reg         z, c, n, v;

    wire [1:0]  rd, rs, reg_waddr;
    wire [7:0]  imm;
    wire [3:0]  alu_op;
    wire        alu_src_imm, reg_we, flags_we, mem_read, mem_write;
    wire        branch_taken, jump, call, ret, push, pop, jr, halt, illegal;
    wire        pc_sel_next, pc_sel_imm, pc_sel_rs, pc_sel_stack, pc_sel_hold;

    decode dut (.instr(instr), .z(z), .c(c), .n(n), .v(v),
                .rd(rd), .rs(rs), .imm(imm),
                .alu_op(alu_op), .alu_src_imm(alu_src_imm),
                .reg_we(reg_we), .reg_waddr(reg_waddr), .flags_we(flags_we),
                .mem_read(mem_read), .mem_write(mem_write),
                .branch_taken(branch_taken), .jump(jump), .call(call), .ret(ret),
                .push(push), .pop(pop), .jr(jr), .halt(halt), .illegal(illegal),
                .pc_sel_next(pc_sel_next), .pc_sel_imm(pc_sel_imm), .pc_sel_rs(pc_sel_rs),
                .pc_sel_stack(pc_sel_stack), .pc_sel_hold(pc_sel_hold));

    always #5 clk = ~clk;

    // Worked out from the spec: see "Simulate" in the README.
    localparam integer ALL_INPUTS    = 1048576;
    localparam integer ILLEGAL_WORDS = 9440;
    localparam integer TAKEN_INPUTS  = 24576;

    // One row per op. The groups are, from the left:
    //   reg_we flags_we mem_read mem_write
    //   jump call ret push pop jr
    //   alu_src_imm
    //   alu_op
    //   pc_sel_next _imm _rs _stack _hold
    function [19:0] control(input integer o);
        case (o)
            0:       control = 20'b0000_000000_0_0000_10000;  // NOP
            1:       control = 20'b1100_000000_0_0000_10000;  // ALU, alu_op comes later
            2:       control = 20'b1000_000000_1_1101_10000;  // LDI
            3:       control = 20'b1100_000000_1_0000_10000;  // ADDI
            4:       control = 20'b0100_000000_1_0010_10000;  // CMPI
            5:       control = 20'b1100_000000_1_0100_10000;  // ANDI
            6:       control = 20'b1010_000000_0_0000_10000;  // LD
            7:       control = 20'b0001_000000_0_0000_10000;  // ST
            8:       control = 20'b0000_100000_0_0000_01000;  // JMP
            9:       control = 20'b0000_000000_0_0000_10000;  // Bcc, not taken
            10:      control = 20'b0001_010000_0_0000_01000;  // CALL
            11:      control = 20'b0010_001000_0_0000_00010;  // RET
            12:      control = 20'b0001_000100_0_0000_10000;  // PUSH
            13:      control = 20'b1010_000010_0_0000_10000;  // POP
            14:      control = 20'b0000_000001_0_0000_00100;  // JR
            default: control = 20'b0000_000000_0_0000_00001;  // illegal
        endcase
    endfunction

    // A truth table per condition. Bit {z, c, n, v} says if it is true.
    function [15:0] truth(input integer cond);
        case (cond)
            0:       truth = 16'hFF00;  // BEQ
            1:       truth = 16'h00FF;  // BNE
            2:       truth = 16'hF0F0;  // BCS
            3:       truth = 16'h0F0F;  // BCC
            4:       truth = 16'hCCCC;  // BMI
            5:       truth = 16'h3333;  // BPL
            6:       truth = 16'hAAAA;  // BVS
            7:       truth = 16'h5555;  // BVC
            8:       truth = 16'h6666;  // BLT
            9:       truth = 16'h9999;  // BGE
            10:      truth = 16'h0F0F;  // BLO
            11:      truth = 16'hF0F0;  // BHS
            default: truth = 16'h0000;
        endcase
    endfunction

    integer      errors = 0;
    integer      inputs = 0, illegal_inputs = 0, taken_inputs = 0;
    integer      irest, iflags, iop;
    integer      expected_op, expected_cond, expected_funct, expected_imm;
    reg [19:0]   expected;
    reg [15:0]   condition;
    reg          expected_taken, expected_halt, expected_illegal;

    wire [19:0] actual = {reg_we, flags_we, mem_read, mem_write,
                          jump, call, ret, push, pop, jr,
                          alu_src_imm,
                          alu_op,
                          pc_sel_next, pc_sel_imm, pc_sel_rs, pc_sel_stack, pc_sel_hold};

    // Works out every output from the word, with no bit-selects of instr.
    task expect_outputs(input integer word, input integer flags);
        begin
            expected_op    = word / 4096;
            expected_cond  = (word / 256) % 16;
            expected_imm   = word % 256;
            expected_funct = word % 16;

            expected         = control(expected_op);
            condition        = truth(expected_cond);
            expected_taken   = 1'b0;
            expected_halt    = 1'b0;
            expected_illegal = (expected_op == 15);

            if (expected_op == 0) begin
                expected_halt    = (expected_imm == 1);
                expected_illegal = (expected_imm >= 2);
                if (expected_halt)
                    expected[4:0] = 5'b00001;
            end

            if (expected_op == 1) begin
                expected_illegal = (expected_funct == 15);
                expected[8:5]    = expected_funct[3:0];
                if (expected_funct == 14) begin
                    expected[19]  = 1'b0;  // CMP: an ALU SUB, and the result is dropped
                    expected[8:5] = 4'd2;
                end
            end

            if (expected_op == 9) begin
                expected_illegal = (expected_cond >= 12);
                expected_taken   = condition[flags];
                if (expected_taken)
                    expected[4:0] = 5'b01000;
            end

            if (expected_illegal)
                expected = control(15);
        end
    endtask

    // Call just after a falling edge, and each call takes one clock cycle.
    // !== also catches a value that is still x or z.
    task step(input integer word, input integer flags);
        begin
            instr        = word[15:0];
            {z, c, n, v} = flags[3:0];
            expect_outputs(word, flags);
            #1;
            if (actual !== expected
                    || branch_taken !== expected_taken
                    || halt !== expected_halt
                    || illegal !== expected_illegal
                    || rd !== word[11:10]
                    || rs !== word[9:8]
                    || reg_waddr !== word[11:10]
                    || imm !== word[7:0]) begin
                if (errors < 10)
                    $display("FAIL t=%0t instr=%h zcnv=%b actual=%b expected=%b taken=%b halt=%b illegal=%b rd=%0d rs=%0d waddr=%0d imm=%h",
                             $time, instr, {z, c, n, v}, actual, expected,
                             branch_taken, halt, illegal, rd, rs, reg_waddr, imm);
                errors = errors + 1;
            end
            inputs         = inputs + 1;
            illegal_inputs = illegal_inputs + (expected_illegal ? 1 : 0);
            taken_inputs   = taken_inputs + (expected_taken ? 1 : 0);
            @(negedge clk);
        end
    endtask

    // One step, printed, so the numbers in the README come from this run.
    task show(input [15:0] word, input [3:0] flags);
        begin
            step({16'd0, word}, {28'd0, flags});
            $display("%h zcnv=%b rd=%0d rs=%0d imm=%h alu_op=%0d alu_src_imm=%b reg_we=%b flags_we=%b mem_read=%b mem_write=%b taken=%b halt=%b illegal=%b pc_sel=%b%b%b%b%b",
                     instr, {z, c, n, v}, rd, rs, imm, alu_op, alu_src_imm, reg_we, flags_we,
                     mem_read, mem_write, branch_taken, halt, illegal,
                     pc_sel_next, pc_sel_imm, pc_sel_rs, pc_sel_stack, pc_sel_hold);
        end
    endtask

    initial begin
        $dumpfile("build/tb_decode.vcd");
        $dumpvars(0, tb_decode);

        @(negedge clk);
        show(16'h2CF0, 4'b0000);  // LDI  R3, 0xF0
        show(16'h1600, 4'b0000);  // ADD  R1, R2
        show(16'h160E, 4'b0000);  // CMP  R1, R2
        show(16'h7600, 4'b0000);  // ST   R1, [R2]
        show(16'hA009, 4'b0000);  // CALL 0x09
        show(16'hD800, 4'b0000);  // POP  R2
        show(16'h9104, 4'b0000);  // BNE  0x04, z is low so it is taken
        show(16'h9104, 4'b1000);  // BNE  0x04, z is high so it is not
        show(16'h0001, 4'b0000);  // HALT
        show(16'hF000, 4'b0000);  // illegal
        $dumpoff;

        // op changes fastest, because Tutorial 4 showed that the order can hide
        // a latch. irest is the rd, rs and imm fields together.
        inputs         = 0;
        illegal_inputs = 0;
        taken_inputs   = 0;
        for (irest = 0; irest < 4096; irest = irest + 1)
            for (iflags = 0; iflags < 16; iflags = iflags + 1)
                for (iop = 0; iop < 16; iop = iop + 1)
                    step(iop * 4096 + irest, iflags);

        // A second check that the loops and the table cover what the spec says.
        if (inputs != ALL_INPUTS || illegal_inputs != ILLEGAL_WORDS * 16
                || taken_inputs != TAKEN_INPUTS) begin
            $display("FAIL: %0d inputs, %0d illegal, %0d taken",
                     inputs, illegal_inputs, taken_inputs);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("PASS: %0d input combinations, %0d illegal, %0d branches taken",
                     inputs, illegal_inputs, taken_inputs);
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
