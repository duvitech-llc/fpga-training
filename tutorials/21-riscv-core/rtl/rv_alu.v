// The RV32I ALU. Combinational. op is {instr[30], funct3}, the same bits the
// instruction uses, so the decoder does not have to translate them.
//
// There are no flags. RISC-V has none: a compare writes 0 or 1 to a register
// (SLT), and a branch compares two registers itself.
//
// Shifts use only the low 5 bits of b, as the spec says. This is a barrel
// shifter, so every shift takes one clock. PicoRV32 shifts a few bits per clock
// instead, which is smaller and slower.
module rv_alu (
    input  wire [3:0]  op,
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg  [31:0] y
);

    localparam [3:0] ALU_ADD  = 4'b0000;
    localparam [3:0] ALU_SUB  = 4'b1000;
    localparam [3:0] ALU_SLL  = 4'b0001;
    localparam [3:0] ALU_SLT  = 4'b0010;
    localparam [3:0] ALU_SLTU = 4'b0011;
    localparam [3:0] ALU_XOR  = 4'b0100;
    localparam [3:0] ALU_SRL  = 4'b0101;
    localparam [3:0] ALU_SRA  = 4'b1101;
    localparam [3:0] ALU_OR   = 4'b0110;
    localparam [3:0] ALU_AND  = 4'b0111;

    wire [4:0] shamt = b[4:0];

    always @(*) begin
        case (op)
            ALU_ADD:  y = a + b;
            ALU_SUB:  y = a - b;
            ALU_SLL:  y = a << shamt;
            ALU_SLT:  y = {31'b0, $signed(a) < $signed(b)};
            ALU_SLTU: y = {31'b0, a < b};
            ALU_XOR:  y = a ^ b;
            ALU_SRL:  y = a >> shamt;
            ALU_SRA:  y = $signed(a) >>> shamt;
            ALU_OR:   y = a | b;
            ALU_AND:  y = a & b;
            default:  y = a + b;   // the decoder never sends the other six codes
        endcase
    end

endmodule
