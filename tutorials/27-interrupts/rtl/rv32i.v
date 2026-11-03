// A small RV32I core: the base integer instruction set of RISC-V, 32 bits,
// multi-cycle. Written for this course. Its size and its memory interface follow
// PicoRV32 (https://github.com/YosysHQ/picorv32), but no code comes from it.
//
// Tutorial 27 adds machine mode from the RISC-V privileged specification: the
// CSRs in rv_csr.v, the Zicsr instructions, MRET, real traps that jump to mtvec,
// bus access faults through mem_err, and two interrupts. Everything else is
// Tutorial 21's core.
//
// One memory interface carries both instruction fetches and data:
//
//   mem_valid  the core wants a transfer. It stays high until mem_ready or mem_err.
//   mem_instr  this transfer is an instruction fetch
//   mem_ready  the memory has done it. The transfer happens on the rising
//              edge where mem_valid and mem_ready are both high. mem_ready may
//              be high on the first clock of mem_valid, or any number later.
//   mem_err    the memory could not do it: an access fault. Like mem_ready, it
//              ends the transfer, and never comes with it. After mem_err the core
//              drops mem_valid for at least one clock.
//   mem_addr   a byte address, always a multiple of 4
//   mem_wstrb  which bytes to write. 0000 is a read.
//   mem_wdata  the data to write, already moved to its byte lanes
//   mem_rdata  the word read, valid while mem_ready is high
//
// mem_valid, mem_instr, mem_addr, mem_wstrb and mem_wdata come straight from
// flip-flops, and do not change while mem_valid is high and the transfer has not
// ended. A new transfer may start on the clock after one finishes, with mem_valid
// still high.
//
// The control is an FSM with three states:
//
//   FETCH    mem_valid is high, with mem_instr and the PC. When mem_ready comes,
//            ir loads mem_rdata. If mem_valid is low, as after reset or a trap,
//            the fetch starts on this clock's edge.
//   EXECUTE  decode, the register and CSR reads, the ALU and the branch compare all
//            work in this clock. An interrupt is taken here, instead of the
//            instruction. Otherwise most instructions finish here: rd and pc load
//            on the edge, and the next fetch starts. A load or store starts its
//            data transfer instead. An instruction that must trap takes its trap.
//   MEMORY   mem_valid is high for the load or store. When mem_ready comes, a
//            load writes rd, pc moves on, and the next fetch starts.
//
// Tutorial 21 had a fourth state, TRAP, where the core stopped until reset. Now a
// trap takes one edge: mepc gets the address of the instruction that did not
// finish, mcause the reason, mtval the bad address or instruction, MIE is cleared
// with its old value kept in MPIE, pc becomes mtvec, and the core goes to FETCH
// with mem_valid low. trap is high in that clock, and trap_cause holds mcause.
//
// The architectural state, the registers, pc and the CSRs, only changes on the
// edge at the end of a clock where retire or trap is high.
//
// Interrupts. One is taken in the EXECUTE clock of an instruction, if in that
// clock mstatus.MIE is 1 and an interrupt is both pending in mip and enabled in
// mie. The instruction does not run, and mepc gets its address, so mret runs it.
//
// Exceptions, with their mcause codes:
//    0  a jump or taken branch to an address that is not a multiple of 4
//    1  instruction access fault: mem_err on a fetch
//    2  an illegal instruction, including a CSR that does not exist, or a write
//       to a read-only one
//    3  EBREAK
//    4  a load from an address that is not a multiple of its size
//    5  load access fault: mem_err on a load
//    6  a store to an address that is not a multiple of its size
//    7  store access fault: mem_err on a store
//   11  ECALL
// Interrupts set bit 31 of mcause: 0x80000007 the timer, 0x8000000B external.
module rv32i #(
    parameter [31:0] RESET_ADDR = 32'h0000_0000   // must be a multiple of 4
) (
    input  wire        clk,
    input  wire        rst,             // synchronous, active high

    output reg         mem_valid,
    output reg         mem_instr,
    input  wire        mem_ready,
    input  wire        mem_err,
    output reg  [31:0] mem_addr,
    output reg  [31:0] mem_wdata,
    output reg  [3:0]  mem_wstrb,
    input  wire [31:0] mem_rdata,

    input  wire        irq_timer,       // MTIP, level: high while the timer is due
    input  wire        irq_external,    // MEIP, level: high while a device wants service

    output wire        trap,            // high in the clock a trap or interrupt is taken
    output wire [31:0] trap_cause,      // its mcause, while trap is high
    output wire        retire,          // high in the last clock of each instruction
    output wire [31:0] retire_pc,       // its address, while retire or trap is high
    output wire [31:0] retire_instr     // its word, while retire is high
);

    localparam [1:0] S_FETCH   = 2'd0;
    localparam [1:0] S_EXECUTE = 2'd1;
    localparam [1:0] S_MEMORY  = 2'd2;

    localparam [31:0] CAUSE_FETCH_ALIGN = 32'd0;
    localparam [31:0] CAUSE_FETCH_FAULT = 32'd1;
    localparam [31:0] CAUSE_ILLEGAL     = 32'd2;
    localparam [31:0] CAUSE_EBREAK      = 32'd3;
    localparam [31:0] CAUSE_LOAD_ALIGN  = 32'd4;
    localparam [31:0] CAUSE_LOAD_FAULT  = 32'd5;
    localparam [31:0] CAUSE_STORE_ALIGN = 32'd6;
    localparam [31:0] CAUSE_STORE_FAULT = 32'd7;
    localparam [31:0] CAUSE_ECALL       = 32'd11;

    reg  [1:0]  state;
    reg  [31:0] pc;
    reg  [31:0] ir;

    // ----- Decode -----

    wire [4:0]  rd, rs1, rs2;
    wire [2:0]  funct3;
    wire [31:0] imm;
    wire [3:0]  alu_op;
    wire        is_lui, is_auipc, is_jal, is_jalr, is_branch, is_load, is_store;
    wire        is_alu_reg, is_ecall, is_ebreak, is_csr, is_mret, illegal_op, writes_rd;

    // FENCE is a NOP, so it needs nothing but to be legal. An ALU immediate needs
    // nothing that is_alu_reg does not already say.
    wire        unused_fence, unused_alu_imm;

    rv_decode u_decode (
        .instr(ir),
        .rd(rd), .rs1(rs1), .rs2(rs2), .funct3(funct3), .imm(imm),
        .is_lui(is_lui), .is_auipc(is_auipc), .is_jal(is_jal), .is_jalr(is_jalr),
        .is_branch(is_branch), .is_load(is_load), .is_store(is_store),
        .is_alu_imm(unused_alu_imm), .is_alu_reg(is_alu_reg), .is_fence(unused_fence),
        .is_ecall(is_ecall), .is_ebreak(is_ebreak), .is_csr(is_csr), .is_mret(is_mret),
        .illegal(illegal_op), .writes_rd(writes_rd), .alu_op(alu_op)
    );

    // ----- Registers and ALU -----

    wire [31:0] rs1_value, rs2_value, alu_y;
    wire [31:0] rd_value;

    rv_regs u_regs (
        .clk(clk),
        .rst(rst),
        .we(retire && writes_rd),
        .waddr(rd),
        .wdata(rd_value),
        .raddr_a(rs1),
        .rdata_a(rs1_value),
        .raddr_b(rs2),
        .rdata_b(rs2_value)
    );

    rv_alu u_alu (
        .op(alu_op),
        .a(rs1_value),
        .b(is_alu_reg ? rs2_value : imm),
        .y(alu_y)
    );

    // ----- Addresses -----

    // One adder makes every address: pc + imm for AUIPC, JAL and branches, and
    // rs1 + imm for JALR, loads and stores.
    wire        from_rs1 = is_jalr || is_load || is_store;
    wire [31:0] sum      = (from_rs1 ? rs1_value : pc) + imm;
    wire [31:0] pc_plus_4 = pc + 32'd4;

    // Branches. funct3[2:1] picks the compare and funct3[0] inverts it.
    wire equal     = rs1_value == rs2_value;
    wire less      = $signed(rs1_value) < $signed(rs2_value);
    wire less_u    = rs1_value < rs2_value;
    wire compare   = !funct3[2] ? equal : !funct3[1] ? less : less_u;
    wire taken     = is_branch && (compare != funct3[0]);

    wire        jumps  = is_jal || is_jalr || taken;
    wire [31:0] target = is_jalr ? {sum[31:1], 1'b0} : sum;    // JALR clears bit 0

    // ----- Loads and stores -----

    // funct3[1:0] is the size: 00 byte, 01 halfword, 10 word. funct3[2] means unsigned.
    wire [1:0]  offset   = sum[1:0];
    wire        is_byte  = funct3[1:0] == 2'b00;
    wire        is_half  = funct3[1:0] == 2'b01;
    wire        misaligned_data = (is_half && offset[0]) || (!is_byte && !is_half && offset != 2'b00);

    // A store copies its byte or halfword to every lane it could use, and wstrb
    // says which lane the memory should take.
    wire [31:0] store_data = is_byte ? {4{rs2_value[7:0]}} :
                             is_half ? {2{rs2_value[15:0]}} :
                                       rs2_value;
    wire [3:0]  store_strb = is_byte ? (4'b0001 << offset) :
                             is_half ? (4'b0011 << offset) :
                                       4'b1111;

    // A load always reads the whole word, then picks its lanes out of it.
    wire [15:0] lanes      = (offset == 2'd0) ? mem_rdata[15:0] :
                             (offset == 2'd1) ? mem_rdata[23:8] :
                             (offset == 2'd2) ? mem_rdata[31:16] :
                                                {8'd0, mem_rdata[31:24]};
    wire        sign_bit   = !funct3[2] && (is_byte ? lanes[7] : lanes[15]);
    wire [31:0] load_value = is_byte ? {{24{sign_bit}}, lanes[7:0]} :
                             is_half ? {{16{sign_bit}}, lanes[15:0]} :
                                       mem_rdata;

    // ----- CSRs -----

    // CSRRW and CSRRWI always write. The set and clear forms write only if rs1, or
    // the immediate in its place, is not 0, so csrr can read a read-only CSR.
    wire [31:0] csr_rdata, mtvec, mepc, irq_cause;
    wire        csr_exists, csr_read_only, irq_pending;
    wire [31:0] csr_source = funct3[2] ? {27'd0, rs1} : rs1_value;
    wire        csr_writes = funct3[1:0] == 2'b01 || rs1 != 5'd0;
    wire [31:0] csr_wdata  = funct3[1:0] == 2'b01 ? csr_source :
                             funct3[1:0] == 2'b10 ? csr_rdata | csr_source :
                                                    csr_rdata & ~csr_source;
    wire        csr_bad    = is_csr && (!csr_exists || (csr_writes && csr_read_only));

    assign rd_value = is_load              ? load_value :
                      is_lui               ? imm :
                      is_auipc             ? sum :
                      (is_jal || is_jalr)  ? pc_plus_4 :
                      is_csr               ? csr_rdata :
                                             alu_y;

    wire [31:0] next_pc = is_mret ? mepc : jumps ? target : pc_plus_4;

    // ----- Traps -----

    wire in_fetch   = state == S_FETCH;
    wire in_execute = state == S_EXECUTE;
    wire in_memory  = state == S_MEMORY;

    // A transfer happens only when both are high. mem_ready alone means nothing.
    wire transfer   = mem_valid && mem_ready;
    wire fault      = mem_valid && mem_err;

    wire mem_op     = is_load || is_store;
    wire illegal    = illegal_op || csr_bad;
    wire trap_fetch = jumps && target[1:0] != 2'b00;
    wire trap_data  = mem_op && misaligned_data;
    wire exception  = illegal || is_ecall || is_ebreak || trap_fetch || trap_data;

    wire [31:0] cause_now = illegal    ? CAUSE_ILLEGAL :
                            is_ecall   ? CAUSE_ECALL :
                            is_ebreak  ? CAUSE_EBREAK :
                            trap_fetch ? CAUSE_FETCH_ALIGN :
                            is_load    ? CAUSE_LOAD_ALIGN :
                                         CAUSE_STORE_ALIGN;
    // mtval: the instruction for an illegal one, the address for EBREAK, the bad
    // address for a misaligned jump, load or store, and 0 for ECALL.
    wire [31:0] tval_now  = illegal    ? ir :
                            is_ecall   ? 32'd0 :
                            is_ebreak  ? pc :
                            trap_fetch ? target :
                                         sum;

    // In EXECUTE an interrupt comes first: the instruction has not started.
    wire take_irq   = in_execute && irq_pending;
    wire take_exc   = in_execute && !irq_pending && exception;
    wire take_fault = (in_fetch || in_memory) && fault;
    assign trap = !rst && (take_irq || take_exc || take_fault);

    assign trap_cause = take_irq   ? irq_cause :
                        take_exc   ? cause_now :
                        in_fetch   ? CAUSE_FETCH_FAULT :
                        is_store   ? CAUSE_STORE_FAULT :
                                     CAUSE_LOAD_FAULT;
    // For a fault the bad address: pc for a fetch, and the load or store's own address.
    wire [31:0] trap_tval = take_irq ? 32'd0 :
                            take_exc ? tval_now :
                            in_fetch ? pc :
                                       sum;

    // ----- Control -----

    assign retire = !rst && ((in_execute && !irq_pending && !exception && !mem_op)
                             || (in_memory && transfer));

    rv_csr u_csr (
        .clk(clk), .rst(rst),
        .addr(ir[31:20]), .rdata(csr_rdata), .exists(csr_exists), .read_only(csr_read_only),
        .we(retire && is_csr && csr_writes), .wdata(csr_wdata),
        .trap_take(trap), .trap_pc(pc), .trap_cause(trap_cause), .trap_tval(trap_tval),
        .mret_take(retire && is_mret), .mtvec(mtvec), .mepc(mepc),
        .irq_timer(irq_timer), .irq_external(irq_external),
        .irq_pending(irq_pending), .irq_cause(irq_cause)
    );

    always @(posedge clk) begin
        if (rst) begin
            state      <= S_FETCH;
            pc         <= RESET_ADDR;
            ir         <= 32'd0;
            mem_valid  <= 1'b0;
            mem_instr  <= 1'b0;
            mem_addr   <= 32'd0;
            mem_wdata  <= 32'd0;
            mem_wstrb  <= 4'd0;
        end else if (trap) begin
            // To the handler. The fetch from mtvec starts on the next clock, so
            // mem_valid is low for one clock, as the bus bridge needs after mem_err.
            pc        <= mtvec;
            mem_valid <= 1'b0;
            state     <= S_FETCH;
        end else begin
            case (state)
                S_FETCH:
                    if (!mem_valid) begin
                        // After reset or a trap: start the fetch.
                        mem_valid <= 1'b1;
                        mem_instr <= 1'b1;
                        mem_addr  <= pc;
                        mem_wstrb <= 4'd0;
                    end else if (transfer) begin
                        mem_valid <= 1'b0;
                        ir        <= mem_rdata;
                        state     <= S_EXECUTE;
                    end

                S_EXECUTE:
                    if (mem_op) begin
                        mem_valid <= 1'b1;
                        mem_instr <= 1'b0;
                        mem_addr  <= {sum[31:2], 2'b00};
                        mem_wdata <= store_data;
                        mem_wstrb <= is_store ? store_strb : 4'd0;
                        state     <= S_MEMORY;
                    end else begin
                        // Retire, and fetch the next instruction straight away.
                        pc        <= next_pc;
                        mem_valid <= 1'b1;
                        mem_instr <= 1'b1;
                        mem_addr  <= next_pc;
                        mem_wstrb <= 4'd0;
                        state     <= S_FETCH;
                    end

                S_MEMORY:
                    if (transfer) begin
                        pc        <= pc_plus_4;
                        mem_valid <= 1'b1;
                        mem_instr <= 1'b1;
                        mem_addr  <= pc_plus_4;
                        mem_wstrb <= 4'd0;
                        state     <= S_FETCH;
                    end

                default:    // not used: there is no fourth state any more
                    state <= S_FETCH;
            endcase
        end
    end

    assign retire_pc    = pc;
    assign retire_instr = ir;

endmodule
