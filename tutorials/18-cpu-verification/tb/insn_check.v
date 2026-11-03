// Per-instruction proof, in the style of riscv-formal but much simpler. Yosys only.
//
// cpu runs with free inputs: the solver chooses every word of instruction memory and
// every byte read from data memory. Each sby task picks one class with CHECK. Whenever
// an instruction of that class retires, this module works out from the spec what it
// should have done, and asserts that it did. It shares nothing with cpu.v, decode.v or
// alu_flags.v: no wires, no names and no method. Sums are checked by their true value
// in numbers too wide to overflow.
//
// pre_ is the state a programmer can see, copied on the first clock of each instruction:
// the clock after a retire or a reset. Nothing is assumed about the instructions before
// this one, or about any other part of the CPU, such as result or ir.
//
// The f_ wires marked "from insn.sby" have no driver in this file. Yosys cannot read
// a path such as u_cpu.pc, so insn.sby connects them after flattening.
module insn_check #(
    parameter CHECK = 0
) (
    input wire        clk,
    input wire        rst,
    input wire [15:0] imem_data,      // free: any instruction
    input wire [7:0]  dmem_rdata      // free: any data
);

    localparam C_NOP = 1, C_HALT = 2, C_ILLEGAL = 3, C_ARITH = 4, C_LOGIC = 5, C_SHIFT = 6,
               C_CMP = 7, C_LDI = 8, C_ADDI = 9, C_CMPI = 10, C_ANDI = 11, C_LD = 12, C_ST = 13,
               C_JMP = 14, C_BCC = 15, C_CALL = 16, C_RET = 17, C_PUSH = 18, C_POP = 19,
               C_JR = 20;
    localparam C_FETCH = 21, C_STRUCTURE = 22;

    wire [7:0]  imem_addr, dmem_addr, dmem_wdata, retire_pc;
    wire        dmem_re, dmem_we, halted, illegal, retire;
    wire [15:0] retire_instr;

    cpu u_cpu (
        .clk(clk), .rst(rst),
        .imem_addr(imem_addr), .imem_data(imem_data),
        .dmem_addr(dmem_addr), .dmem_re(dmem_re), .dmem_we(dmem_we),
        .dmem_wdata(dmem_wdata), .dmem_rdata(dmem_rdata),
        .halted(halted), .illegal(illegal),
        .retire(retire), .retire_pc(retire_pc), .retire_instr(retire_instr)
    );

    wire [7:0] f_pc;                    // from insn.sby
    wire [7:0] f_r0, f_r1, f_r2, f_r3;  // from insn.sby
    wire       f_z, f_c, f_n, f_v;      // from insn.sby
    wire [3:0] f_state;                 // from insn.sby

    reg past_valid = 1'b0;
    always @(posedge clk)
        past_valid <= 1'b1;

    // A proof starts at the first clock of an instruction, with PC, registers, flags,
    // ir and result all free. A reset ends in such a state, so this covers it too, and
    // the solver needs no instructions to set up a rare value. Cover starts from reset,
    // to show that each class can really be reached.
    always @(posedge clk) begin
        if (!past_valid) begin
            if (CHECK == 0)
                assume (rst);
            else
                assume (f_state == 4'd0);
        end
    end

    // ----- The state before this instruction, and what it did to memory -----

    reg       boundary = 1'b1;          // high on the clock after a retire or a reset
    reg [7:0] pre_pc, pre_r0, pre_r1, pre_r2, pre_r3;
    reg       pre_z, pre_c, pre_n, pre_v;

    reg [1:0] writes = 2'd0, reads = 2'd0;   // how many, stopping at 3
    reg       read_valid = 1'b0;             // dmem_rdata holds the answer on this clock
    reg [7:0] write_addr, write_data, read_addr, read_data;

    always @(posedge clk) begin
        boundary <= rst || retire;
        if (boundary) begin
            pre_pc <= f_pc;
            pre_r0 <= f_r0;
            pre_r1 <= f_r1;
            pre_r2 <= f_r2;
            pre_r3 <= f_r3;
            {pre_z, pre_c, pre_n, pre_v} <= {f_z, f_c, f_n, f_v};
        end

        writes <= (boundary ? 2'd0 : writes) + ((dmem_we && writes != 2'd3) ? 2'd1 : 2'd0);
        reads  <= (boundary ? 2'd0 : reads)  + ((dmem_re && reads  != 2'd3) ? 2'd1 : 2'd0);

        if (dmem_we) begin
            write_addr <= dmem_addr;
            write_data <= dmem_wdata;
        end
        if (dmem_re)
            read_addr <= dmem_addr;

        read_valid <= dmem_re;
        if (read_valid)
            read_data <= dmem_rdata;
    end

    // ----- The fields, and which class this is -----

    wire [3:0] op    = retire_instr[15:12];
    wire [1:0] rd    = retire_instr[11:10];
    wire [1:0] rs    = retire_instr[9:8];
    wire [3:0] cond  = retire_instr[11:8];
    wire [7:0] imm   = retire_instr[7:0];
    wire [3:0] funct = retire_instr[3:0];

    wire is_alu    = op == 4'h1;
    wire is_nop    = op == 4'h0 && imm == 8'd0;
    wire is_halt   = op == 4'h0 && imm == 8'd1;
    wire is_arith  = is_alu && funct <= 4'd3;
    wire is_logic  = is_alu && ((funct >= 4'd4 && funct <= 4'd7) || funct == 4'd13);
    wire is_shift  = is_alu && funct >= 4'd8 && funct <= 4'd12;
    wire is_cmp    = is_alu && funct == 4'd14;
    wire is_ldi    = op == 4'h2;
    wire is_addi   = op == 4'h3;
    wire is_cmpi   = op == 4'h4;
    wire is_andi   = op == 4'h5;
    wire is_ld     = op == 4'h6;
    wire is_st     = op == 4'h7;
    wire is_jmp    = op == 4'h8;
    wire is_bcc    = op == 4'h9 && cond <= 4'd11;
    wire is_call   = op == 4'hA;
    wire is_ret    = op == 4'hB;
    wire is_push   = op == 4'hC;
    wire is_pop    = op == 4'hD;
    wire is_jr     = op == 4'hE;
    wire is_illegal = (op == 4'h0 && imm >= 8'd2) || (is_alu && funct == 4'd15)
                   || (op == 4'h9 && cond >= 4'd12) || op == 4'hF;

    wire this_class = (CHECK == C_NOP     && is_nop)   || (CHECK == C_HALT  && is_halt)
                   || (CHECK == C_ILLEGAL && is_illegal)
                   || (CHECK == C_ARITH   && is_arith) || (CHECK == C_LOGIC && is_logic)
                   || (CHECK == C_SHIFT   && is_shift) || (CHECK == C_CMP   && is_cmp)
                   || (CHECK == C_LDI     && is_ldi)   || (CHECK == C_ADDI  && is_addi)
                   || (CHECK == C_CMPI    && is_cmpi)  || (CHECK == C_ANDI  && is_andi)
                   || (CHECK == C_LD      && is_ld)    || (CHECK == C_ST    && is_st)
                   || (CHECK == C_JMP     && is_jmp)   || (CHECK == C_BCC   && is_bcc)
                   || (CHECK == C_CALL    && is_call)  || (CHECK == C_RET   && is_ret)
                   || (CHECK == C_PUSH    && is_push)  || (CHECK == C_POP   && is_pop)
                   || (CHECK == C_JR      && is_jr);

    // ----- What the spec says -----

    wire [7:0] val_rd = (rd == 2'd0) ? pre_r0 : (rd == 2'd1) ? pre_r1 :
                        (rd == 2'd2) ? pre_r2 : pre_r3;
    wire [7:0] val_rs = (rs == 2'd0) ? pre_r0 : (rs == 2'd1) ? pre_r1 :
                        (rs == 2'd2) ? pre_r2 : pre_r3;

    // Arithmetic, as true numbers. The instruction is reduced to a sum:
    // top - (or +) other - (or +) extra, unsigned and signed, 11 bits so it cannot wrap.
    wire is_sum  = is_arith || is_addi;
    wire minus   = (is_alu && (funct == 4'd2 || funct == 4'd3)) || is_cmp || is_cmpi;
    wire [7:0] other = is_alu ? val_rs : imm;

    wire use_carry_in = is_alu && (funct == 4'd1 || funct == 4'd3);
    wire signed [10:0] extra = !use_carry_in ? 11'sd0 :
                               (funct == 4'd1) ? (pre_c ? 11'sd1 : 11'sd0) :
                               (pre_c ? 11'sd0 : -11'sd1);      // SBC: 0, or a borrow of 1

    wire signed [10:0] u_top   = {3'b000, val_rd};
    wire signed [10:0] u_other = {3'b000, other};
    wire signed [10:0] s_top   = {{3{val_rd[7]}}, val_rd};
    wire signed [10:0] s_other = {{3{other[7]}}, other};

    wire signed [10:0] u_exact = minus ? u_top - u_other + extra : u_top + u_other + extra;
    wire signed [10:0] s_exact = minus ? s_top - s_other + extra : s_top + s_other + extra;

    wire [7:0] sum_y = u_exact[7:0];
    wire       sum_c = minus ? (u_exact >= 0) : (u_exact > 255);
    wire       sum_v = (s_exact < -128) || (s_exact > 127);

    // Shifts and rotates, from what each one means. Bit 7 of y is the new sign.
    wire [8:0] twice = {val_rd, 1'b0};
    wire [7:0] half  = val_rd / 8'd2;

    wire [7:0] shift_y = (funct == 4'd8)  ? twice[7:0] :
                         (funct == 4'd9)  ? half :
                         (funct == 4'd10) ? (val_rd[7] ? half + 8'd128 : half) :
                         (funct == 4'd11) ? (pre_c ? twice[7:0] + 8'd1 : twice[7:0]) :
                                            (pre_c ? half + 8'd128 : half);
    wire shift_c = (funct == 4'd8 || funct == 4'd11) ? val_rd >= 8'd128 : val_rd[0];
    wire shift_v = (funct == 4'd8 || funct == 4'd11) && (shift_y[7] != val_rd[7]);

    // Logic. c and v are always 0.
    wire [7:0] logic_y = is_andi       ? (val_rd & imm)    :
                         (funct == 4'd4)  ? (val_rd & val_rs) :
                         (funct == 4'd5)  ? (val_rd | val_rs) :
                         (funct == 4'd6)  ? (val_rd ^ val_rs) :
                         (funct == 4'd7)  ? 8'd255 - val_rd   :
                                            val_rs;

    wire uses_sum   = is_sum || is_cmp || is_cmpi;
    wire [7:0] alu_y = uses_sum ? sum_y : is_shift ? shift_y : logic_y;

    // The flags. Everything else keeps the flags it had.
    wire sets_flags = is_arith || is_logic || is_shift || is_cmp || is_addi || is_cmpi || is_andi;
    wire want_z = sets_flags ? alu_y == 8'd0 : pre_z;
    wire want_n = sets_flags ? alu_y >= 8'd128 : pre_n;
    wire want_c = !sets_flags ? pre_c : uses_sum ? sum_c : is_shift ? shift_c : 1'b0;
    wire want_v = !sets_flags ? pre_v : uses_sum ? sum_v : is_shift ? shift_v : 1'b0;

    // The stack. A push decrements and then stores. A pop loads and then increments.
    wire pushes = is_call || is_push;
    wire pops   = is_ret || is_pop;
    wire [7:0] sp_down = pre_r3 - 8'd1;
    wire [7:0] sp_up   = pre_r3 + 8'd1;

    // Memory.
    wire [7:0] ld_st_addr = val_rs + imm;
    wire [7:0] next_pc    = pre_pc + 8'd1;

    wire       want_write      = is_st || pushes;
    wire [7:0] want_write_addr = is_st ? ld_st_addr : sp_down;
    wire [7:0] want_write_data = is_st ? val_rd : is_call ? next_pc : val_rs;
    wire       want_read       = is_ld || pops;
    wire [7:0] want_read_addr  = is_ld ? ld_st_addr : pre_r3;

    // The registers. rd is decided last, so POP R3 keeps the loaded value.
    wire       writes_rd = is_arith || is_logic || is_shift || is_ldi || is_addi || is_andi
                        || is_ld || is_pop;
    wire [7:0] rd_value  = is_ldi ? imm : (is_ld || is_pop) ? read_data : alu_y;
    wire [7:0] r3_moved  = pushes ? sp_down : pops ? sp_up : pre_r3;

    wire [7:0] want_r0 = (writes_rd && rd == 2'd0) ? rd_value : pre_r0;
    wire [7:0] want_r1 = (writes_rd && rd == 2'd1) ? rd_value : pre_r1;
    wire [7:0] want_r2 = (writes_rd && rd == 2'd2) ? rd_value : pre_r2;
    wire [7:0] want_r3 = (writes_rd && rd == 2'd3) ? rd_value : r3_moved;

    // The PC.
    wire taken = (cond == 4'd0)  ? pre_z  : (cond == 4'd1)  ? !pre_z :
                 (cond == 4'd2)  ? pre_c  : (cond == 4'd3)  ? !pre_c :
                 (cond == 4'd4)  ? pre_n  : (cond == 4'd5)  ? !pre_n :
                 (cond == 4'd6)  ? pre_v  : (cond == 4'd7)  ? !pre_v :
                 (cond == 4'd8)  ? pre_n != pre_v : (cond == 4'd9) ? pre_n == pre_v :
                 (cond == 4'd10) ? !pre_c : pre_c;

    wire stops = is_halt || is_illegal;
    wire [7:0] want_pc = (is_jmp || is_call || (is_bcc && taken)) ? imm :
                         is_jr  ? val_rs :
                         is_ret ? read_data :
                         stops  ? pre_pc :
                                  next_pc;

    // ----- The checks for one instruction class -----

    reg       check_next = 1'b0;   // the instruction checked last clock has just left
    reg [7:0] pc_after;
    reg       halted_after, illegal_after;

    always @(posedge clk) begin
        check_next <= retire && this_class;
        pc_after   <= want_pc;
        halted_after  <= stops;
        illegal_after <= is_illegal;
    end

    always @(posedge clk) begin
        if (past_valid && retire && this_class) begin
            assert (retire_pc == pre_pc);

            assert (f_r0 == want_r0);
            assert (f_r1 == want_r1);
            assert (f_r2 == want_r2);
            assert (f_r3 == want_r3);

            assert (f_z == want_z);
            assert (f_c == want_c);
            assert (f_n == want_n);
            assert (f_v == want_v);

            assert (writes == (want_write ? 2'd1 : 2'd0));
            if (want_write) begin
                assert (write_addr == want_write_addr);
                assert (write_data == want_write_data);
            end

            assert (reads == (want_read ? 2'd1 : 2'd0));
            if (want_read)
                assert (read_addr == want_read_addr);
        end

        // PC moves after retire, so it is checked one clock later.
        if (past_valid && check_next) begin
            assert (f_pc == pc_after);
            assert (halted == halted_after);
            assert (illegal == illegal_after);
        end
    end

    // ----- The instruction really came from memory -----

    // The solver picks one address and what it holds, as in Tutorial 6. Memory answers
    // one clock after the address, so a retire must report this word for this address.
    (* anyconst *) reg [7:0]  watch_addr;
    (* anyconst *) reg [15:0] watch_word;

    reg [7:0] last_imem_addr;
    always @(posedge clk)
        last_imem_addr <= imem_addr;

    generate
        if (CHECK == C_FETCH) begin : gen_fetch
            always @(posedge clk) begin
                if (past_valid && last_imem_addr == watch_addr)
                    assume (imem_data == watch_word);
                if (past_valid && retire && retire_pc == watch_addr)
                    assert (retire_instr == watch_word);
            end
        end
    endgenerate

    // ----- What joins one instruction to the next -----

    wire [4:0] class_count = is_nop + is_halt + is_illegal + is_arith + is_logic + is_shift
                           + is_cmp + is_ldi + is_addi + is_cmpi + is_andi + is_ld + is_st
                           + is_jmp + is_bcc + is_call + is_ret + is_push + is_pop + is_jr;

    reg [3:0] age = 4'd0;           // clocks since this instruction began
    reg       past_rst = 1'b0;
    reg       past_halted = 1'b0;

    always @(posedge clk) begin
        past_rst    <= rst;
        past_halted <= halted;

        if (rst || boundary)
            age <= 4'd0;
        else if (age != 4'd15)
            age <= age + 4'd1;
    end

    generate
        if (CHECK == C_STRUCTURE) begin : gen_structure
            always @(posedge clk) begin
                if (past_valid) begin
                    // The classes above split all 65536 words, with no gaps or overlaps.
                    assert (class_count == 5'd1);

                    // Reset gives the state the spec lists.
                    if (past_rst) begin
                        assert (f_pc == 8'd0);
                        assert (f_r0 == 8'd0 && f_r1 == 8'd0 && f_r2 == 8'd0 && f_r3 == 8'd0);
                        assert (!f_z && !f_c && !f_n && !f_v);
                    end

                    // Every instruction finishes, in the 9 clocks of Tutorial 17's table.
                    if (!halted)
                        assert (age <= 4'd8);

                    // An instruction boundary is one clock, never a retire.
                    if (boundary)
                        assert (!retire);

                    // Halted is left only by reset, and nothing moves while there.
                    if (past_halted && !past_rst) begin
                        assert (halted);
                        assert (!retire && !dmem_we && !dmem_re);
                        assert (f_pc == pre_pc);
                        assert (f_r0 == pre_r0 && f_r1 == pre_r1);
                        assert (f_r2 == pre_r2 && f_r3 == pre_r3);
                        assert ({f_z, f_c, f_n, f_v} == {pre_z, pre_c, pre_n, pre_v});
                    end
                end
            end
        end
    endgenerate

    // ----- Cover: the proofs above are about something -----

    always @(posedge clk) begin
        if (past_valid && !rst && retire) begin
            cover (is_nop);
            cover (is_halt);
            cover (is_illegal);
            cover (is_arith);
            cover (is_logic);
            cover (is_shift);
            cover (is_cmp);
            cover (is_ldi);
            cover (is_addi);
            cover (is_cmpi);
            cover (is_andi);
            cover (is_ld);
            cover (is_st);
            cover (is_jmp);
            cover (is_bcc && taken);
            cover (is_bcc && !taken);
            cover (is_call);
            cover (is_ret);
            cover (is_push);
            cover (is_pop);
            cover (is_jr);
            cover (is_pop && rd == 2'd3);
            cover (is_push && rs == 2'd3);
        end
    end

endmodule
