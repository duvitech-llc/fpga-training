// The course CPU: 8 bits, four registers, multi-cycle. Tutorial 16 has the
// instruction set. There are no memories in here: cpu_top adds them.
//
// The design has two halves. The datapath holds the data: pc, ir, result, the
// flags, the registers, the ALU and two small adders. The control is the FSM,
// which decides on each clock which datapath registers load. Every datapath
// register is an enreg, so "load" is just its en input.
//
//   FETCH    pc is on imem_addr. The memory takes the address on this clock edge.
//   WAIT     imem_data is valid, one clock later. ir loads it.
//   DECODE   decode looks at ir. Nothing loads here. This state picks the route.
//   EXECUTE  The ALU works. result loads, and so do the flags if flags_we is high.
//   SP_DEC   CALL, PUSH: R3 = R3 - 1.
//   MEMORY   dmem_re or dmem_we is high for one clock.
//   MEM_WAIT dmem_rdata is valid, one clock later. result loads it.
//   SP_INC   RET, POP: R3 = R3 + 1.
//   WRITEBACK  rd loads result.
//   RETIRE   All effects are done. retire pulses, and pc moves to the next address.
//   HALTED   Stays here until reset.
//
// The order of the stack states carries the spec's two rulings on R3. PUSH R3
// takes its copy in EXECUTE, before SP_DEC, so the old R3 is stored. POP R3 writes
// rd in WRITEBACK, after SP_INC, so the load wins over the increment.
module cpu (
    input  wire        clk,
    input  wire        rst,          // synchronous, active high
    output wire [7:0]  imem_addr,
    input  wire [15:0] imem_data,    // one clock after imem_addr, as in Tutorial 6
    output wire [7:0]  dmem_addr,
    output wire        dmem_re,
    output wire        dmem_we,
    output wire [7:0]  dmem_wdata,
    input  wire [7:0]  dmem_rdata,   // one clock after dmem_re, as in Tutorial 6
    output wire        halted,
    output wire        illegal,
    output wire        retire,       // one pulse per finished instruction
    output wire [7:0]  retire_pc,    // address of that instruction
    output wire [15:0] retire_instr  // that instruction
);

    localparam [3:0] S_FETCH     = 4'd0;
    localparam [3:0] S_WAIT      = 4'd1;
    localparam [3:0] S_DECODE    = 4'd2;
    localparam [3:0] S_EXECUTE   = 4'd3;
    localparam [3:0] S_SP_DEC    = 4'd4;
    localparam [3:0] S_MEMORY    = 4'd5;
    localparam [3:0] S_MEM_WAIT  = 4'd6;
    localparam [3:0] S_SP_INC    = 4'd7;
    localparam [3:0] S_WRITEBACK = 4'd8;
    localparam [3:0] S_RETIRE    = 4'd9;
    localparam [3:0] S_HALTED    = 4'd10;

    localparam [1:0] SP = 2'd3;  // R3 is the stack pointer

    reg  [3:0] state;
    reg  [3:0] next_state;

    // Datapath registers.
    wire [7:0]  pc;
    wire [15:0] ir;
    wire [7:0]  result;     // the value on its way to a register, the PC or memory
    wire        flag_z, flag_c, flag_n, flag_v;

    // Everything decode says about the instruction in ir.
    wire [1:0] rd, rs, reg_waddr;
    wire [7:0] imm;
    wire [3:0] alu_op;
    wire       alu_src_imm, reg_we, flags_we, mem_read, mem_write;
    wire       call, ret, push, pop, halt, dec_illegal;
    wire       pc_sel_imm, pc_sel_rs, pc_sel_stack, pc_sel_hold;

    // decode gives more than this CPU needs: pc_sel_ already says all of these.
    wire       unused_branch_taken, unused_jump, unused_jr, unused_pc_sel_next;

    decode u_decode (
        .instr(ir),
        .z(flag_z), .c(flag_c), .n(flag_n), .v(flag_v),
        .rd(rd), .rs(rs), .imm(imm),
        .alu_op(alu_op), .alu_src_imm(alu_src_imm),
        .reg_we(reg_we), .reg_waddr(reg_waddr), .flags_we(flags_we),
        .mem_read(mem_read), .mem_write(mem_write),
        .branch_taken(unused_branch_taken), .jump(unused_jump),
        .call(call), .ret(ret), .push(push), .pop(pop), .jr(unused_jr),
        .halt(halt), .illegal(dec_illegal),
        .pc_sel_next(unused_pc_sel_next), .pc_sel_imm(pc_sel_imm), .pc_sel_rs(pc_sel_rs),
        .pc_sel_stack(pc_sel_stack), .pc_sel_hold(pc_sel_hold)
    );

    // ----- Control: the FSM -----

    // Instructions that do nothing but choose the next PC go straight to RETIRE.
    wire uses_datapath = reg_we || flags_we || mem_read || mem_write;
    wire uses_stack    = call || ret || push || pop;
    wire stops         = halt || dec_illegal;

    always @(*) begin
        case (state)
            S_FETCH:     next_state = S_WAIT;
            S_WAIT:      next_state = S_DECODE;
            S_DECODE:    next_state = uses_datapath ? S_EXECUTE : S_RETIRE;
            S_EXECUTE:
                if (call || push)
                    next_state = S_SP_DEC;
                else if (mem_read || mem_write)
                    next_state = S_MEMORY;
                else
                    next_state = reg_we ? S_WRITEBACK : S_RETIRE;
            S_SP_DEC:    next_state = S_MEMORY;
            S_MEMORY:    next_state = mem_read ? S_MEM_WAIT : S_RETIRE;
            S_MEM_WAIT:  next_state = uses_stack ? S_SP_INC : S_WRITEBACK;
            S_SP_INC:    next_state = reg_we ? S_WRITEBACK : S_RETIRE;
            S_WRITEBACK: next_state = S_RETIRE;
            S_RETIRE:    next_state = stops ? S_HALTED : S_FETCH;
            S_HALTED:    next_state = S_HALTED;
            default:     next_state = S_FETCH;  // codes 11 to 15 are never entered
        endcase
    end

    always @(posedge clk) begin
        if (rst)
            state <= S_FETCH;
        else
            state <= next_state;
    end

    // The FSM's control signals: Moore outputs, as in Tutorial 5.
    wire ir_load     = (state == S_WAIT);
    wire flags_load  = (state == S_EXECUTE) && flags_we;
    wire result_load = (state == S_EXECUTE) || (state == S_MEM_WAIT);
    wire sp_write    = (state == S_SP_DEC) || (state == S_SP_INC);
    wire rd_write    = (state == S_WRITEBACK);
    wire pc_load     = (state == S_RETIRE);

    // ----- Datapath -----

    // Port a is rd, or R3 for the stack instructions. Port b is always rs.
    wire [7:0] rdata_a, rdata_b;
    wire [7:0] sp_next = (state == S_SP_DEC) ? rdata_a - 8'd1 : rdata_a + 8'd1;

    regfile #(.WIDTH(8), .REGS(4)) u_regfile (
        .clk(clk),
        .rst(rst),
        .we(sp_write || rd_write),
        .waddr(sp_write ? SP : reg_waddr),
        .wdata(sp_write ? sp_next : result),
        .raddr_a(uses_stack ? SP : rd),
        .rdata_a(rdata_a),
        .raddr_b(rs),
        .rdata_b(rdata_b)
    );

    wire [7:0] alu_y;
    wire       alu_z, alu_c, alu_n, alu_v;

    alu_flags #(.WIDTH(8)) u_alu (
        .a(rdata_a),
        .b(alu_src_imm ? imm : rdata_b),
        .carry_in(flag_c),
        .op(alu_op),
        .y(alu_y),
        .z(alu_z), .c(alu_c), .n(alu_n), .v(alu_v)
    );

    enreg #(.WIDTH(4)) u_flags (
        .clk(clk), .rst(rst), .en(flags_load),
        .d({alu_z, alu_c, alu_n, alu_v}),
        .q({flag_z, flag_c, flag_n, flag_v})
    );

    enreg #(.WIDTH(16)) u_ir (
        .clk(clk), .rst(rst), .en(ir_load), .d(imem_data), .q(ir)
    );

    // In EXECUTE, the value this instruction will need later. It has to be taken
    // now: PUSH R3 needs R3 from before SP_DEC.
    wire [7:0] pc_plus_1 = pc + 8'd1;
    wire [7:0] exec_value = call      ? pc_plus_1 :
                            push      ? rdata_b   :
                            mem_write ? rdata_a   :  // ST stores rd
                                        alu_y;

    enreg #(.WIDTH(8)) u_result (
        .clk(clk), .rst(rst), .en(result_load),
        .d((state == S_MEM_WAIT) ? dmem_rdata : exec_value),
        .q(result)
    );

    wire [7:0] pc_next = pc_sel_imm   ? imm     :
                         pc_sel_rs    ? rdata_b :
                         pc_sel_stack ? result  :
                         pc_sel_hold  ? pc      :
                                        pc_plus_1;

    enreg #(.WIDTH(8)) u_pc (
        .clk(clk), .rst(rst), .en(pc_load), .d(pc_next), .q(pc)
    );

    // ----- Outputs -----

    assign imem_addr = pc;

    // The stack uses R3. LD and ST have their own adder, because the ALU's a
    // input is rd and the address is rs + imm.
    assign dmem_addr  = uses_stack ? rdata_a : rdata_b + imm;
    assign dmem_wdata = result;
    assign dmem_re    = !rst && (state == S_MEMORY) && mem_read;
    assign dmem_we    = !rst && (state == S_MEMORY) && mem_write;

    assign halted       = (state == S_HALTED);
    assign illegal      = halted && dec_illegal;
    assign retire       = !rst && (state == S_RETIRE);
    assign retire_pc    = pc;
    assign retire_instr = ir;

`ifdef FORMAL
    // Structural rules only: when things may happen, not whether each instruction
    // gets the right answer. Tutorial 18 proves that. imem_data and dmem_rdata are
    // free inputs with no assumptions on them, so these hold for any program, and
    // even for a memory that returns nonsense.
    reg past_valid = 1'b0;
    always @(posedge clk)
        past_valid <= 1'b1;

    always @(posedge clk) begin
        if (!past_valid)
            assume (rst);
    end

    // High from the clock ir loads until that instruction's retire.
    reg f_pending = 1'b0;
    // Clocks since FETCH. Bounds how long any instruction can take.
    reg [3:0] f_age = 4'd0;

    always @(posedge clk) begin
        if (rst || retire)
            f_pending <= 1'b0;
        else if (ir_load)
            f_pending <= 1'b1;

        if (rst || state == S_FETCH || state == S_HALTED)
            f_age <= 4'd0;
        else if (f_age != 4'd15)
            f_age <= f_age + 4'd1;
    end

    wire f_in_body = (state != S_FETCH) && (state != S_WAIT) && (state != S_HALTED);

    wire [3:0] f_op = ir[15:12];
    wire f_op_write = (f_op == 4'h7) || (f_op == 4'hA) || (f_op == 4'hC);  // ST, CALL, PUSH
    wire f_op_read  = (f_op == 4'h6) || (f_op == 4'hB) || (f_op == 4'hD);  // LD, RET, POP

    always @(posedge clk) begin
        if (past_valid) begin
            // The FSM is always in a state that has a name.
            assert (state <= S_HALTED);

            // Memory is only touched in MEMORY, by the right instructions.
            if (dmem_we)
                assert (state == S_MEMORY && f_op_write && !dmem_re);
            if (dmem_re)
                assert (state == S_MEMORY && f_op_read);

            // Exactly one retire per fetched instruction: a retire needs one
            // pending, and a new fetch needs none. This helper ties it to the FSM.
            assert (f_pending == f_in_body);
            if (retire)
                assert (f_pending);
            if (ir_load)
                assert (!f_pending);

            // And it arrives: no instruction takes more than 9 clocks.
            assert (f_age <= 4'd8);

            // Halted is only left through reset, and nothing moves while there.
            if (halted)
                assert (!retire && !dmem_we && !dmem_re && !sp_write && !rd_write && !flags_load);
            if (illegal)
                assert (halted);
            if ($past(halted) && !$past(rst)) begin
                assert (halted);
                assert (pc == $past(pc));
            end

            // HALT and illegal instructions touch nothing on their way to RETIRE.
            if (f_pending && stops)
                assert (state == S_DECODE || state == S_RETIRE);

            // The PC only moves at an instruction boundary, and ir only at a fetch.
            if (!$past(rst) && $past(state) != S_RETIRE)
                assert (pc == $past(pc));
            if (!$past(rst) && $past(state) != S_WAIT)
                assert (ir == $past(ir));

            // Reset really does reset.
            if ($past(rst))
                assert (state == S_FETCH && pc == 8'd0 && ir == 16'd0);

            // And it never touches memory, or counts as a retire.
            if (rst)
                assert (!dmem_we && !dmem_re && !retire);
        end
    end

    // Cover: can a retire of each class happen at all? These prove that the
    // assertions above are not empty.
    always @(posedge clk) begin
        if (past_valid && !rst) begin
            cover (retire && ir == 16'h0000);                                 // NOP
            cover (retire && halt);
            cover (retire && dec_illegal);
            cover (retire && f_op == 4'h1 && reg_we);                         // ALU
            cover (retire && f_op == 4'h1 && !reg_we && !dec_illegal);        // CMP
            cover (retire && f_op == 4'h2);                                   // LDI
            cover (retire && f_op == 4'h3);                                   // ADDI
            cover (retire && f_op == 4'h4);                                   // CMPI
            cover (retire && f_op == 4'h5);                                   // ANDI
            cover (retire && f_op == 4'h6);                                   // LD
            cover (retire && f_op == 4'h7);                                   // ST
            cover (retire && f_op == 4'h8);                                   // JMP
            cover (retire && f_op == 4'h9 && pc_sel_imm);                     // taken
            cover (retire && f_op == 4'h9 && !pc_sel_imm && !dec_illegal);    // not taken
            cover (retire && call);
            cover (retire && ret);
            cover (retire && push);
            cover (retire && pop);
            cover (retire && f_op == 4'hE);                                   // JR
            cover (halted && illegal);
            cover (halted && !illegal);
        end
    end
`endif

endmodule
