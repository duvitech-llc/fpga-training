// Instruction decoder for the course CPU. No clock and no stored state.
//
// Every instruction has the same four fields in the same places:
//
//   15    12 11  10 9   8 7          0
//   +-------+------+-----+------------+
//   | op    | rd   | rs  | imm        |
//   +-------+------+-----+------------+
//
// The outputs say what the CPU must do for one instruction. The README has the
// full instruction table. These rules are easy to miss:
//
// - reg_we means "write a result to rd". R3 also moves during CALL, RET, PUSH and
//   POP. The CPU does that itself when it sees call, ret, push or pop, so PUSH
//   and CALL have mem_write high and reg_we low.
// - When reg_we is high, rd gets the memory data if mem_read is high, otherwise
//   the ALU result.
// - alu_op is the op input of alu_flags, whose a input is rd. LD and ST do not
//   use the ALU, because their address is rs + imm. Instructions that do not
//   use the ALU leave alu_op and alu_src_imm at 0.
// - Exactly one of the pc_sel_ outputs is high, for every input.
module decode (
    input  wire [15:0] instr,
    input  wire        z,             // flags from the last instruction that set them
    input  wire        c,
    input  wire        n,
    input  wire        v,

    // The fields, as plain wires. Instructions that have no use for one ignore it.
    output wire [1:0]  rd,
    output wire [1:0]  rs,
    output wire [7:0]  imm,

    // The datapath.
    output reg  [3:0]  alu_op,        // op input of alu_flags
    output reg         alu_src_imm,   // ALU input b: 1 for imm, 0 for rs
    output reg         reg_we,        // write a result to reg_waddr
    output wire [1:0]  reg_waddr,
    output reg         flags_we,      // store z, c, n and v from the ALU
    output reg         mem_read,      // LD, POP, RET
    output reg         mem_write,     // ST, PUSH, CALL

    // Which instruction this is, where a CPU has to treat it specially.
    output reg         branch_taken,  // a Bcc whose condition is true
    output reg         jump,          // JMP
    output reg         call,
    output reg         ret,
    output reg         push,
    output reg         pop,
    output reg         jr,
    output reg         halt,
    output reg         illegal,

    // Where the PC goes next.
    output wire        pc_sel_next,   // PC + 1
    output wire        pc_sel_imm,    // imm: JMP, CALL, taken branch
    output wire        pc_sel_rs,     // register rs: JR
    output wire        pc_sel_stack,  // the byte popped from the stack: RET
    output wire        pc_sel_hold    // stay here: HALT, illegal
);

    localparam [3:0] OP_SYSTEM = 4'h0;  // NOP and HALT
    localparam [3:0] OP_ALU    = 4'h1;
    localparam [3:0] OP_LDI    = 4'h2;
    localparam [3:0] OP_ADDI   = 4'h3;
    localparam [3:0] OP_CMPI   = 4'h4;
    localparam [3:0] OP_ANDI   = 4'h5;
    localparam [3:0] OP_LD     = 4'h6;
    localparam [3:0] OP_ST     = 4'h7;
    localparam [3:0] OP_JMP    = 4'h8;
    localparam [3:0] OP_BRANCH = 4'h9;
    localparam [3:0] OP_CALL   = 4'hA;
    localparam [3:0] OP_RET    = 4'hB;
    localparam [3:0] OP_PUSH   = 4'hC;
    localparam [3:0] OP_POP    = 4'hD;
    localparam [3:0] OP_JR     = 4'hE;

    // The alu_flags operations that decode has to name, and the funct codes
    // that mean something other than "this alu_flags operation".
    localparam [3:0] ALU_ADD    = 4'd0;
    localparam [3:0] ALU_SUB    = 4'd2;
    localparam [3:0] ALU_AND    = 4'd4;
    localparam [3:0] ALU_PASS_B = 4'd13;
    localparam [3:0] FUNCT_CMP  = 4'd14;
    localparam [3:0] FUNCT_BAD  = 4'd15;

    wire [3:0] op    = instr[15:12];
    wire [3:0] cond  = instr[11:8];
    wire [3:0] funct = instr[3:0];

    assign rd        = instr[11:10];
    assign rs        = instr[9:8];
    assign imm       = instr[7:0];
    assign reg_waddr = rd;

    assign pc_sel_imm   = jump || call || branch_taken;
    assign pc_sel_rs    = jr;
    assign pc_sel_stack = ret;
    assign pc_sel_hold  = halt || illegal;
    assign pc_sel_next  = !(pc_sel_imm || pc_sel_rs || pc_sel_stack || pc_sel_hold);

    always @(*) begin
        // Default assignments, as in Tutorial 4, so no path makes a latch. Each
        // instruction below only lists what it turns on.
        alu_op       = ALU_ADD;
        alu_src_imm  = 1'b0;
        reg_we       = 1'b0;
        flags_we     = 1'b0;
        mem_read     = 1'b0;
        mem_write    = 1'b0;
        branch_taken = 1'b0;
        jump         = 1'b0;
        call         = 1'b0;
        ret          = 1'b0;
        push         = 1'b0;
        pop          = 1'b0;
        jr           = 1'b0;
        halt         = 1'b0;
        illegal      = 1'b0;

        case (op)
            OP_SYSTEM:
                case (imm)
                    8'd0:    ;  // NOP
                    8'd1:    halt = 1'b1;
                    default: illegal = 1'b1;
                endcase
            OP_ALU:
                case (funct)
                    FUNCT_BAD: illegal = 1'b1;
                    FUNCT_CMP: begin
                        alu_op   = ALU_SUB;
                        flags_we = 1'b1;
                    end
                    default: begin
                        alu_op   = funct;
                        reg_we   = 1'b1;
                        flags_we = 1'b1;
                    end
                endcase
            // LDI goes through the ALU, but it does not change the flags.
            OP_LDI: begin
                alu_op      = ALU_PASS_B;
                alu_src_imm = 1'b1;
                reg_we      = 1'b1;
            end
            OP_ADDI: begin
                alu_op      = ALU_ADD;
                alu_src_imm = 1'b1;
                reg_we      = 1'b1;
                flags_we    = 1'b1;
            end
            OP_CMPI: begin
                alu_op      = ALU_SUB;
                alu_src_imm = 1'b1;
                flags_we    = 1'b1;
            end
            OP_ANDI: begin
                alu_op      = ALU_AND;
                alu_src_imm = 1'b1;
                reg_we      = 1'b1;
                flags_we    = 1'b1;
            end
            OP_LD: begin
                mem_read = 1'b1;
                reg_we   = 1'b1;
            end
            OP_ST:  mem_write = 1'b1;
            OP_JMP: jump = 1'b1;
            OP_BRANCH:
                case (cond)
                    4'd0:    branch_taken = z;        // BEQ
                    4'd1:    branch_taken = !z;       // BNE
                    4'd2:    branch_taken = c;        // BCS
                    4'd3:    branch_taken = !c;       // BCC
                    4'd4:    branch_taken = n;        // BMI
                    4'd5:    branch_taken = !n;       // BPL
                    4'd6:    branch_taken = v;        // BVS
                    4'd7:    branch_taken = !v;       // BVC
                    4'd8:    branch_taken = n != v;   // BLT
                    4'd9:    branch_taken = n == v;   // BGE
                    4'd10:   branch_taken = !c;       // BLO
                    4'd11:   branch_taken = c;        // BHS
                    default: illegal = 1'b1;
                endcase
            OP_CALL: begin
                call      = 1'b1;
                mem_write = 1'b1;
            end
            OP_RET: begin
                ret      = 1'b1;
                mem_read = 1'b1;
            end
            OP_PUSH: begin
                push      = 1'b1;
                mem_write = 1'b1;
            end
            OP_POP: begin
                pop      = 1'b1;
                mem_read = 1'b1;
                reg_we   = 1'b1;
            end
            OP_JR:   jr = 1'b1;
            default: illegal = 1'b1;  // op 15
        endcase
    end

`ifdef FORMAL
    // Safety rules, written out of the spec. They use bit positions, numbers and
    // masks, and none of the names or case branches above. A mask has one bit
    // per op, so bit 6 of F_WRITES_RD is about LD.
    localparam [15:0] F_WRITES_RD = 16'h206E;  // ALU, LDI, ADDI, ANDI, LD, POP
    localparam [15:0] F_SETS_FLAG = 16'h003A;  // ALU, ADDI, CMPI, ANDI
    localparam [15:0] F_READS_MEM = 16'h2840;  // LD, RET, POP
    localparam [15:0] F_WRITE_MEM = 16'h1480;  // ST, CALL, PUSH

    wire f_alu   = instr[15:12] == 4'h1;
    wire f_cmp   = f_alu && instr[3:0] == 4'hE;
    wire f_bcc   = instr[15:12] == 4'h9;

    // The spec's four kinds of illegal word, and nothing else.
    wire f_illegal = (instr[15:12] == 4'h0 && instr[7:1] != 7'd0)
                  || (f_alu && instr[3:0] == 4'hF)
                  || (f_bcc && instr[11:10] == 2'b11)
                  || instr[15:12] == 4'hF;

    // HALT does not depend on rd or rs, which it ignores.
    wire f_halt = instr[15:12] == 4'h0 && instr[7:0] == 8'h01;

    // A truth table for each condition: bit {z, c, n, v} says whether it is true.
    // This is ?: and not case on purpose. Yosys turns a case of constants into a
    // ROM, and the solver may then pick its contents during the induction step.
    wire [15:0] f_truth = (instr[11:8] == 4'd0)  ? 16'hFF00
                        : (instr[11:8] == 4'd1)  ? 16'h00FF
                        : (instr[11:8] == 4'd2)  ? 16'hF0F0
                        : (instr[11:8] == 4'd3)  ? 16'h0F0F
                        : (instr[11:8] == 4'd4)  ? 16'hCCCC
                        : (instr[11:8] == 4'd5)  ? 16'h3333
                        : (instr[11:8] == 4'd6)  ? 16'hAAAA
                        : (instr[11:8] == 4'd7)  ? 16'h5555
                        : (instr[11:8] == 4'd8)  ? 16'h6666
                        : (instr[11:8] == 4'd9)  ? 16'h9999
                        : (instr[11:8] == 4'd10) ? 16'h0F0F
                        : (instr[11:8] == 4'd11) ? 16'hF0F0
                        :                          16'h0000;

    wire f_taken = f_bcc && f_truth[{z, c, n, v}];

    // Added up rather than compared, so two selects at once cannot cancel out.
    wire [2:0] f_pc_count = {2'b00, pc_sel_next} + {2'b00, pc_sel_imm} + {2'b00, pc_sel_rs}
                          + {2'b00, pc_sel_stack} + {2'b00, pc_sel_hold};

    always @(*) begin
        // Illegal exactly when the spec says so.
        assert (illegal == f_illegal);

        // A write goes to one place. R3 moving during PUSH and CALL is not reg_we.
        assert (!(reg_we && mem_write));
        assert (!(mem_read && mem_write));

        // The right register, and for the right instructions.
        if (reg_we)
            assert (reg_waddr == instr[11:10]);
        assert (reg_we == (F_WRITES_RD[instr[15:12]] && !f_cmp && !f_illegal));

        // Which instructions set the flags, and illegal ones never do.
        if (illegal)
            assert (!flags_we);
        assert (flags_we == (F_SETS_FLAG[instr[15:12]] && !f_illegal));

        // HALT and illegal instructions change nothing.
        if (halt || illegal)
            assert (!reg_we && !flags_we && !mem_read && !mem_write);

        assert (mem_read == F_READS_MEM[instr[15:12]]);
        assert (mem_write == F_WRITE_MEM[instr[15:12]]);

        // Exactly one PC source, and the right one.
        assert (f_pc_count == 3'd1);
        assert (pc_sel_hold == (f_halt || f_illegal));
        assert (pc_sel_rs == (instr[15:12] == 4'hE));
        assert (pc_sel_stack == (instr[15:12] == 4'hB));
        assert (pc_sel_imm == (instr[15:12] == 4'h8 || instr[15:12] == 4'hA || f_taken));

        // Branch evaluation.
        assert (branch_taken == f_taken);
    end
`endif

endmodule
