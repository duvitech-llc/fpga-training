// The machine-mode CSRs of the RV32I core, written from the RISC-V privileged
// specification. New in Tutorial 27. The core has machine mode only.
//
//   Address  Name        What is kept
//   0x300    mstatus     MIE (bit 3) and MPIE (bit 7). MPP (bits 12:11) reads 11,
//                        machine mode, the only mode there is. Other bits read 0.
//   0x301    misa        read 0x40000100: 32-bit, I. Writes are ignored.
//   0x304    mie         MTIE (bit 7) and MEIE (bit 11). Other bits read 0.
//   0x305    mtvec       bits 31:2, the handler's address. Bits 1:0 read 0: direct
//                        mode only, every trap goes to the same address.
//   0x310    mstatush    reads 0. Writes are ignored.
//   0x340    mscratch    32 bits, for the handler's own use
//   0x341    mepc        bits 31:2. Bits 1:0 read 0, since every instruction is 4 bytes.
//   0x342    mcause      bit 31, interrupt, and bits 3:0, the code. Others read 0.
//   0x343    mtval       32 bits: the bad address or instruction, or 0
//   0x344    mip         MTIP (bit 7) and MEIP (bit 11), the interrupt lines
//                        as they are on this clock. Writes are ignored.
//   0xF11 to 0xF15       mvendorid, marchid, mimpid, mhartid, mconfigptr: read 0
//
// Any other address does not exist, and an instruction that names it is illegal.
// So is a write to the read-only addresses, 0xC00 and up. The counters mcycle and
// minstret are left out: Tutorial 26's counters peripheral does that job.
//
// One write port, used by the CSR instructions on the edge where they retire. A
// trap and mret change mstatus, and a trap writes mepc, mcause and mtval, on
// their own edge. The core never asks for two of these on the same edge.
module rv_csr (
    input  wire        clk,
    input  wire        rst,            // synchronous, active high

    // The CSR instructions
    input  wire [11:0] addr,
    output reg  [31:0] rdata,          // the CSR's value, combinational
    output reg         exists,         // addr names a CSR this core has
    output wire        read_only,      // addr is in the read-only range
    input  wire        we,             // write wdata on this edge
    input  wire [31:0] wdata,

    // Traps and mret
    input  wire        trap_take,      // enter the handler on this edge
    input  wire [31:0] trap_pc,        // to mepc
    input  wire [31:0] trap_cause,     // to mcause
    input  wire [31:0] trap_tval,      // to mtval
    input  wire        mret_take,      // leave the handler on this edge
    output wire [31:0] mtvec,
    output wire [31:0] mepc,

    // Interrupts
    input  wire        irq_timer,      // MTIP: the timer's mtime >= mtimecmp
    input  wire        irq_external,   // MEIP: the UART has a byte waiting
    output wire        irq_pending,    // an enabled interrupt is pending, and MIE is set
    output wire [31:0] irq_cause       // its mcause, if it is taken
);

    localparam [11:0] A_MSTATUS  = 12'h300, A_MISA   = 12'h301, A_MIE    = 12'h304,
                      A_MTVEC    = 12'h305, A_MSTATUSH = 12'h310,
                      A_MSCRATCH = 12'h340, A_MEPC   = 12'h341, A_MCAUSE = 12'h342,
                      A_MTVAL    = 12'h343, A_MIP    = 12'h344,
                      A_MVENDORID = 12'hF11, A_MARCHID = 12'hF12, A_MIMPID = 12'hF13,
                      A_MHARTID  = 12'hF14, A_MCONFIGPTR = 12'hF15;

    reg        mstatus_mie, mstatus_mpie;
    reg        mie_mtie, mie_meie;
    reg [29:0] mtvec_base;
    reg [31:0] mscratch;
    reg [29:0] mepc_word;
    reg        mcause_irq;
    reg [3:0]  mcause_code;
    reg [31:0] mtval;

    wire [31:0] mstatus = {19'd0, 2'b11, 3'd0, mstatus_mpie, 3'd0, mstatus_mie, 3'd0};
    wire [31:0] mie     = {20'd0, mie_meie, 3'd0, mie_mtie, 7'd0};
    wire [31:0] mip     = {20'd0, irq_external, 3'd0, irq_timer, 7'd0};
    wire [31:0] mcause  = {mcause_irq, 27'd0, mcause_code};

    assign mtvec = {mtvec_base, 2'b00};
    assign mepc  = {mepc_word, 2'b00};

    // The privileged spec puts the read-only CSRs at addresses whose top two bits are 11.
    assign read_only = addr[11:10] == 2'b11;

    always @(*) begin
        exists = 1'b1;
        case (addr)
            A_MSTATUS:  rdata = mstatus;
            A_MISA:     rdata = 32'h4000_0100;
            A_MIE:      rdata = mie;
            A_MTVEC:    rdata = mtvec;
            A_MSTATUSH: rdata = 32'd0;
            A_MSCRATCH: rdata = mscratch;
            A_MEPC:     rdata = mepc;
            A_MCAUSE:   rdata = mcause;
            A_MTVAL:    rdata = mtval;
            A_MIP:      rdata = mip;
            A_MVENDORID, A_MARCHID, A_MIMPID, A_MHARTID, A_MCONFIGPTR:
                        rdata = 32'd0;
            default: begin
                rdata  = 32'd0;
                exists = 1'b0;
            end
        endcase
    end

    // External before timer: the privileged spec's order for machine interrupts.
    wire external_on = mie_meie && irq_external;
    wire timer_on    = mie_mtie && irq_timer;
    assign irq_pending = mstatus_mie && (external_on || timer_on);
    assign irq_cause   = external_on ? 32'h8000_000B : 32'h8000_0007;

    always @(posedge clk) begin
        if (rst) begin
            mstatus_mie  <= 1'b0;
            mstatus_mpie <= 1'b0;
            mie_mtie     <= 1'b0;
            mie_meie     <= 1'b0;
            mtvec_base   <= 30'd0;
            mscratch     <= 32'd0;
            mepc_word    <= 30'd0;
            mcause_irq   <= 1'b0;
            mcause_code  <= 4'd0;
            mtval        <= 32'd0;
        end else if (trap_take) begin
            // Interrupts off, and the old setting kept, so mret can restore it.
            mstatus_mpie <= mstatus_mie;
            mstatus_mie  <= 1'b0;
            mepc_word    <= trap_pc[31:2];
            mcause_irq   <= trap_cause[31];
            mcause_code  <= trap_cause[3:0];
            mtval        <= trap_tval;
        end else if (mret_take) begin
            mstatus_mie  <= mstatus_mpie;
            mstatus_mpie <= 1'b1;
        end else if (we) begin
            case (addr)
                A_MSTATUS: begin
                    mstatus_mie  <= wdata[3];
                    mstatus_mpie <= wdata[7];
                end
                A_MIE: begin
                    mie_mtie <= wdata[7];
                    mie_meie <= wdata[11];
                end
                A_MTVEC:    mtvec_base <= wdata[31:2];
                A_MSCRATCH: mscratch   <= wdata;
                A_MEPC:     mepc_word  <= wdata[31:2];
                A_MCAUSE: begin
                    mcause_irq  <= wdata[31];
                    mcause_code <= wdata[3:0];
                end
                A_MTVAL:    mtval      <= wdata;
                default: ;  // read-only, or bits that are all fixed
            endcase
        end
    end

    // trap_pc is always a multiple of 4, and mcause keeps only five bits.
    wire unused = &{1'b0, trap_pc[1:0], trap_cause[30:4]};

endmodule
