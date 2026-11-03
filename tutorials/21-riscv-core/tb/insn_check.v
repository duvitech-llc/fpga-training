// Per-instruction proofs for the RV32I core, in the style of Tutorial 18 and of
// riscv-formal, but much simpler. Yosys only.
//
// rv32i runs with free inputs: the solver chooses every word the memory returns,
// for fetches and for loads, and when mem_ready comes. Each sby task picks one class
// with CHECK. Whenever an instruction of that class retires, this module works out
// from the spec what it should have done, and asserts that it did. It shares nothing
// with rv32i.v, rv_decode.v or rv_alu.v: no wires, no names and no method.
//
// The core changes x1 to x31 and pc only on the edge that ends a retire. So while
// retire is high they still hold the values from before the instruction, and the
// operands are read from them then. The results are checked one clock later.
//
// Registers. Keeping a copy of all 31 would be slow, so the solver picks one, w,
// and the proof follows it, as in Tutorial 11. w may be any of them, so the proof
// covers them all: it must keep its value through the instruction, and afterwards
// hold the new value if it was rd, and the old one if not.
//
// Memory. The proofs assume the memory answers within MAX_WAIT clocks. Without a
// limit an instruction could wait forever, and induction could start in the middle
// of one, after its state was copied. Simulation tries up to 3 waits.
//
// The f_ wires marked "from insn.sby" have no driver in this file. Yosys cannot read
// a path such as u_cpu.state, so insn.sby connects them after flattening.
module insn_check #(
    parameter CHECK = 0,
    parameter MAX_WAIT = 2
) (
    input wire        clk,
    input wire        rst,
    input wire        mem_ready,     // free: any timing, within MAX_WAIT
    input wire [31:0] mem_rdata      // free: any instruction, any data
);

    localparam C_UPPER = 1, C_JAL = 2, C_JALR = 3, C_BRANCH = 4, C_LOAD = 5, C_STORE = 6,
               C_ALU_IMM = 7, C_SHIFT = 8, C_ALU_REG = 9, C_FENCE = 10, C_TRAP = 11,
               C_STRUCTURE = 12;

    wire        mem_valid, mem_instr, trap, retire;
    wire [31:0] mem_addr, mem_wdata, retire_pc, retire_instr;
    wire [3:0]  mem_wstrb, trap_cause;

    rv32i u_cpu (
        .clk(clk), .rst(rst),
        .mem_valid(mem_valid), .mem_instr(mem_instr), .mem_ready(mem_ready),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),
        .trap(trap), .trap_cause(trap_cause),
        .retire(retire), .retire_pc(retire_pc), .retire_instr(retire_instr)
    );

    wire [1:0]  f_state;                                       // from insn.sby
    wire [31:0] f_x1,  f_x2,  f_x3,  f_x4,  f_x5,  f_x6,  f_x7,  f_x8;   // from insn.sby
    wire [31:0] f_x9,  f_x10, f_x11, f_x12, f_x13, f_x14, f_x15, f_x16;  // from insn.sby
    wire [31:0] f_x17, f_x18, f_x19, f_x20, f_x21, f_x22, f_x23, f_x24;  // from insn.sby
    wire [31:0] f_x25, f_x26, f_x27, f_x28, f_x29, f_x30, f_x31;         // from insn.sby

    // Register n, with x0 always 0. The f_ wires are read here and nowhere else. They
    // must not be joined to other wires by an assign: connect -set in insn.sby cuts
    // every other driver of the net it sets, and that would cut the assign too.
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

    reg past_valid = 1'b0;
    always @(posedge clk)
        past_valid <= 1'b1;

    // ----- What may be assumed -----

    // A proof starts as a reset ends: in FETCH with no request yet. pc and all the
    // registers are free. Cover starts from a real reset, to show each class can
    // really be reached.
    always @(posedge clk) begin
        if (!past_valid) begin
            if (CHECK == 0)
                assume (rst);
            else
                assume (f_state == 2'd0 && !mem_valid);
        end
    end

    // The memory answers within MAX_WAIT clocks.
    reg [3:0] waited = 4'd0;
    always @(posedge clk)
        waited <= (mem_valid && !mem_ready) ? waited + 4'd1 : 4'd0;
    always @(*)
        if (mem_valid && waited >= MAX_WAIT)
            assume (mem_ready);

    // ----- The state before this instruction, and what it did on the bus -----

    (* anyconst *) reg [4:0] w;          // the watched register

    reg        boundary = 1'b1;          // the first clock of an instruction
    reg [31:0] pre_pc, pre_w;

    wire fetch_now = mem_valid && mem_ready && mem_instr;
    wire data_now  = mem_valid && mem_ready && !mem_instr;

    reg [1:0]  fetches = 2'd0, datas = 2'd0;      // how many, stopping at 3
    reg [31:0] fetch_addr, fetch_word;
    reg [3:0]  fetch_strb;
    reg [31:0] data_addr, data_wdata, data_rdata;
    reg [3:0]  data_strb;

    // Transfers in this instruction so far, this clock included, since a load or store
    // finishes on the clock of its transfer. On the boundary clock the old count is gone.
    // The count stops at 3, and that test uses the new count: an early version tested
    // the old one, and induction found a fetch it never counted.
    wire [1:0] fetches_before = boundary ? 2'd0 : fetches;
    wire [1:0] datas_before   = boundary ? 2'd0 : datas;
    wire [1:0] fetches_so_far = fetches_before + ((fetch_now && fetches_before != 2'd3) ? 2'd1 : 2'd0);
    wire [1:0] datas_so_far   = datas_before   + ((data_now  && datas_before   != 2'd3) ? 2'd1 : 2'd0);

    always @(posedge clk) begin
        boundary <= rst || retire;
        if (boundary) begin
            pre_pc <= retire_pc;
            pre_w  <= xreg(w);
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

    // The data transfer, if it is happening on this clock.
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

    wire [3:0] kinds = is_lui + is_auipc + is_jal + is_jalr + is_branch + is_load + is_store
                     + is_shift_imm + is_alu_imm + is_shift_reg + is_alu_reg + is_fence
                     + is_ecall + is_ebreak;
    wire is_illegal = kinds == 4'd0;

    // ----- What the spec says it does -----

    wire [31:0] a = xreg(rs1);
    wire [31:0] b = xreg(rs2);
    wire [31:0] operand = (opcode == 7'h33) ? b : imm_i;
    wire [4:0]  shamt   = operand[4:0];

    // Compares by the sign of a 33-bit difference, so they cannot overflow.
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

    // An arithmetic shift is a logical shift with the sign copied into the top bits.
    wire [31:0] filled = ~(32'hFFFFFFFF >> shamt);
    wire [31:0] shift_value =
        funct3 == 3'd1 ? a << shamt :
        (alt && a[31]) ? (a >> shamt) | filled :
                         a >> shamt;

    // Branches compare a with b, both as numbers.
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

    // Loads and stores. size is 1, 2 or 4 bytes.
    wire [31:0] ea      = a + (is_store ? imm_s : imm_i);
    wire [2:0]  size    = funct3[1:0] == 2'd0 ? 3'd1 : funct3[1:0] == 2'd1 ? 3'd2 : 3'd4;
    wire        ea_bad  = (ea & ({29'd0, size} - 32'd1)) != 32'd0;
    wire [4:0]  shift8  = {ea[1:0], 3'b000};
    wire [31:0] raw     = d_rdata >> shift8;
    // Sign extension by arithmetic: flip the sign bit, then subtract it back.
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

    // Traps, with their mcause codes.
    wire jump_bad   = jumps && jump_to[1:0] != 2'd0;
    wire mem_bad    = (is_load || is_store) && ea_bad;
    wire want_trap  = is_illegal || is_ecall || is_ebreak || jump_bad || mem_bad;
    wire [3:0] want_cause = is_illegal ? 4'd2 : is_ecall ? 4'd11 : is_ebreak ? 4'd3 :
                            jump_bad ? 4'd0 : is_load ? 4'd4 : 4'd6;

    // The register write and the next pc.
    wire writes_rd = is_lui || is_auipc || is_jal || is_jalr || is_load || is_alu_imm
                  || is_alu_reg || is_shift_imm || is_shift_reg;
    wire [31:0] rd_value = is_lui   ? imm_u :
                           is_auipc ? pre_pc + imm_u :
                           (is_jal || is_jalr) ? pc_next :
                           is_load  ? load_value :
                           (is_shift_imm || is_shift_reg) ? shift_value :
                                      alu_value;
    wire [31:0] want_pc = jumps ? jump_to : pc_next;

    wire this_class = (CHECK == C_UPPER   && (is_lui || is_auipc)) ||
                      (CHECK == C_JAL     && is_jal)     || (CHECK == C_JALR  && is_jalr) ||
                      (CHECK == C_BRANCH  && is_branch)  || (CHECK == C_LOAD  && is_load) ||
                      (CHECK == C_STORE   && is_store)   ||
                      (CHECK == C_ALU_IMM && is_alu_imm) ||
                      (CHECK == C_SHIFT   && (is_shift_imm || is_shift_reg)) ||
                      (CHECK == C_ALU_REG && is_alu_reg) || (CHECK == C_FENCE && is_fence);

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
            // Fetched once, from its own pc, and nothing moved before the retire.
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

        // pc and the registers change on the retire edge, so they are checked after it.
        if (past_valid && check_next) begin
            assert (xreg(w) == w_after);
            assert (retire_pc == pc_after);
            assert (!trap);
        end
    end

    // ----- Traps -----

    reg past_trap = 1'b0;
    always @(posedge clk)
        past_trap <= trap && !rst;

    generate
        if (CHECK == C_TRAP) begin : gen_trap
            always @(posedge clk) begin
                // An instruction that must trap never retires.
                if (past_valid && retire)
                    assert (!want_trap);

                // A trap is right, and changed nothing: no data transfer, no register
                // and no pc. A misaligned load or store never reaches the bus.
                if (past_valid && trap && !past_trap) begin
                    assert (want_trap);
                    assert (trap_cause == want_cause);
                    assert (fetches_so_far == 2'd1 && fetch_addr == pre_pc && i == fetch_word);
                    assert (datas_so_far == 2'd0);
                    assert (retire_pc == pre_pc);
                    assert (xreg(w) == pre_w);
                end
            end
        end
    endgenerate

    // ----- Structure, and the memory interface -----

    reg [3:0]  age = 4'd0;           // clocks since this instruction began
    reg        past_rst = 1'b0;
    reg        past_waiting = 1'b0;   // a request was waiting at the last edge
    reg [68:0] past_request;
    wire [68:0] request = {mem_instr, mem_addr, mem_wdata, mem_wstrb};

    always @(posedge clk) begin
        past_rst     <= rst;
        past_waiting <= mem_valid && !mem_ready && !rst;
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
                    end

                    // A waiting request holds still until mem_ready.
                    if (past_waiting && !past_rst) begin
                        assert (mem_valid);
                        assert (request == past_request);
                    end

                    // Every request is to a word address, and a fetch never writes.
                    if (mem_valid) begin
                        assert (mem_addr[1:0] == 2'b00);
                        if (mem_instr)
                            assert (mem_wstrb == 4'd0);
                    end

                    // Every instruction ends, within 2 * MAX_WAIT + 3 clocks.
                    if (!trap)
                        assert (age <= 2 * MAX_WAIT + 3);

                    // retire is a single clock, never in a trap.
                    if (boundary)
                        assert (!retire);
                    if (trap)
                        assert (!retire);

                    // A trap is left only by reset, and nothing moves while there.
                    if (past_trap && !past_rst) begin
                        assert (trap);
                        assert (!mem_valid);
                        assert (retire_pc == pre_pc && xreg(w) == pre_w);
                    end
                end
            end

            // pc is always a multiple of 4. A proof starts with any pc, so this one
            // assumes it, as reset would give.
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
            end
            if (trap && !past_trap) begin
                cover (trap_cause == 4'd0);
                cover (trap_cause == 4'd2);
                cover (trap_cause == 4'd3);
                cover (trap_cause == 4'd4);
                cover (trap_cause == 4'd6);
                cover (trap_cause == 4'd11);
            end
        end
    end

endmodule
