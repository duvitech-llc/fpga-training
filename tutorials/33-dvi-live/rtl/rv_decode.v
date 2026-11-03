// Decoder for RV32I. Combinational: it reads one instruction word and says what
// kind it is, which registers it names, and its immediate.
//
// Every word that is not an RV32I instruction raises illegal. That includes the
// encodings of other extensions (M, A, F and C), so the core can trap on them
// instead of guessing.
//
// Tutorial 27 adds the six CSR instructions of Zicsr and MRET. Whether a CSR
// instruction names a CSR that exists is for rv_csr to say, not this decoder.
//
// The five immediate formats are built here, from the bit positions in the spec:
//
//   I  imm[11:0]                    = instr[31:20]
//   S  imm[11:5]  imm[4:0]          = instr[31:25] instr[11:7]
//   B  imm[12] imm[10:5] imm[4:1] imm[11]
//                                   = instr[31] instr[30:25] instr[11:8] instr[7]
//   U  imm[31:12]                   = instr[31:12]
//   J  imm[20] imm[10:1] imm[11] imm[19:12]
//                                   = instr[31] instr[30:21] instr[20] instr[19:12]
//
// The sign is always instr[31], whatever the format.
module rv_decode (
    input  wire [31:0] instr,
    output wire [4:0]  rd,
    output wire [4:0]  rs1,
    output wire [4:0]  rs2,
    output wire [2:0]  funct3,
    output reg  [31:0] imm,
    output wire        is_lui,
    output wire        is_auipc,
    output wire        is_jal,
    output wire        is_jalr,
    output wire        is_branch,
    output wire        is_load,
    output wire        is_store,
    output wire        is_alu_imm,   // OP-IMM: ADDI, SLTI, ..., SRAI
    output wire        is_alu_reg,   // OP: ADD, SUB, ..., AND
    output wire        is_fence,
    output wire        is_ecall,
    output wire        is_ebreak,
    output wire        is_csr,       // CSRRW, CSRRS, CSRRC, and their immediate forms
    output wire        is_mret,
    output wire        illegal,
    output wire        writes_rd,    // the instruction has a destination register
    output wire [3:0]  alu_op        // {instr[30] where it selects SUB or SRA, funct3}
);

    wire [6:0] opcode = instr[6:0];
    wire [6:0] funct7 = instr[31:25];

    assign rd     = instr[11:7];
    assign rs1    = instr[19:15];
    assign rs2    = instr[24:20];
    assign funct3 = instr[14:12];

    // The major opcodes. The low two bits are 11 for every 32-bit instruction.
    wire op_lui     = opcode == 7'b0110111;
    wire op_auipc   = opcode == 7'b0010111;
    wire op_jal     = opcode == 7'b1101111;
    wire op_jalr    = opcode == 7'b1100111;
    wire op_branch  = opcode == 7'b1100011;
    wire op_load    = opcode == 7'b0000011;
    wire op_store   = opcode == 7'b0100011;
    wire op_imm     = opcode == 7'b0010011;
    wire op_reg     = opcode == 7'b0110011;
    wire op_misc    = opcode == 7'b0001111;
    wire op_system  = opcode == 7'b1110011;

    // Which funct3 and funct7 values exist for each opcode.
    wire f7_zero = funct7 == 7'b0000000;
    wire f7_alt  = funct7 == 7'b0100000;

    assign is_lui     = op_lui;
    assign is_auipc   = op_auipc;
    assign is_jal     = op_jal;
    assign is_jalr    = op_jalr && funct3 == 3'b000;
    assign is_branch  = op_branch && funct3 != 3'b010 && funct3 != 3'b011;
    assign is_load    = op_load && (funct3 == 3'b000 || funct3 == 3'b001 || funct3 == 3'b010
                                    || funct3 == 3'b100 || funct3 == 3'b101);
    assign is_store   = op_store && (funct3 == 3'b000 || funct3 == 3'b001 || funct3 == 3'b010);

    // A shift by an immediate keeps funct7 in imm[11:5]. Only SRAI may set bit 30,
    // and in RV32 the shift amount is 5 bits, so imm[5] (instr[25]) must be 0.
    assign is_alu_imm = op_imm && (funct3 == 3'b001 ? f7_zero :
                                   funct3 == 3'b101 ? (f7_zero || f7_alt) :
                                   1'b1);
    assign is_alu_reg = op_reg && (f7_zero || (f7_alt && (funct3 == 3'b000 || funct3 == 3'b101)));

    // FENCE orders memory accesses. This core makes one access at a time, in program
    // order, so it has nothing to order and FENCE is a NOP. The spec says a base
    // implementation ignores its other fields. FENCE.I (funct3 001) is Zifencei,
    // which is not in the base ISA, so it is illegal here.
    assign is_fence   = op_misc && funct3 == 3'b000;

    // ECALL and EBREAK have one encoding each.
    assign is_ecall   = instr == 32'h00000073;
    assign is_ebreak  = instr == 32'h00100073;

    // The CSR instructions are SYSTEM with funct3 001, 010, 011 (rs1 is a register)
    // and 101, 110, 111 (bits 19:15 are a 5-bit immediate). funct3 100 is reserved.
    assign is_csr     = op_system && funct3 != 3'b000 && funct3 != 3'b100;

    // MRET has one encoding. Every other SYSTEM word with funct3 000, such as WFI,
    // is still illegal.
    assign is_mret    = instr == 32'h30200073;

    wire known = is_lui || is_auipc || is_jal || is_jalr || is_branch || is_load || is_store
              || is_alu_imm || is_alu_reg || is_fence || is_ecall || is_ebreak
              || is_csr || is_mret;
    assign illegal = !known;

    assign writes_rd = is_lui || is_auipc || is_jal || is_jalr || is_load
                    || is_alu_imm || is_alu_reg || is_csr;

    // Bit 30 picks SUB from ADD and SRA from SRL. In OP-IMM, ADDI has no SUBI, so the
    // bit only counts for SRAI. Anything not an ALU instruction gets ADD.
    wire alt = (is_alu_reg || (is_alu_imm && funct3 == 3'b101)) && instr[30];
    assign alu_op = (is_alu_reg || is_alu_imm) ? {alt, funct3} : 4'b0000;

    always @(*) begin
        if (op_lui || op_auipc)                                              // U
            imm = {instr[31:12], 12'b0};
        else if (op_jal)                                                     // J
            imm = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};
        else if (op_branch)                                                  // B
            imm = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
        else if (op_store)                                                   // S
            imm = {{21{instr[31]}}, instr[30:25], instr[11:7]};
        else                                                                 // I
            imm = {{21{instr[31]}}, instr[30:20]};
    end

endmodule
