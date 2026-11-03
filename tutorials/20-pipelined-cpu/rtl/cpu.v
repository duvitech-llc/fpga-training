// The course CPU again, with the same ports and instruction set as Tutorial 17, cut
// into five stages. Up to five instructions are in here at once, so most of the time
// one finishes on every clock.
//
//   IF   pc holds the address of the word now on imem_data.
//   ID   decode looks at the word, and the registers are read.
//   EX   The ALU works, and jumps and branches are decided.
//   MEM  dmem_re or dmem_we is high for one clock.
//   WB   dmem_rdata is valid. The registers and flags are written.
//
// Between two stages is one pipeline register, a single wide enreg, and each signal
// is named after the stage it is in. A stage that has nothing to do holds a bubble,
// which is a word of zeros: instr 0000 is a NOP, and every control bit is low, so a
// bubble cannot change anything. Killing an instruction is writing zeros over it.
//
// The rules that stop instructions getting in each other's way:
//
//   Forwarding  A result still in MEM or WB goes straight to EX. A result in WB also
//               goes to ID, because regfile returns the old value until the edge.
//   Stall       A load's data only exists in WB. An instruction that needs it at
//               once waits one clock in ID, and a bubble goes into EX.
//   Flush       Fetching assumes that nothing jumps. EX finds out otherwise, and
//               zeros the two younger instructions in IF and ID. They have not
//               reached MEM or WB, so they have changed nothing.
//   RET         Its target comes from memory, so it flushes in EX and then fetching
//               waits until WB. HALT and illegal words flush in the same way, and
//               only act in EX, where nothing older can still jump past them.
//   POP         The only instruction with two registers to write, and WB has one
//               write port. ID sends it down the pipeline twice.
//
// STEP is here for the lesson, which adds these fixes one at a time. Only STEP = 4
// is a working CPU with the tutorial's speed:
//
//   0  Nothing is handled.     2  Plus: stall until every result is written.
//   1  Plus: flush.            3  Plus: forward registers.   4  Plus: forward flags.
module cpu #(
    parameter STEP = 4
) (
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

    localparam [0:0] HAS_FLUSH        = (STEP >= 1);
    localparam [0:0] HAS_REG_FORWARD  = (STEP >= 3);
    localparam [0:0] HAS_FLAG_FORWARD = (STEP >= 4);

    localparam [1:0] SP = 2'd3;  // R3 is the stack pointer

    // The alu_flags operations this file has to recognise.
    localparam [3:0] ALU_ADC    = 4'd1;
    localparam [3:0] ALU_SBC    = 4'd3;
    localparam [3:0] ALU_NOT    = 4'd7;
    localparam [3:0] ALU_ROL    = 4'd11;
    localparam [3:0] ALU_ROR    = 4'd12;
    localparam [3:0] ALU_PASS_B = 4'd13;

    localparam [3:0] OP_BRANCH = 4'h9;

    // ----- What each stage holds -----

    localparam integer IF_ID_BITS  = 25;
    localparam integer ID_EX_BITS  = 62;
    localparam integer EX_MEM_BITS = 63;
    localparam integer MEM_WB_BITS = 45;

    // last is high on an instruction's final trip through the pipeline. It is low in a
    // bubble, and on the first trip of a POP. It is what becomes retire.
    wire        id_valid;
    wire [7:0]  id_pc;
    wire [15:0] id_instr;

    wire        ex_last;
    wire [7:0]  ex_pc;
    wire [15:0] ex_instr;
    wire [7:0]  ex_a_read, ex_b_read;   // as read in ID. May already be out of date
    wire [3:0]  ex_alu_op;
    wire        ex_alu_src_imm;
    wire        ex_reg_we;
    wire [1:0]  ex_waddr;
    wire        ex_flags_we;
    wire        ex_load;                // the value for the register comes from memory
    wire        ex_mem_read, ex_mem_write;
    wire        ex_stack;               // uses R3 as an address
    wire        ex_sp_down;             // and R3 - 1 is the one that matters
    wire        ex_jump;                // JMP or CALL
    wire        ex_jr, ex_call, ex_ret, ex_push;
    wire        ex_stops, ex_illegal;   // HALT or illegal, and illegal only

    wire        mem_last;
    wire [7:0]  mem_pc;
    wire [15:0] mem_instr;
    wire [7:0]  mem_result;             // the value on its way to a register
    wire [3:0]  mem_flags;              // {z, c, n, v}
    wire [7:0]  mem_addr, mem_wdata;
    wire        mem_reg_we;
    wire [1:0]  mem_waddr;
    wire        mem_flags_we;
    wire        mem_load, mem_read, mem_write;
    wire        mem_ret, mem_stops, mem_illegal;

    wire        wb_last;
    wire [7:0]  wb_pc;
    wire [15:0] wb_instr;
    wire [7:0]  wb_result;
    wire [3:0]  wb_flags;
    wire        wb_reg_we;
    wire [1:0]  wb_waddr;
    wire        wb_flags_we;
    wire        wb_load;
    wire        wb_ret, wb_stops, wb_illegal;

    // What is written in WB. Forwarding needs it, so it comes first.
    wire [7:0] wb_value = wb_load ? dmem_rdata : wb_result;

    // Set in EX, and used by every stage before it.
    wire        flush;       // zero the instructions in IF and ID
    wire        ex_redirect; // this instruction in EX is not followed by pc + 1
    wire [7:0]  ex_target;
    wire        ex_taken;    // a Bcc whose condition is true

    // Set in ID, and used by IF.
    wire        stall;       // the instruction in ID must wait, and a bubble goes on
    wire        id_hold;     // the instruction in ID stays there for the next clock

    // ----- IF: instruction fetch -----

    // High while fetching waits for a RET to reach WB, and for ever after HALT.
    wire front_stop;
    wire front_stop_next = (front_stop || ex_ret || ex_stops) && !wb_ret;

    // Memory has one clock of latency, so it is given the address a clock early. pc
    // loads the same value on the same edge, so imem_data always belongs to pc. A held
    // instruction reads the same word again, and nothing has to be stored.
    wire [7:0] pc;
    wire [7:0] pc_next = wb_ret                           ? dmem_rdata :
                         ex_stops                         ? ex_pc      :
                         ex_redirect                      ? ex_target  :
                         (id_hold || ex_ret || front_stop) ? pc         :
                                                             pc + 8'd1;

    // Holding imem_addr at 0 in reset means word 0 is ready on the first clock after it.
    assign imem_addr = rst ? 8'd0 : pc_next;

    enreg #(.WIDTH(8)) u_pc (
        .clk(clk), .rst(rst), .en(1'b1), .d(pc_next), .q(pc)
    );

    enreg #(.WIDTH(1)) u_front_stop (
        .clk(clk), .rst(rst), .en(1'b1), .d(front_stop_next), .q(front_stop)
    );

    // ----- IF/ID -----

    enreg #(.WIDTH(IF_ID_BITS)) u_if_id (
        .clk(clk), .rst(rst), .en(!id_hold),
        .d((flush || front_stop) ? {IF_ID_BITS{1'b0}} : {1'b1, pc, imem_data}),
        .q({id_valid, id_pc, id_instr})
    );

    // ----- ID: decode, and read the registers -----

    wire [1:0] id_rd, id_rs, id_decode_waddr;
    wire [3:0] id_alu_op;
    wire       id_alu_src_imm, id_decode_reg_we, id_flags_we, id_decode_mem_read, id_mem_write;
    wire       id_jmp, id_call, id_ret, id_push, id_pop, id_jr, id_halt, id_illegal;

    // Whether a branch is taken is decided by the copy of decode in EX, and the
    // pc_sel_ outputs say nothing that the outputs above do not.
    wire [7:0] unused_id_imm;
    wire       unused_id_taken, unused_id_next, unused_id_imm_sel, unused_id_rs_sel;
    wire       unused_id_stack_sel, unused_id_hold_sel;

    decode u_decode_id (
        .instr(id_instr),
        .z(1'b0), .c(1'b0), .n(1'b0), .v(1'b0),
        .rd(id_rd), .rs(id_rs), .imm(unused_id_imm),
        .alu_op(id_alu_op), .alu_src_imm(id_alu_src_imm),
        .reg_we(id_decode_reg_we), .reg_waddr(id_decode_waddr), .flags_we(id_flags_we),
        .mem_read(id_decode_mem_read), .mem_write(id_mem_write),
        .branch_taken(unused_id_taken), .jump(id_jmp),
        .call(id_call), .ret(id_ret), .push(id_push), .pop(id_pop), .jr(id_jr),
        .halt(id_halt), .illegal(id_illegal),
        .pc_sel_next(unused_id_next), .pc_sel_imm(unused_id_imm_sel),
        .pc_sel_rs(unused_id_rs_sel), .pc_sel_stack(unused_id_stack_sel),
        .pc_sel_hold(unused_id_hold_sel)
    );

    // POP goes down the pipeline twice. The first trip is R3 = R3 + 1. The second is a
    // load from R3 - 1 into rd, and since it writes last, POP R3 keeps the loaded value.
    wire pop_second;
    wire id_pop_first = id_pop && !pop_second;

    enreg #(.WIDTH(1)) u_pop_second (
        .clk(clk), .rst(rst), .en(!stall || flush),
        .d(id_pop_first && !flush), .q(pop_second)
    );

    wire id_stack    = id_call || id_ret || id_push || id_pop;
    wire id_sp_down  = id_call || id_push || pop_second;
    wire id_mem_read = id_decode_mem_read && !id_pop_first;
    wire id_load     = id_decode_reg_we && id_mem_read;
    wire id_reg_we   = id_decode_reg_we || id_stack;

    wire [1:0] id_waddr = (id_stack && !pop_second) ? SP : id_decode_waddr;
    wire [1:0] id_ra    = id_stack ? SP : id_rd;

    // Which values this instruction really uses, so that it never waits for the others.
    wire id_one_reg = (id_alu_op >= ALU_NOT) && (id_alu_op <= ALU_ROR);

    wire id_reads_a = id_stack || id_mem_write || (id_flags_we && id_alu_op != ALU_PASS_B);
    wire id_reads_b = (id_flags_we && !id_alu_src_imm && !id_one_reg) || id_push || id_jr
                   || ((id_mem_write || id_decode_mem_read) && !id_stack);
    wire id_reads_flags = (id_instr[15:12] == OP_BRANCH)
                       || (id_flags_we && (id_alu_op == ALU_ADC || id_alu_op == ALU_SBC ||
                                           id_alu_op == ALU_ROL || id_alu_op == ALU_ROR));

    wire [7:0] id_a_read, id_b_read;

    regfile #(.WIDTH(8), .REGS(4)) u_regfile (
        .clk(clk),
        .rst(rst),
        .we(wb_reg_we),
        .waddr(wb_waddr),
        .wdata(wb_value),
        .raddr_a(id_ra),
        .rdata_a(id_a_read),
        .raddr_b(id_rs),
        .rdata_b(id_b_read)
    );

    // The register being written in WB reads as its old value until the edge, and EX
    // forwarding is too late, since that instruction will have left WB. So ID takes it.
    wire bypass_a = HAS_REG_FORWARD && wb_reg_we && (wb_waddr == id_ra);
    wire bypass_b = HAS_REG_FORWARD && wb_reg_we && (wb_waddr == id_rs);

    wire [7:0] id_a = bypass_a ? wb_value : id_a_read;
    wire [7:0] id_b = bypass_b ? wb_value : id_b_read;

    // Load-use: the load is in EX, and its data will not exist until it reaches WB.
    wire load_use = ex_load && ((id_reads_a && ex_waddr == id_ra) ||
                                (id_reads_b && ex_waddr == id_rs));

    // Without forwarding, an instruction waits until nothing ahead of it will write
    // what it reads.
    wire wait_a = id_reads_a && ((ex_reg_we  && ex_waddr  == id_ra) ||
                                 (mem_reg_we && mem_waddr == id_ra) ||
                                 (wb_reg_we  && wb_waddr  == id_ra));
    wire wait_b = id_reads_b && ((ex_reg_we  && ex_waddr  == id_rs) ||
                                 (mem_reg_we && mem_waddr == id_rs) ||
                                 (wb_reg_we  && wb_waddr  == id_rs));
    wire wait_flags = id_reads_flags && (ex_flags_we || mem_flags_we || wb_flags_we);

    assign stall = (STEP == 2) ? (wait_a || wait_b || wait_flags) :
                   (STEP == 3) ? (load_use || wait_flags) :
                   (STEP == 4) ? load_use :
                                 1'b0;

    assign id_hold = (stall || id_pop_first) && !flush;

    // ----- ID/EX -----

    enreg #(.WIDTH(ID_EX_BITS)) u_id_ex (
        .clk(clk), .rst(rst), .en(1'b1),
        .d((stall || flush) ? {ID_EX_BITS{1'b0}} :
           {id_valid && !id_pop_first, id_pc, id_instr, id_a, id_b,
            id_alu_op, id_alu_src_imm, id_reg_we, id_waddr, id_flags_we,
            id_load, id_mem_read, id_mem_write, id_stack, id_sp_down,
            id_jmp || id_call, id_jr, id_call, id_ret, id_push,
            id_halt || id_illegal, id_illegal}),
        .q({ex_last, ex_pc, ex_instr, ex_a_read, ex_b_read,
            ex_alu_op, ex_alu_src_imm, ex_reg_we, ex_waddr, ex_flags_we,
            ex_load, ex_mem_read, ex_mem_write, ex_stack, ex_sp_down,
            ex_jump, ex_jr, ex_call, ex_ret, ex_push,
            ex_stops, ex_illegal})
    );

    // ----- EX: execute, and decide where to go next -----

    wire [7:0] ex_imm = ex_instr[7:0];
    wire [1:0] ex_ra  = ex_stack ? SP : ex_instr[11:10];
    wire [1:0] ex_rb  = ex_instr[9:8];

    // Forwarding. The nearest stage wins, because it holds the newest value.
    wire forward_a_mem = HAS_REG_FORWARD && mem_reg_we && (mem_waddr == ex_ra);
    wire forward_a_wb  = HAS_REG_FORWARD && wb_reg_we  && (wb_waddr  == ex_ra);
    wire forward_b_mem = HAS_REG_FORWARD && mem_reg_we && (mem_waddr == ex_rb);
    wire forward_b_wb  = HAS_REG_FORWARD && wb_reg_we  && (wb_waddr  == ex_rb);

    wire [7:0] ex_a = forward_a_mem ? mem_result :
                      forward_a_wb  ? wb_value   :
                                      ex_a_read;
    wire [7:0] ex_b = forward_b_mem ? mem_result :
                      forward_b_wb  ? wb_value   :
                                      ex_b_read;

    // The flags are just another register, written in WB, so they forward the same way.
    wire [3:0] flags_reg;
    wire forward_flags_mem = HAS_FLAG_FORWARD && mem_flags_we;
    wire forward_flags_wb  = HAS_FLAG_FORWARD && wb_flags_we;

    wire [3:0] ex_flags = forward_flags_mem ? mem_flags :
                          forward_flags_wb  ? wb_flags  :
                                              flags_reg;

    // Tutorial 16's decode has the branch conditions, so EX has a copy just for them,
    // given the instruction and flags of this stage. Only branch_taken is used.
    wire [1:0] unused_ex_rd, unused_ex_rs, unused_ex_waddr;
    wire [7:0] unused_ex_imm;
    wire [3:0] unused_ex_alu_op;
    wire [17:0] unused_ex_decode;

    decode u_decode_ex (
        .instr(ex_instr),
        .z(ex_flags[3]), .c(ex_flags[2]), .n(ex_flags[1]), .v(ex_flags[0]),
        .rd(unused_ex_rd), .rs(unused_ex_rs), .imm(unused_ex_imm),
        .alu_op(unused_ex_alu_op), .alu_src_imm(unused_ex_decode[0]),
        .reg_we(unused_ex_decode[1]), .reg_waddr(unused_ex_waddr),
        .flags_we(unused_ex_decode[2]),
        .mem_read(unused_ex_decode[3]), .mem_write(unused_ex_decode[4]),
        .branch_taken(ex_taken), .jump(unused_ex_decode[5]),
        .call(unused_ex_decode[6]), .ret(unused_ex_decode[7]), .push(unused_ex_decode[8]),
        .pop(unused_ex_decode[9]), .jr(unused_ex_decode[10]),
        .halt(unused_ex_decode[11]), .illegal(unused_ex_decode[12]),
        .pc_sel_next(unused_ex_decode[13]), .pc_sel_imm(unused_ex_decode[14]),
        .pc_sel_rs(unused_ex_decode[15]), .pc_sel_stack(unused_ex_decode[16]),
        .pc_sel_hold(unused_ex_decode[17])
    );

    wire [7:0] alu_y;
    wire [3:0] alu_flags_out;

    alu_flags #(.WIDTH(8)) u_alu (
        .a(ex_a),
        .b(ex_alu_src_imm ? ex_imm : ex_b),
        .carry_in(ex_flags[2]),
        .op(ex_alu_op),
        .y(alu_y),
        .z(alu_flags_out[3]), .c(alu_flags_out[2]), .n(alu_flags_out[1]), .v(alu_flags_out[0])
    );

    // The stack needs one small adder each way. A push's address and the new R3 are the
    // same number. PUSH R3 stores ex_b, the old R3, because forwarding is about what
    // came before this instruction, and R3 only changes in this one's own WB.
    wire [7:0] sp_down = ex_a - 8'd1;
    wire [7:0] sp_up   = ex_a + 8'd1;
    wire [7:0] sp_new  = ex_sp_down ? sp_down : sp_up;

    wire [7:0] ex_result = ex_stack ? sp_new : alu_y;
    wire [7:0] ex_addr   = !ex_stack  ? ex_b + ex_imm :
                           ex_sp_down ? sp_down       :
                                        ex_a;
    wire [7:0] ex_pc_plus_1 = ex_pc + 8'd1;
    wire [7:0] ex_wdata = ex_call ? ex_pc_plus_1 :
                          ex_push ? ex_b         :
                                    ex_a;           // ST stores rd

    assign ex_redirect = ex_jump || ex_jr || ex_taken;
    assign ex_target   = ex_jr ? ex_b : ex_imm;
    assign flush       = HAS_FLUSH && (ex_redirect || ex_ret || ex_stops);

    // ----- EX/MEM -----

    enreg #(.WIDTH(EX_MEM_BITS)) u_ex_mem (
        .clk(clk), .rst(rst), .en(1'b1),
        .d({ex_last, ex_pc, ex_instr, ex_result, alu_flags_out, ex_addr, ex_wdata,
            ex_reg_we, ex_waddr, ex_flags_we, ex_load, ex_mem_read, ex_mem_write,
            ex_ret, ex_stops, ex_illegal}),
        .q({mem_last, mem_pc, mem_instr, mem_result, mem_flags, mem_addr, mem_wdata,
            mem_reg_we, mem_waddr, mem_flags_we, mem_load, mem_read, mem_write,
            mem_ret, mem_stops, mem_illegal})
    );

    // ----- MEM: nothing here can be flushed, or stalled -----

    assign dmem_addr  = mem_addr;
    assign dmem_wdata = mem_wdata;
    assign dmem_re    = !rst && mem_read;
    assign dmem_we    = !rst && mem_write;

    // ----- MEM/WB -----

    enreg #(.WIDTH(MEM_WB_BITS)) u_mem_wb (
        .clk(clk), .rst(rst), .en(1'b1),
        .d({mem_last, mem_pc, mem_instr, mem_result, mem_flags,
            mem_reg_we, mem_waddr, mem_flags_we, mem_load,
            mem_ret, mem_stops, mem_illegal}),
        .q({wb_last, wb_pc, wb_instr, wb_result, wb_flags,
            wb_reg_we, wb_waddr, wb_flags_we, wb_load,
            wb_ret, wb_stops, wb_illegal})
    );

    // ----- WB: the registers were written by u_regfile, above -----

    enreg #(.WIDTH(4)) u_flags (
        .clk(clk), .rst(rst), .en(wb_flags_we), .d(wb_flags), .q(flags_reg)
    );

    // ----- Retire -----

    // One clock after WB, so the registers and flags show this instruction's result,
    // and a younger one cannot have changed them yet.
    wire retire_now;
    wire retire_stops, retire_illegal;

    enreg #(.WIDTH(1)) u_retire (
        .clk(clk), .rst(rst), .en(1'b1), .d(wb_last), .q(retire_now)
    );

    enreg #(.WIDTH(26)) u_retired (
        .clk(clk), .rst(rst), .en(wb_last),
        .d({wb_stops, wb_illegal, wb_pc, wb_instr}),
        .q({retire_stops, retire_illegal, retire_pc, retire_instr})
    );

    // HALT and illegal retire first, and these rise a clock later. Only reset clears them.
    wire halted_reg, illegal_reg;

    enreg #(.WIDTH(2)) u_halted (
        .clk(clk), .rst(rst), .en(retire_now && retire_stops),
        .d({1'b1, retire_illegal}), .q({halted_reg, illegal_reg})
    );

    assign retire  = !rst && retire_now;
    assign halted  = halted_reg;
    assign illegal = illegal_reg;

`ifdef FORMAL
    // Structural rules: what may happen when, for any program. Tutorial 18's proofs of
    // what each instruction computes are in tb/insn_check.v. imem_data and dmem_rdata
    // are free inputs, so these hold even for a memory that returns nonsense.
    reg past_valid = 1'b0;
    always @(posedge clk)
        past_valid <= 1'b1;

    always @(posedge clk) begin
        if (!past_valid)
            assume (rst);
    end

    // ----- A flushed instruction changes nothing -----

    // Clocks since a flush. Bit 0 is one clock after it, and so on. The instruction in
    // ID at the flush would reach MEM two clocks later, the one in IF three, and each
    // goes on to WB and retire. These checks are on the outputs and write enables, so
    // they do not care how the design kills anything.
    reg [5:0] f_flushed = 6'd0;
    always @(posedge clk)
        f_flushed <= rst ? 6'd0 : {f_flushed[4:0], flush};

    always @(posedge clk) begin
        if (past_valid && !rst) begin
            if (f_flushed[1] || f_flushed[2])
                assert (!dmem_we && !dmem_re);
            if (f_flushed[2] || f_flushed[3])
                assert (!wb_reg_we && !wb_flags_we);
            if (f_flushed[3] || f_flushed[4])
                assert (!retire);
        end
    end

    // ----- Retire order is fetch order -----

    // A ghost number for each instruction, given as it enters ID, which travels with it.
    // Numbers only go up, so an instruction that retires must have a higher number than
    // the last one. It also proves that no instruction retires twice, even a POP.
    reg [4:0] f_next_tag = 5'd0;
    reg [4:0] f_id_tag = 5'd0, f_ex_tag = 5'd0, f_mem_tag = 5'd0;
    reg [4:0] f_wb_tag = 5'd0, f_retire_tag = 5'd0, f_last_tag = 5'd0;
    reg       f_any_retired = 1'b0;

    wire f_id_loads = !id_hold && !flush && !front_stop;
    wire [4:0] f_tag_step = f_retire_tag - f_last_tag;

    always @(posedge clk) begin
        if (f_id_loads) begin
            f_id_tag   <= f_next_tag;
            f_next_tag <= f_next_tag + 5'd1;
        end
        f_ex_tag  <= f_id_tag;
        f_mem_tag <= f_ex_tag;
        f_wb_tag  <= f_mem_tag;
        if (wb_last)
            f_retire_tag <= f_wb_tag;

        if (rst)
            f_any_retired <= 1'b0;
        else if (retire) begin
            f_any_retired <= 1'b1;
            f_last_tag    <= f_retire_tag;
        end
    end

    always @(posedge clk) begin
        if (past_valid && !rst && retire && f_any_retired)
            assert (f_tag_step >= 5'd1 && f_tag_step <= 5'd3);
    end

    // ----- Stopping -----

    // What is left in the pipeline behind a stop on its way out.
    wire f_ex_empty  = !ex_last && !ex_reg_we && !ex_flags_we && !ex_mem_read && !ex_mem_write
                    && !ex_jump && !ex_jr && !ex_ret && !ex_stops && !ex_taken;
    wire f_mem_empty = !mem_last && !mem_reg_we && !mem_flags_we && !mem_read && !mem_write
                    && !mem_ret && !mem_stops;
    wire f_wb_empty  = !wb_last && !wb_reg_we && !wb_flags_we && !wb_ret && !wb_stops;

    reg [7:0] f_halt_pc = 8'd0;
    always @(posedge clk)
        if (ex_stops)
            f_halt_pc <= ex_pc;

    always @(posedge clk) begin
        if (past_valid && !rst) begin
            // Nothing follows a stop down the pipeline.
            if (mem_stops)
                assert (!id_valid && f_ex_empty && front_stop);
            if (wb_stops)
                assert (!id_valid && f_ex_empty && f_mem_empty && front_stop);
            if (retire_now && retire_stops)
                assert (!id_valid && f_ex_empty && f_mem_empty && f_wb_empty && front_stop);
            if (halted)
                assert (!id_valid && f_ex_empty && f_mem_empty && f_wb_empty && front_stop);

            // The same for a RET, until it is in WB and gives fetching its address.
            if (mem_ret)
                assert (!id_valid && f_ex_empty && front_stop);
            if (wb_ret)
                assert (!id_valid && f_ex_empty && f_mem_empty && front_stop);
            if (front_stop)
                assert (mem_ret || wb_ret || mem_stops || wb_stops ||
                        (retire_now && retire_stops) || halted);

            // Only a stop can raise these, and a pop's second trip follows its first.
            if (illegal)
                assert (halted);
            if (pop_second)
                assert (id_valid && id_pop);
        end
    end

    // Halted is only left through reset, and nothing moves while there.
    reg       f_was_halted = 1'b0;
    reg [7:0] f_was_pc;
    reg [3:0] f_was_flags;

    always @(posedge clk) begin
        f_was_halted <= halted && !rst;
        f_was_pc     <= pc;
        f_was_flags  <= flags_reg;
    end

    always @(posedge clk) begin
        if (past_valid && !rst) begin
            if (f_was_halted) begin
                assert (halted);
                assert (pc == f_was_pc);
                assert (flags_reg == f_was_flags);
            end
            // The registers have one write port, so this says that they stay too.
            if (halted)
                assert (!retire && !dmem_we && !dmem_re && !wb_reg_we && !wb_flags_we);
        end
    end

    // ----- Every instruction gets through -----

    reg [3:0] f_gap = 4'd0;
    always @(posedge clk) begin
        if (rst || retire || halted)
            f_gap <= 4'd0;
        else if (f_gap != 4'd15)
            f_gap <= f_gap + 4'd1;
    end

    always @(posedge clk) begin
        if (past_valid && !rst)
            assert (f_gap <= 4'd9);
    end

    // ----- Reset, and the rule that memory is only used by what is allowed to -----

    always @(posedge clk) begin
        if (past_valid) begin
            if (rst)
                assert (!dmem_we && !dmem_re && !retire);
            if ($past(rst))
                assert (pc == 8'd0 && !front_stop && !halted && !illegal && flags_reg == 4'd0);
            if (mem_write)
                assert (!mem_read);
        end
    end

    // Cover: the events the proofs are about really do happen.
    always @(posedge clk) begin
        if (past_valid && !rst) begin
            cover (retire && !halted);
            cover (stall);
            cover (flush && ex_taken);
            cover (flush && ex_ret);
            cover (flush && ex_stops);
            cover (flush && id_mem_write && id_valid);        // a wrong-path store dies
            cover (forward_a_mem && ex_last);
            cover (forward_b_wb && ex_last);
            cover (bypass_a && id_valid);
            cover (forward_flags_mem && ex_taken);
            cover (pop_second);
            cover (halted && illegal);
            cover (halted && !illegal);
        end
    end
`endif

endmodule
