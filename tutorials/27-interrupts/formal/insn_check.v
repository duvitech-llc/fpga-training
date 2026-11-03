// Per-instruction proofs for the RV32I core with machine mode, in the style of
// Tutorial 18 and of riscv-formal, but much simpler. Yosys only.
//
// This is Tutorial 21's checker, extended for Tutorial 27: the CSR instructions,
// MRET, traps that go to mtvec, bus access faults, and interrupts.
//
// rv32i runs with free inputs: the solver chooses every word the memory returns,
// for fetches and for loads, when mem_ready or mem_err comes, and both interrupt
// lines on every clock. Each sby task picks one class with CHECK. Whenever a step
// of that class happens, a retire or a trap, this module works out from the spec
// what it should have done, and asserts that it did. It shares nothing with
// rv32i.v, rv_csr.v, rv_decode.v or rv_alu.v: no wires, no names and no method.
//
// The core changes x1 to x31, pc and the CSRs only on the edge that ends a retire
// or a trap. So during that clock they still hold the values from before, and the
// operands are read from them then. The results are checked one clock later.
//
// Registers. The solver picks one register, w, and the proof follows it, as in
// Tutorial 11. w may be any of them, so the proof covers them all. The CSRs are few
// enough to check every one of them after every step that is checked.
//
// Memory. The proofs assume the memory answers, with mem_ready or mem_err, within
// MAX_WAIT clocks. Simulation tries up to 3 waits.
//
// The f_ wires marked "from insn.sby" have no driver in this file. Yosys cannot read
// a path such as u_cpu.state, so insn.sby connects them after flattening. They are
// read only through functions, operators and flip-flops, never joined to another
// wire by an assign: connect -set cuts every other driver of the net it sets.
module insn_check #(
    parameter CHECK = 0,
    parameter MAX_WAIT = 2
) (
    input wire        clk,
    input wire        rst,
    input wire        mem_ready,     // free: any timing, within MAX_WAIT
    input wire        mem_err,       // free: any access may fault
    input wire [31:0] mem_rdata,     // free: any instruction, any data
    input wire        irq_timer,     // free: any interrupt, on any clock
    input wire        irq_external
);

    localparam C_UPPER = 1, C_JAL = 2, C_JALR = 3, C_BRANCH = 4, C_LOAD = 5, C_STORE = 6,
               C_ALU_IMM = 7, C_SHIFT = 8, C_ALU_REG = 9, C_FENCE = 10, C_TRAP = 11,
               C_STRUCTURE = 12, C_CSR = 13, C_MRET = 14, C_IRQ = 15;

    // The worst case from an enabled interrupt becoming pending to its trap: the
    // rest of a load or store's MEMORY, the next fetch, and its EXECUTE.
    localparam IRQ_BOUND = 2 * (MAX_WAIT + 1) + 1;

    wire        mem_valid, mem_instr, trap, retire;
    wire [31:0] mem_addr, mem_wdata, retire_pc, retire_instr, trap_cause;
    wire [3:0]  mem_wstrb;

    rv32i u_cpu (
        .clk(clk), .rst(rst),
        .mem_valid(mem_valid), .mem_instr(mem_instr), .mem_ready(mem_ready),
        .mem_err(mem_err),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),
        .irq_timer(irq_timer), .irq_external(irq_external),
        .trap(trap), .trap_cause(trap_cause),
        .retire(retire), .retire_pc(retire_pc), .retire_instr(retire_instr)
    );

    wire [1:0]  f_state;                                       // from insn.sby
    wire [31:0] f_x1,  f_x2,  f_x3,  f_x4,  f_x5,  f_x6,  f_x7,  f_x8;   // from insn.sby
    wire [31:0] f_x9,  f_x10, f_x11, f_x12, f_x13, f_x14, f_x15, f_x16;  // from insn.sby
    wire [31:0] f_x17, f_x18, f_x19, f_x20, f_x21, f_x22, f_x23, f_x24;  // from insn.sby
    wire [31:0] f_x25, f_x26, f_x27, f_x28, f_x29, f_x30, f_x31;         // from insn.sby
    // The CSR flip-flops, from insn.sby: mstatus.MIE and MPIE, mie.MTIE and MEIE,
    // mtvec and mepc without their two fixed low bits, mscratch, mcause's interrupt
    // bit and code, and mtval.
    wire        f_mie, f_mpie, f_mtie, f_meie;                  // from insn.sby
    wire [29:0] f_mtvec, f_mepc;                                // from insn.sby
    wire [31:0] f_mscratch, f_mtval;                            // from insn.sby
    wire        f_mcause_irq;                                   // from insn.sby
    wire [3:0]  f_mcause_code;                                  // from insn.sby

    // Register n, with x0 always 0.
    function [31:0] xreg(input [4:0] n);
        case (n)
            5'd1:  xreg = f_x1;   5'd2:  xreg = f_x2;   5'd3:  xreg = f_x3;   5'd4:  xreg = f_x4;
            5'd5:  xreg = f_x5;   5'd6:  xreg = f_x6;   5'd7:  xreg = f_x7;   5'd8:  xreg = f_x8;
            5'd9:  xreg = f_x9;   5'd10: xreg = f_x10;  5'd11: xreg = f_x11;  5'd12: xreg = f_x12;
            5'd13: xreg = f_x13;  5'd14: xreg = f_x14;  5'd15: xreg = f_x15;  5'd16: xreg = f_x16;
            5'd17: xreg = f_x17;  5'd18: xreg = f_x18;  5'd19: xreg = f_x19;  5'd20: xreg = f_x20;
            5'd21: xreg = f_x21;  5'd22: xreg = f_x22;  5'd23: xreg = f_x23;  5'd24: xreg = f_x24;
            5'd25: xreg = f_x25;  5'd26: xreg = f_x26;  5'd27: xreg = f_x27;  5'd28: xreg = f_x28;
            5'd29: xreg = f_x29;  5'd30: xreg = f_x30;  5'd31: xreg = f_x31;
            default: xreg = 32'd0;
        endcase
    endfunction

    // The CSRs, as the privileged spec lays them out, and as a program reads them.
    function [31:0] csr_value(input [11:0] a);
        case (a)
            12'h300: csr_value = {19'd0, 2'b11, 3'd0, f_mpie, 3'd0, f_mie, 3'd0};   // mstatus
            12'h301: csr_value = 32'h4000_0100;                                     // misa
            12'h304: csr_value = {20'd0, f_meie, 3'd0, f_mtie, 7'd0};               // mie
            12'h305: csr_value = {f_mtvec, 2'b00};                                  // mtvec
            12'h340: csr_value = f_mscratch;
            12'h341: csr_value = {f_mepc, 2'b00};
            12'h342: csr_value = {f_mcause_irq, 27'd0, f_mcause_code};
            12'h343: csr_value = f_mtval;
            12'h344: csr_value = {20'd0, irq_external, 3'd0, irq_timer, 7'd0};      // mip
            default: csr_value = 32'd0;     // mstatush, the IDs, and those that do not exist
        endcase
    endfunction

    function csr_exists(input [11:0] a);
        csr_exists = a == 12'h300 || a == 12'h301 || a == 12'h304 || a == 12'h305 ||
                     a == 12'h310 || (a >= 12'h340 && a <= 12'h344) ||
                     (a >= 12'hF11 && a <= 12'hF15);
    endfunction

    reg past_valid = 1'b0;
    always @(posedge clk)
        past_valid <= 1'b1;

    // ----- What may be assumed -----

    // A proof starts as a reset ends: in FETCH with no request yet. pc, all the
    // registers and the CSRs are free. Cover starts from a real reset.
    always @(posedge clk) begin
        if (!past_valid) begin
            if (CHECK == 0)
                assume (rst);
            else
                assume (f_state == 2'd0 && !mem_valid);
        end
    end

    // The memory answers within MAX_WAIT clocks, with mem_ready or mem_err, never
    // both, and only to a request.
    reg [3:0] waited = 4'd0;
    always @(posedge clk)
        waited <= (mem_valid && !mem_ready && !mem_err) ? waited + 4'd1 : 4'd0;
    always @(*) begin
        if (mem_valid && waited >= MAX_WAIT)
            assume (mem_ready || mem_err);
        assume (!(mem_ready && mem_err));
        if (!mem_valid)
            assume (!mem_err);
    end

    // ----- The state before this instruction, and what it did on the bus -----

    (* anyconst *) reg [4:0] w;          // the watched register

    reg        boundary = 1'b1;          // the first clock of an instruction
    reg [31:0] pre_pc_q, pre_w_q;        // captured at the end of the boundary clock
    // pc and w before this instruction, on every clock of it. On the boundary clock
    // itself the capture has not happened yet, so they are read directly. In Tutorial
    // 21 nothing could end on that clock. Now a fetch can fault on it.
    wire [31:0] pre_pc = boundary ? retire_pc : pre_pc_q;
    wire [31:0] pre_w  = boundary ? xreg(w) : pre_w_q;

    wire fetch_now = mem_valid && mem_ready && mem_instr;
    wire data_now  = mem_valid && mem_ready && !mem_instr;
    wire fault_now = mem_valid && mem_err;

    reg [1:0]  fetches = 2'd0, datas = 2'd0;      // how many, stopping at 3
    reg [31:0] fetch_addr, fetch_word;
    reg [3:0]  fetch_strb;
    reg [31:0] data_addr, data_wdata, data_rdata;
    reg [3:0]  data_strb;

    wire [1:0] fetches_before = boundary ? 2'd0 : fetches;
    wire [1:0] datas_before   = boundary ? 2'd0 : datas;
    wire [1:0] fetches_so_far = fetches_before + ((fetch_now && fetches_before != 2'd3) ? 2'd1 : 2'd0);
    wire [1:0] datas_so_far   = datas_before   + ((data_now  && datas_before   != 2'd3) ? 2'd1 : 2'd0);

    always @(posedge clk) begin
        // A trap ends an instruction too, now that the core goes on after it.
        boundary <= rst || retire || trap;
        if (boundary) begin
            pre_pc_q <= retire_pc;
            pre_w_q  <= xreg(w);
        end

        fetches <= fetches_so_far;
        datas   <= datas_so_far;

        if (fetch_now) begin
            fetch_addr <= mem_addr;
            fetch_word <= mem_rdata;
            fetch_strb <= mem_wstrb;
        end
        if (data_now) begin
            data_addr  <= mem_addr;
            data_wdata <= mem_wdata;
            data_rdata <= mem_rdata;
            data_strb  <= mem_wstrb;
        end
    end

    wire [31:0] d_addr = data_now ? mem_addr  : data_addr;
    wire [31:0] d_wdata = data_now ? mem_wdata : data_wdata;
    wire [31:0] d_rdata = data_now ? mem_rdata : data_rdata;
    wire [3:0]  d_strb  = data_now ? mem_wstrb : data_strb;

    // ----- The instruction, read from the spec -----

    wire [31:0] i      = retire_instr;
    wire [6:0]  opcode = i[6:0];
    wire [4:0]  rd     = i[11:7];
    wire [2:0]  funct3 = i[14:12];
    wire [4:0]  rs1    = i[19:15];
    wire [4:0]  rs2    = i[24:20];
    wire [6:0]  funct7 = i[31:25];
    wire [11:0] csr    = i[31:20];

    wire signed [31:0] imm_i = $signed(i[31:20]);
    wire signed [31:0] imm_s = $signed({i[31:25], i[11:7]});
    wire signed [31:0] imm_b = $signed({i[31], i[7], i[30:25], i[11:8], 1'b0});
    wire signed [31:0] imm_u = $signed({i[31:12], 12'd0});
    wire signed [31:0] imm_j = $signed({i[31], i[19:12], i[20], i[30:21], 1'b0});

    wire is_lui    = opcode == 7'h37;
    wire is_auipc  = opcode == 7'h17;
    wire is_jal    = opcode == 7'h6F;
    wire is_jalr   = opcode == 7'h67 && funct3 == 3'd0;
    wire is_branch = opcode == 7'h63 && funct3 != 3'd2 && funct3 != 3'd3;
    wire is_load   = opcode == 7'h03 && funct3 != 3'd3 && funct3 != 3'd6 && funct3 != 3'd7;
    wire is_store  = opcode == 7'h23 && funct3 <= 3'd2;
    wire is_shift_imm = opcode == 7'h13 && ((funct3 == 3'd1 && funct7 == 7'h00) ||
                                            (funct3 == 3'd5 && (funct7 == 7'h00 || funct7 == 7'h20)));
    wire is_alu_imm   = opcode == 7'h13 && funct3 != 3'd1 && funct3 != 3'd5;
    wire is_shift_reg = opcode == 7'h33 && ((funct3 == 3'd1 && funct7 == 7'h00) ||
                                            (funct3 == 3'd5 && (funct7 == 7'h00 || funct7 == 7'h20)));
    wire is_alu_reg   = opcode == 7'h33 && funct3 != 3'd1 && funct3 != 3'd5 &&
                        (funct7 == 7'h00 || (funct7 == 7'h20 && funct3 == 3'd0));
    wire is_fence  = opcode == 7'h0F && funct3 == 3'd0;
    wire is_ecall  = i == 32'h00000073;
    wire is_ebreak = i == 32'h00100073;
    wire is_mret   = i == 32'h30200073;

    // A CSR instruction is legal if its CSR exists, and it does not write one whose
    // number starts with 11. W writes always; S and C only if rs1, or the
    // immediate, is not 0.
    wire csr_op     = opcode == 7'h73 && funct3 != 3'd0 && funct3 != 3'd4;
    wire csr_writes = funct3[1:0] == 2'b01 || rs1 != 5'd0;
    wire is_csr     = csr_op && csr_exists(csr) && !(csr_writes && csr[11:10] == 2'b11);

    wire [3:0] kinds = is_lui + is_auipc + is_jal + is_jalr + is_branch + is_load + is_store
                     + is_shift_imm + is_alu_imm + is_shift_reg + is_alu_reg + is_fence
                     + is_ecall + is_ebreak + is_mret + is_csr;
    wire is_illegal = kinds == 4'd0;

    // ----- What the spec says it does -----

    wire [31:0] a = xreg(rs1);
    wire [31:0] b = xreg(rs2);
    wire [31:0] operand = (opcode == 7'h33) ? b : imm_i;
    wire [4:0]  shamt   = operand[4:0];

    wire [32:0] diff_s = {a[31], a} - {operand[31], operand};
    wire [32:0] diff_u = {1'b0, a} - {1'b0, operand};
    wire        lt_s   = diff_s[32];
    wire        lt_u   = diff_u[32];

    wire alt = funct7 == 7'h20;
    wire [31:0] alu_value =
        funct3 == 3'd0 ? ((opcode == 7'h33 && alt) ? a - b : a + operand) :
        funct3 == 3'd2 ? {31'd0, lt_s} :
        funct3 == 3'd3 ? {31'd0, lt_u} :
        funct3 == 3'd4 ? a ^ operand :
        funct3 == 3'd6 ? a | operand :
                         a & operand;

    wire [31:0] filled = ~(32'hFFFFFFFF >> shamt);
    wire [31:0] shift_value =
        funct3 == 3'd1 ? a << shamt :
        (alt && a[31]) ? (a >> shamt) | filled :
                         a >> shamt;

    wire [32:0] cmp_s = {a[31], a} - {b[31], b};
    wire [32:0] cmp_u = {1'b0, a} - {1'b0, b};
    wire taken = funct3 == 3'd0 ? a == b :
                 funct3 == 3'd1 ? a != b :
                 funct3 == 3'd4 ? cmp_s[32] :
                 funct3 == 3'd5 ? !cmp_s[32] :
                 funct3 == 3'd6 ? cmp_u[32] :
                                  !cmp_u[32];

    wire [31:0] pc_next = pre_pc + 32'd4;
    wire [31:0] jal_to  = pre_pc + imm_j;
    wire [31:0] jalr_to = (a + imm_i) & ~32'd1;
    wire [31:0] br_to   = pre_pc + imm_b;
    wire        jumps   = is_jal || is_jalr || (is_branch && taken);
    wire [31:0] jump_to = is_jal ? jal_to : is_jalr ? jalr_to : br_to;

    wire [31:0] ea      = a + (is_store ? imm_s : imm_i);
    wire [2:0]  size    = funct3[1:0] == 2'd0 ? 3'd1 : funct3[1:0] == 2'd1 ? 3'd2 : 3'd4;
    wire        ea_bad  = (ea & ({29'd0, size} - 32'd1)) != 32'd0;
    wire [4:0]  shift8  = {ea[1:0], 3'b000};
    wire [31:0] raw     = d_rdata >> shift8;
    wire [31:0] lb      = ({24'd0, raw[7:0]}  ^ 32'h80)   - 32'h80;
    wire [31:0] lh      = ({16'd0, raw[15:0]} ^ 32'h8000) - 32'h8000;
    wire [31:0] load_value = funct3 == 3'd0 ? lb :
                             funct3 == 3'd1 ? lh :
                             funct3 == 3'd2 ? d_rdata :
                             funct3 == 3'd4 ? {24'd0, raw[7:0]} :
                                              {16'd0, raw[15:0]};
    wire [3:0]  want_strb  = (size == 3'd1 ? 4'b0001 : size == 3'd2 ? 4'b0011 : 4'b1111) << ea[1:0];
    wire [31:0] store_lanes = (size == 3'd1 ? {24'd0, b[7:0]} :
                               size == 3'd2 ? {16'd0, b[15:0]} : b) << shift8;
    wire [31:0] lane_mask  = {{8{want_strb[3]}}, {8{want_strb[2]}},
                              {8{want_strb[1]}}, {8{want_strb[0]}}};

    // The CSR instruction: the old value goes to rd, the new one to the CSR.
    wire [31:0] csr_old    = csr_value(csr);
    wire [31:0] csr_source = funct3[2] ? {27'd0, rs1} : a;
    wire [31:0] csr_new    = funct3[1:0] == 2'b01 ? csr_source :
                             funct3[1:0] == 2'b10 ? (csr_old | csr_source) :
                                                    (csr_old & ~csr_source);

    // Exceptions of the instruction itself, with their mcause codes and mtval.
    wire jump_bad   = jumps && jump_to[1:0] != 2'd0;
    wire mem_bad    = (is_load || is_store) && ea_bad;
    wire want_trap  = is_illegal || is_ecall || is_ebreak || jump_bad || mem_bad;
    wire [3:0] want_cause = is_illegal ? 4'd2 : is_ecall ? 4'd11 : is_ebreak ? 4'd3 :
                            jump_bad ? 4'd0 : is_load ? 4'd4 : 4'd6;
    wire [31:0] want_tval = is_illegal ? i : is_ecall ? 32'd0 : is_ebreak ? pre_pc :
                            jump_bad ? jump_to : ea;

    // An interrupt, by the spec: MIE set, and a line both pending and enabled.
    // External comes before timer.
    wire ext_on   = f_meie && irq_external;
    wire timer_on = f_mtie && irq_timer;
    wire want_irq = f_mie && (ext_on || timer_on);
    wire [31:0] irq_cause = ext_on ? 32'h8000_000B : 32'h8000_0007;

    // What a trap on this clock should be: a fault if a transfer just failed, else
    // an interrupt if one is wanted, else the instruction's own exception.
    wire        is_fault  = fault_now;
    wire        is_irq    = !fault_now && want_irq;
    wire [31:0] exp_cause = is_fault ? (mem_instr ? 32'd1 : mem_wstrb != 4'd0 ? 32'd7 : 32'd5) :
                            is_irq   ? irq_cause : {28'd0, want_cause};
    wire [31:0] exp_tval  = is_fault ? (mem_instr ? pre_pc : ea) :
                            is_irq   ? 32'd0 : want_tval;

    // The register write and the next pc.
    wire writes_rd = is_lui || is_auipc || is_jal || is_jalr || is_load || is_alu_imm
                  || is_alu_reg || is_shift_imm || is_shift_reg || is_csr;
    wire [31:0] rd_value = is_lui   ? imm_u :
                           is_auipc ? pre_pc + imm_u :
                           (is_jal || is_jalr) ? pc_next :
                           is_load  ? load_value :
                           is_csr   ? csr_old :
                           (is_shift_imm || is_shift_reg) ? shift_value :
                                      alu_value;
    wire [31:0] want_pc = is_mret ? {f_mepc, 2'b00} : jumps ? jump_to : pc_next;

    wire this_class = (CHECK == C_UPPER   && (is_lui || is_auipc)) ||
                      (CHECK == C_JAL     && is_jal)     || (CHECK == C_JALR  && is_jalr) ||
                      (CHECK == C_BRANCH  && is_branch)  || (CHECK == C_LOAD  && is_load) ||
                      (CHECK == C_STORE   && is_store)   ||
                      (CHECK == C_ALU_IMM && is_alu_imm) ||
                      (CHECK == C_SHIFT   && (is_shift_imm || is_shift_reg)) ||
                      (CHECK == C_ALU_REG && is_alu_reg) || (CHECK == C_FENCE && is_fence) ||
                      (CHECK == C_CSR     && is_csr)     || (CHECK == C_MRET  && is_mret);

    // ----- The checks for one class -----

    reg        check_next = 1'b0;
    reg [31:0] w_after, pc_after;

    always @(posedge clk) begin
        check_next <= retire && this_class;
        w_after    <= (writes_rd && rd == w && w != 5'd0) ? rd_value : pre_w;
        pc_after   <= want_pc;
    end

    always @(posedge clk) begin
        if (past_valid && retire && this_class) begin
            assert (fetches_so_far == 2'd1 && fetch_addr == pre_pc && fetch_strb == 4'd0);
            assert (i == fetch_word);
            assert (retire_pc == pre_pc);
            assert (xreg(w) == pre_w);
            assert (!want_trap);
            assert (datas_so_far == ((is_load || is_store) ? 2'd1 : 2'd0));
            if (is_load || is_store)
                assert (d_addr == {ea[31:2], 2'b00});
            if (is_load)
                assert (d_strb == 4'd0);
            if (is_store) begin
                assert (d_strb == want_strb);
                assert ((d_wdata & lane_mask) == store_lanes);
            end
        end

        if (past_valid && check_next) begin
            assert (xreg(w) == w_after);
            assert (retire_pc == pc_after);
        end
    end

    // ----- The CSRs after a step -----

    // What every CSR field should hold after this clock, if it ends a step: a trap
    // writes mepc, mcause and mtval, and moves MIE to MPIE. MRET moves MPIE back to
    // MIE and sets MPIE. A CSR instruction writes its CSR, keeping only the bits the
    // CSR has. Anything else changes nothing.
    wire csr_wr = retire && is_csr && csr_writes;
    wire ret_now = retire && is_mret;
    reg        e_mie, e_mpie, e_mtie, e_meie, e_mcause_irq;
    reg [29:0] e_mtvec, e_mepc;
    reg [31:0] e_mscratch, e_mtval, e_pc;
    reg [3:0]  e_mcause_code;
    reg        check_csrs = 1'b0;

    wire step_checked = (CHECK == C_CSR       && retire && is_csr) ||
                        (CHECK == C_MRET      && retire && is_mret) ||
                        (CHECK == C_TRAP      && trap && !is_irq) ||
                        (CHECK == C_IRQ       && trap && is_irq) ||
                        (CHECK == C_STRUCTURE && retire && !is_csr && !is_mret);

    always @(posedge clk) begin
        check_csrs    <= step_checked;
        e_mie         <= trap ? 1'b0 : ret_now ? f_mpie :
                         (csr_wr && csr == 12'h300) ? csr_new[3] : f_mie;
        e_mpie        <= trap ? f_mie : ret_now ? 1'b1 :
                         (csr_wr && csr == 12'h300) ? csr_new[7] : f_mpie;
        e_mtie        <= (csr_wr && csr == 12'h304) ? csr_new[7] : f_mtie;
        e_meie        <= (csr_wr && csr == 12'h304) ? csr_new[11] : f_meie;
        e_mtvec       <= (csr_wr && csr == 12'h305) ? csr_new[31:2] : f_mtvec;
        e_mscratch    <= (csr_wr && csr == 12'h340) ? csr_new : f_mscratch;
        e_mepc        <= trap ? pre_pc[31:2] : (csr_wr && csr == 12'h341) ? csr_new[31:2] : f_mepc;
        e_mcause_irq  <= trap ? exp_cause[31] : (csr_wr && csr == 12'h342) ? csr_new[31] : f_mcause_irq;
        e_mcause_code <= trap ? exp_cause[3:0] : (csr_wr && csr == 12'h342) ? csr_new[3:0] : f_mcause_code;
        e_mtval       <= trap ? exp_tval : (csr_wr && csr == 12'h343) ? csr_new : f_mtval;
        e_pc          <= {f_mtvec, 2'b00};
    end

    always @(posedge clk) begin
        if (past_valid && check_csrs) begin
            assert (f_mie == e_mie && f_mpie == e_mpie);
            assert (f_mtie == e_mtie && f_meie == e_meie);
            assert (f_mtvec == e_mtvec);
            assert (f_mscratch == e_mscratch);
            assert (f_mepc == e_mepc);
            assert (f_mcause_irq == e_mcause_irq && f_mcause_code == e_mcause_code);
            assert (f_mtval == e_mtval);
        end
    end

    // ----- Traps: exceptions and faults, and interrupts -----

    reg trap_next = 1'b0;
    always @(posedge clk)
        trap_next <= trap && ((CHECK == C_TRAP && !is_irq) || (CHECK == C_IRQ && is_irq));

    generate
        if (CHECK == C_TRAP || CHECK == C_IRQ) begin : gen_trap
            always @(posedge clk) begin
                // An instruction that must trap never retires.
                if (past_valid && retire)
                    assert (!want_trap);

                // Facts that structure proves, repeated here so that induction
                // cannot start in a state no reset reaches: the core stuck in
                // MEMORY with no request, waiting for nothing. The first version
                // of the irq task failed induction on exactly that.
                if (past_valid) begin
                    assert (f_state != 2'd3);
                    if (f_state == 2'd2)
                        assert (mem_valid && !mem_instr);
                    assert (age <= 2 * MAX_WAIT + 3);
                end

                // Every trap is one the spec asks for, with its cause. Nothing the
                // instruction would have written is written, and pc is its own.
                if (past_valid && trap) begin
                    assert (trap_cause == exp_cause);
                    assert (retire_pc == pre_pc);
                    assert (xreg(w) == pre_w);
                    assert (datas_so_far == 2'd0);
                    if (is_fault && mem_instr) begin
                        assert (fetches_so_far == 2'd0 && mem_addr == pre_pc);
                    end else begin
                        assert (fetches_so_far == 2'd1 && fetch_addr == pre_pc && i == fetch_word);
                        if (is_fault)
                            assert ((is_load || is_store) && !ea_bad
                                    && mem_addr == {ea[31:2], 2'b00}
                                    && mem_wstrb == (is_store ? want_strb : 4'd0));
                        else if (!is_irq)
                            assert (want_trap);
                    end
                end

                // After it: the handler's address, and nothing else changed.
                if (past_valid && trap_next) begin
                    assert (retire_pc == e_pc);
                    assert (xreg(w) == pre_w);
                end
            end
        end
    endgenerate

    // Interrupts: taken when the spec says, and within a bounded time.
    reg [3:0] pend_age = 4'd0;      // clocks an enabled interrupt has waited
    always @(posedge clk)
        if (rst || trap || !want_irq)
            pend_age <= 4'd0;
        else if (pend_age != 4'd15)
            pend_age <= pend_age + 4'd1;

    generate
        if (CHECK == C_IRQ) begin : gen_irq
            always @(posedge clk) begin
                if (past_valid && !rst) begin
                    // In EXECUTE, an enabled pending interrupt is taken, before the
                    // instruction, whatever it is.
                    if (f_state == 2'd1 && want_irq)
                        assert (trap && trap_cause == irq_cause);
                    // And no interrupt is taken that the spec does not ask for.
                    if (trap && trap_cause[31])
                        assert (is_irq);
                    // Within IRQ_BOUND clocks of becoming pending, while enabled.
                    assert (pend_age < IRQ_BOUND);
                end
            end
        end
    endgenerate

    // ----- Structure, and the memory interface -----

    reg [3:0]  age = 4'd0;
    reg        past_rst = 1'b0;
    reg        past_waiting = 1'b0;
    reg        past_fault = 1'b0;
    reg [68:0] past_request;
    wire [68:0] request = {mem_instr, mem_addr, mem_wdata, mem_wstrb};

    always @(posedge clk) begin
        past_rst     <= rst;
        past_waiting <= mem_valid && !mem_ready && !mem_err && !rst;
        past_fault   <= fault_now && !rst;
        past_request <= request;
        if (rst || boundary)
            age <= 4'd0;
        else if (age != 4'd15)
            age <= age + 4'd1;
    end

    generate
        if (CHECK == C_STRUCTURE) begin : gen_structure
            always @(posedge clk) begin
                if (past_valid) begin
                    // The decoding above splits all 2**32 words with no overlaps.
                    assert (kinds <= 4'd1);

                    // Reset gives the spec's state, and no request.
                    if (past_rst) begin
                        assert (retire_pc == 32'd0 && !mem_valid && !trap && !retire);
                        assert (xreg(w) == 32'd0);
                        assert (!f_mie && !f_mtie && !f_meie);
                    end

                    // A waiting request holds still until it ends.
                    if (past_waiting && !past_rst) begin
                        assert (mem_valid);
                        assert (request == past_request);
                    end

                    // After mem_err, mem_valid is low for a clock.
                    if (past_fault && !past_rst)
                        assert (!mem_valid);

                    if (mem_valid) begin
                        assert (mem_addr[1:0] == 2'b00);
                        if (mem_instr)
                            assert (mem_wstrb == 4'd0);
                    end

                    // Every instruction ends, by a retire or a trap.
                    assert (age <= 2 * MAX_WAIT + 3);

                    // retire and trap are single clocks, and never together.
                    if (boundary)
                        assert (!retire);
                    assert (!(retire && trap));
                end
            end

            always @(posedge clk) begin
                if (!past_valid)
                    assume (retire_pc[1:0] == 2'b00);
                else
                    assert (retire_pc[1:0] == 2'b00);
            end
        end
    endgenerate

    // ----- Cover: the proofs above are about something -----

    always @(posedge clk) begin
        if (past_valid && !rst) begin
            if (retire) begin
                cover (is_lui);
                cover (is_auipc);
                cover (is_jal);
                cover (is_jalr);
                cover (is_branch && taken);
                cover (is_branch && !taken);
                cover (is_load && funct3 == 3'd0 && ea[1:0] == 2'd3);
                cover (is_load && funct3 == 3'd5 && ea[1:0] == 2'd2);
                cover (is_load && funct3 == 3'd2);
                cover (is_store && funct3 == 3'd0 && ea[1:0] == 2'd1);
                cover (is_store && funct3 == 3'd1 && ea[1:0] == 2'd2);
                cover (is_store && funct3 == 3'd2);
                cover (is_alu_imm);
                cover (is_alu_reg && alt);
                cover (is_shift_imm && alt);
                cover (is_shift_reg);
                cover (is_fence);
                cover (writes_rd && rd == 5'd0);
                cover (is_load && waited == 4'd2);
                cover (is_csr && funct3 == 3'd1 && csr == 12'h305);      // csrrw mtvec
                cover (is_csr && funct3 == 3'd6 && csr == 12'h300);      // csrrsi mstatus
                cover (is_csr && funct3 == 3'd3 && csr == 12'h304);      // csrrc mie
                cover (is_csr && funct3 == 3'd2 && csr == 12'h344 && rs1 == 5'd0);  // csrr mip
                cover (is_mret && f_mpie);
            end
            if (trap) begin
                cover (trap_cause == 32'd0);
                cover (trap_cause == 32'd1);
                cover (trap_cause == 32'd2);
                cover (trap_cause == 32'd2 && csr_op);
                cover (trap_cause == 32'd3);
                cover (trap_cause == 32'd4);
                cover (trap_cause == 32'd5);
                cover (trap_cause == 32'd6);
                cover (trap_cause == 32'd7);
                cover (trap_cause == 32'd11);
                cover (trap_cause == 32'h8000_0007);
                cover (trap_cause == 32'h8000_000B && timer_on);  // both lines: external first
                cover (trap_cause[31] && pend_age == IRQ_BOUND - 1);
            end
        end
    end

endmodule
