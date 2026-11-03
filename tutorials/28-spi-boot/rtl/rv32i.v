// A small RV32I core: the base integer instruction set of RISC-V, 32 bits,
// multi-cycle. Written for this course. Its size and its memory interface follow
// PicoRV32 (https://github.com/YosysHQ/picorv32), but no code comes from it.
//
// One memory interface carries both instruction fetches and data:
//
//   mem_valid  the core wants a transfer. It stays high until mem_ready.
//   mem_instr  this transfer is an instruction fetch
//   mem_ready  the memory has done it. The transfer happens on the rising
//              edge where mem_valid and mem_ready are both high. mem_ready may
//              be high on the first clock of mem_valid, or any number later.
//   mem_addr   a byte address, always a multiple of 4
//   mem_wstrb  which bytes to write. 0000 is a read.
//   mem_wdata  the data to write, already moved to its byte lanes
//   mem_rdata  the word read, valid while mem_ready is high
//
// mem_valid, mem_instr, mem_addr, mem_wstrb and mem_wdata come straight from
// flip-flops, and do not change while mem_valid is high and mem_ready is low.
// A new transfer may start on the clock after one finishes, with mem_valid
// still high.
//
// The control is an FSM with four states:
//
//   FETCH    mem_valid is high, with mem_instr and the PC. When mem_ready comes,
//            ir loads mem_rdata.
//   EXECUTE  decode, the register reads, the ALU and the branch compare all work
//            in this clock. Most instructions finish here: rd and pc load on the
//            edge, and the next fetch starts. A load or store starts its data
//            transfer instead. An instruction that must trap goes to TRAP.
//   MEMORY   mem_valid is high for the load or store. When mem_ready comes, a
//            load writes rd, pc moves on, and the next fetch starts.
//   TRAP     The instruction did not finish, and nothing it would have changed
//            has changed. trap is high, and the core waits for reset.
//
// The architectural state, the registers and pc, only changes on the edge at the
// end of a clock where retire is high. Until then x1 to x31 and pc still hold
// what they held before the instruction.
//
// Traps. trap_cause uses the codes of the RISC-V mcause register, so Tutorial 26
// can keep them when it replaces TRAP with a jump to a handler:
//    0  a jump or taken branch to an address that is not a multiple of 4
//    2  an illegal instruction: anything outside RV32I
//    3  EBREAK
//    4  a load from an address that is not a multiple of its size
//    6  a store to an address that is not a multiple of its size
//   11  ECALL
module rv32i #(
    parameter [31:0] RESET_ADDR = 32'h0000_0000   // must be a multiple of 4
) (
    input  wire        clk,
    input  wire        rst,             // synchronous, active high

    output reg         mem_valid,
    output reg         mem_instr,
    input  wire        mem_ready,
    output reg  [31:0] mem_addr,
    output reg  [31:0] mem_wdata,
    output reg  [3:0]  mem_wstrb,
    input  wire [31:0] mem_rdata,

    output wire        trap,            // high from a trap until reset
    output reg  [3:0]  trap_cause,      // why, as an mcause code
    output wire        retire,          // high in the last clock of each instruction
    output wire [31:0] retire_pc,       // its address, while retire is high
    output wire [31:0] retire_instr     // its word, while retire is high
);

    localparam [1:0] S_FETCH   = 2'd0;
    localparam [1:0] S_EXECUTE = 2'd1;
    localparam [1:0] S_MEMORY  = 2'd2;
    localparam [1:0] S_TRAP    = 2'd3;

    localparam [3:0] CAUSE_FETCH_ALIGN = 4'd0;
    localparam [3:0] CAUSE_ILLEGAL     = 4'd2;
    localparam [3:0] CAUSE_EBREAK      = 4'd3;
    localparam [3:0] CAUSE_LOAD_ALIGN  = 4'd4;
    localparam [3:0] CAUSE_STORE_ALIGN = 4'd6;
    localparam [3:0] CAUSE_ECALL       = 4'd11;

    reg  [1:0]  state;
    reg  [31:0] pc;
    reg  [31:0] ir;

    // ----- Decode -----

    wire [4:0]  rd, rs1, rs2;
    wire [2:0]  funct3;
    wire [31:0] imm;
    wire [3:0]  alu_op;
    wire        is_lui, is_auipc, is_jal, is_jalr, is_branch, is_load, is_store;
    wire        is_alu_reg, is_ecall, is_ebreak, illegal, writes_rd;

    // FENCE is a NOP, so it needs nothing but to be legal. An ALU immediate needs
    // nothing that is_alu_reg does not already say.
    wire        unused_fence, unused_alu_imm;

    rv_decode u_decode (
        .instr(ir),
        .rd(rd), .rs1(rs1), .rs2(rs2), .funct3(funct3), .imm(imm),
        .is_lui(is_lui), .is_auipc(is_auipc), .is_jal(is_jal), .is_jalr(is_jalr),
        .is_branch(is_branch), .is_load(is_load), .is_store(is_store),
        .is_alu_imm(unused_alu_imm), .is_alu_reg(is_alu_reg), .is_fence(unused_fence),
        .is_ecall(is_ecall), .is_ebreak(is_ebreak), .illegal(illegal),
        .writes_rd(writes_rd), .alu_op(alu_op)
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
    wire [31:0] next_pc = jumps ? target : pc_plus_4;

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

    assign rd_value = is_load              ? load_value :
                      is_lui               ? imm :
                      is_auipc             ? sum :
                      (is_jal || is_jalr)  ? pc_plus_4 :
                                             alu_y;

    // ----- Traps -----

    wire mem_op     = is_load || is_store;
    wire trap_fetch = jumps && target[1:0] != 2'b00;
    wire trap_data  = mem_op && misaligned_data;
    wire trap_now   = illegal || is_ecall || is_ebreak || trap_fetch || trap_data;

    wire [3:0] cause_now = illegal    ? CAUSE_ILLEGAL :
                           is_ecall   ? CAUSE_ECALL :
                           is_ebreak  ? CAUSE_EBREAK :
                           trap_fetch ? CAUSE_FETCH_ALIGN :
                           is_load    ? CAUSE_LOAD_ALIGN :
                                        CAUSE_STORE_ALIGN;

    // ----- Control -----

    wire in_execute = state == S_EXECUTE;
    wire in_memory  = state == S_MEMORY;

    // A transfer happens only when both are high. mem_ready alone means nothing.
    wire transfer   = mem_valid && mem_ready;

    assign retire = !rst && ((in_execute && !trap_now && !mem_op) || (in_memory && transfer));

    always @(posedge clk) begin
        if (rst) begin
            state      <= S_FETCH;
            pc         <= RESET_ADDR;
            ir         <= 32'd0;
            trap_cause <= 4'd0;
            mem_valid  <= 1'b0;
            mem_instr  <= 1'b0;
            mem_addr   <= 32'd0;
            mem_wdata  <= 32'd0;
            mem_wstrb  <= 4'd0;
        end else begin
            case (state)
                S_FETCH:
                    if (!mem_valid) begin
                        // Only after reset: start the first fetch.
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
                    if (trap_now) begin
                        trap_cause <= cause_now;
                        state      <= S_TRAP;
                    end else if (mem_op) begin
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

                default: ;   // S_TRAP: wait for reset
            endcase
        end
    end

    assign trap         = state == S_TRAP;
    assign retire_pc    = pc;
    assign retire_instr = ir;

endmodule
