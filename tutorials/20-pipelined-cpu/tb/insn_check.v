// Per-instruction proof, Tutorial 18's checker moved to the pipeline. Yosys only.
//
// cpu runs with free inputs: the solver chooses every word of instruction memory and
// every byte read from data memory. Each sby task picks one class with CHECK. Whenever
// an instruction of that class retires, this module works out from the spec what it
// should have done, and asserts that it did. It shares nothing with cpu.v, decode.v or
// alu_flags.v: no wires, no names and no method.
//
// Two things differ from Tutorial 18, because instructions overlap here:
//
// - pre_ is the state a programmer can see, copied at the last retire. Registers and
//   flags change only in WB and retire comes one clock later, so what the last retire
//   showed is exactly what this instruction started from.
// - Memory is used two clocks before retire, while older instructions are still
//   finishing. A delay line brings each access to the clock of its own retire.
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

    reg past_valid = 1'b0;
    reg past_rst   = 1'b0;
    always @(posedge clk) begin
        past_valid <= 1'b1;
        past_rst   <= rst;
    end

    // The base case starts from reset. The induction step starts from anywhere, and that
    // is what makes this a proof about every program.
    always @(posedge clk) begin
        if (!past_valid)
            assume (rst);
    end

    // ----- The state before this instruction, and what it did to memory -----

    reg [7:0] pre_r0, pre_r1, pre_r2, pre_r3;
    reg       pre_z, pre_c, pre_n, pre_v;

    always @(posedge clk) begin
        if (past_rst || retire) begin
            pre_r0 <= f_r0;
            pre_r1 <= f_r1;
            pre_r2 <= f_r2;
            pre_r3 <= f_r3;
            {pre_z, pre_c, pre_n, pre_v} <= {f_z, f_c, f_n, f_v};
        end
    end

    // Memory is used in MEM, data comes back in WB, and retire is the clock after that.
    reg       we_1 = 1'b0, we_2 = 1'b0, re_1 = 1'b0, re_2 = 1'b0;
    reg [7:0] addr_1, addr_2, wdata_1, wdata_2, read_data;

    always @(posedge clk) begin
        we_1      <= dmem_we;
        we_2      <= we_1;
        re_1      <= dmem_re;
        re_2      <= re_1;
        addr_1    <= dmem_addr;
        addr_2    <= addr_1;
        wdata_1   <= dmem_wdata;
        wdata_2   <= wdata_1;
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
    wire [7:0] next_pc    = retire_pc + 8'd1;

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
                         stops  ? retire_pc :
                                  next_pc;

    // ----- The checks for one instruction class -----

    reg       check_stop = 1'b0;   // the instruction checked last clock has just retired
    reg       check_next = 1'b0;   // the next retire must be at pc_after
    reg [7:0] pc_after;
    reg       halted_after, illegal_after;
    reg       was_halted = 1'b0;

    always @(posedge clk) begin
        check_stop    <= retire && this_class;
        was_halted    <= halted;
        halted_after  <= stops;
        illegal_after <= is_illegal;

        if (rst)
            check_next <= 1'b0;
        else if (retire) begin
            check_next <= this_class;
            pc_after   <= want_pc;
        end
    end

    always @(posedge clk) begin
        if (past_valid && !rst && retire && this_class) begin
            assert (f_r0 == want_r0);
            assert (f_r1 == want_r1);
            assert (f_r2 == want_r2);
            assert (f_r3 == want_r3);

            assert (f_z == want_z);
            assert (f_c == want_c);
            assert (f_n == want_n);
            assert (f_v == want_v);

            assert (we_2 == want_write);
            if (want_write) begin
                assert (addr_2 == want_write_addr);
                assert (wdata_2 == want_write_data);
            end

            assert (re_2 == want_read);
            if (want_read)
                assert (addr_2 == want_read_addr);
        end

        // The instruction after this one proves where the PC went. A jump to the wrong
        // place, or a wrong-path instruction that got through, fails here.
        if (past_valid && !rst && retire && check_next)
            assert (retire_pc == pc_after);

        // cpu.sby proves that nothing retires while halted, and that illegal needs halted,
        // so this only asks what a retire does to a CPU that was running.
        if (past_valid && !rst && !past_rst && check_stop && !was_halted) begin
            assert (halted == halted_after);
            if (halted_after) begin
                assert (illegal == illegal_after);
                assert (f_pc == pc_after);
            end
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
                if (past_valid && !rst && retire && retire_pc == watch_addr)
                    assert (retire_instr == watch_word);
            end
        end
    endgenerate

    // ----- What joins one instruction to the next -----

    wire [4:0] class_count = is_nop + is_halt + is_illegal + is_arith + is_logic + is_shift
                           + is_cmp + is_ldi + is_addi + is_cmpi + is_andi + is_ld + is_st
                           + is_jmp + is_bcc + is_call + is_ret + is_push + is_pop + is_jr;

    reg first_retire = 1'b0;        // no instruction has retired since reset
    always @(posedge clk) begin
        if (rst)
            first_retire <= 1'b1;
        else if (retire)
            first_retire <= 1'b0;
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

                    // After reset, the program starts at address 0.
                    if (!rst && retire && first_retire)
                        assert (retire_pc == 8'd0);

                    // Memory is only ever used by an instruction that goes on to retire,
                    // so a wrong-path store or load never reaches the bus.
                    if (!rst && !past_rst && (we_2 || re_2))
                        assert (retire);
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
