// A Wishbone B4 pipelined slave with the machine timer of the RISC-V privileged
// specification: a 64-bit mtime that counts clocks, a 64-bit mtimecmp, and an
// interrupt line that is high while mtime >= mtimecmp. It is in the style of the
// CLINT, the timer block of SiFive's cores, but with its own, smaller layout:
//
//   BASE + 0x0  mtime, bits 31:0      read/write
//   BASE + 0x4  mtime, bits 63:32     read/write
//   BASE + 0x8  mtimecmp, bits 31:0   read/write
//   BASE + 0xC  mtimecmp, bits 63:32  read/write
//
// mtime adds 1 on every clock, except on a clock that writes it. A write replaces
// the whole word, whatever sel says: use sw. (A byte store would write its byte
// to all four lanes.) Reset clears mtime and sets mtimecmp to
// all ones, so the line stays low until a program sets a time.
//
// irq comes from a flip-flop: it shows the compare of the clock before. Writing a
// later mtimecmp clears it one clock after the write. The line stays high until
// then: it is level, and only a new mtimecmp, or a new mtime, clears it.
//
// A 32-bit core writes mtimecmp in two halves, and between them the 64-bit value
// is half old and half new, which can raise irq by mistake. The privileged spec
// suggests writing all ones to the low half first. sw/soc.h does that.
//
// adr is two bits: the word within the slave. Each request gets ack on the next
// clock, never err. hold stalls requests, as in wb_regfile. Tie it low in a real
// design.
module wb_timer (
    input  wire        clk,
    input  wire        rst,     // synchronous, active high
    input  wire        cyc,
    input  wire        stb,
    input  wire        we,
    input  wire [1:0]  adr,     // 0 mtime low, 1 mtime high, 2 mtimecmp low, 3 mtimecmp high
    input  wire [3:0]  sel,
    input  wire [31:0] dat_w,
    output reg         ack,
    output wire        err,
    output wire        stall,
    output reg  [31:0] dat_r,
    input  wire        hold,
    output reg         irq      // MTIP: mtime >= mtimecmp, one clock late
);

    reg [63:0] mtime;
    reg [63:0] mtimecmp;

    assign stall = hold;
    assign err   = 1'b0;

    wire accept = cyc && stb && !stall;
    wire write  = accept && we;

    // Writes are whole words, so sel is not used.
    wire unused = &{1'b0, sel};

    always @(posedge clk) begin
        if (rst) begin
            mtime    <= 64'd0;
            mtimecmp <= {64{1'b1}};
            irq      <= 1'b0;
        end else begin
            irq <= mtime >= mtimecmp;

            if (write && adr == 2'd0)
                mtime[31:0] <= dat_w;
            else if (write && adr == 2'd1)
                mtime[63:32] <= dat_w;
            else
                mtime <= mtime + 64'd1;

            if (write && adr == 2'd2)
                mtimecmp[31:0] <= dat_w;
            if (write && adr == 2'd3)
                mtimecmp[63:32] <= dat_w;
        end

        if (rst || !cyc)
            ack <= 1'b0;
        else
            ack <= accept;

        if (accept && !we)
            case (adr)
                2'd0:    dat_r <= mtime[31:0];
                2'd1:    dat_r <= mtime[63:32];
                2'd2:    dat_r <= mtimecmp[31:0];
                default: dat_r <= mtimecmp[63:32];
            endcase
    end

`ifdef FORMAL
    reg f_past_valid = 1'b0;
    reg f_past_rst, f_past_cyc, f_past_hold, f_past_due, f_past_write_time;
    reg [63:0] f_past_mtime;
    always @(posedge clk) begin
        f_past_valid      <= 1'b1;
        f_past_rst        <= rst;
        f_past_cyc        <= cyc;
        f_past_hold       <= hold;
        f_past_due        <= mtime >= mtimecmp;
        f_past_write_time <= write && adr[1] == 1'b0;
        f_past_mtime      <= mtime;
    end

    // ---- The bus: Tutorial 22's checker, with this module as the slave ----
    // hold is never high two clocks in a row, as in Tutorial 22's proof of wb_regfile.
    always @(*) begin
        if (!f_past_valid)
            assume (rst);
        if (f_past_valid && f_past_hold)
            assume (!hold);
    end

    wire [3:0] f_outstanding;
    wire [7:0] f_waited;
    wire [7:0] f_stalled;

    wb_checker #(
        .AW(2), .DUT_IS_SLAVE(1), .LGDEPTH(4),
        .MAX_OUTSTANDING(1), .MAX_WAIT(1), .MAX_STALL(2)
    ) f_bus (
        .clk(clk), .rst(rst),
        .cyc(cyc), .stb(stb), .we(we), .adr(adr), .sel(sel), .dat_w(dat_w),
        .ack(ack), .err(err), .stall(stall),
        .outstanding(f_outstanding), .waited(f_waited), .stalled(f_stalled)
    );

    // ---- The timer, from the privileged spec ----
    always @(*) begin
        if (f_past_valid && !f_past_rst) begin
            // Induction: the checker's count is this slave's ack.
            if (!f_past_cyc)
                assert (!ack);
            else
                assert (f_outstanding == {3'd0, ack});
            // irq is the compare of the clock before: mtime >= mtimecmp.
            assert (irq == f_past_due);
            // mtime counts every clock, unless a write changed it.
            if (!f_past_write_time)
                assert (mtime == f_past_mtime + 64'd1);
        end
        if (f_past_valid && f_past_rst)
            assert (mtime == 64'd0 && mtimecmp == {64{1'b1}} && !irq);
    end

    // These must be reachable: a read of each half, the line rising, and the line
    // falling, which only a write can do.
    reg f_past_irq = 1'b0;
    always @(posedge clk)
        f_past_irq <= irq;
    always @(*) begin
        if (f_past_valid && !rst) begin
            cover (accept && !we && adr == 2'd1);
            cover (accept && !we && adr == 2'd3);
            cover (irq && !f_past_irq);
            cover (!irq && f_past_irq);
        end
    end
`endif

endmodule
