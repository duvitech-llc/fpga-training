// A Wishbone B4 pipelined slave: 2**AW words of read-only memory, for the boot ROM.
//
// This is wb_ram with the write taken out. The contents come from INIT, a file
// for $readmemh with one 32-bit word per line, and nothing on the bus can change
// them. A read gets ack on the next clock with the whole word. A write gets err
// on the next clock, so a store to the ROM is a store access fault, and the
// program finds out at once.
//
// hold makes the ROM slow, as in wb_regfile: while it is high, stall is high and
// no request is taken. Tie it low in a real design.
module wb_rom #(
    parameter AW   = 8,    // 2**AW words: 8 is 1 KiB
    parameter INIT = ""    // a file for $readmemh, or "" for none
) (
    input  wire          clk,
    input  wire          rst,     // synchronous, active high
    input  wire          cyc,
    input  wire          stb,
    input  wire          we,
    input  wire [AW-1:0] adr,     // word address
    output reg           ack,
    output reg           err,     // for every write
    output wire          stall,
    output reg  [31:0]   dat_r,
    input  wire          hold
);

    reg [31:0] mem [0:(1<<AW)-1];

    initial
        if (INIT != "")
            $readmemh(INIT, mem);

    assign stall = hold;

    wire accept = cyc && stb && !stall;

    always @(posedge clk) begin
        if (rst || !cyc) begin
            ack <= 1'b0;
            err <= 1'b0;
        end else begin
            ack <= accept && !we;
            err <= accept && we;
        end

        dat_r <= mem[adr];
    end

`ifdef FORMAL
    reg f_past_valid = 1'b0;
    reg f_past_rst, f_past_cyc, f_past_hold;
    always @(posedge clk) begin
        f_past_valid <= 1'b1;
        f_past_rst   <= rst;
        f_past_cyc   <= cyc;
        f_past_hold  <= hold;
    end

    // hold is never high two clocks in a row, so the ROM is slow but not stuck.
    always @(*)
        if (f_past_valid && f_past_hold)
            assume (!hold);

    wire [3:0] f_outstanding;
    wire [7:0] f_waited;
    wire [7:0] f_stalled;

    wb_checker #(
        .AW(AW), .DUT_IS_SLAVE(1), .LGDEPTH(4),
        .MAX_OUTSTANDING(1), .MAX_WAIT(1), .MAX_STALL(2)
    ) f_bus (
        .clk(clk), .rst(rst),
        .cyc(cyc), .stb(stb), .we(we), .adr(adr), .sel(4'hF), .dat_w(32'd0),
        .ack(ack), .err(err), .stall(stall),
        .outstanding(f_outstanding), .waited(f_waited), .stalled(f_stalled)
    );

    // What the last request was, to check its answer.
    reg          f_was_write = 1'b0;
    reg [AW-1:0] f_adr_q;
    always @(posedge clk) begin
        f_was_write <= accept && we;
        f_adr_q     <= adr;
    end

    always @(*) begin
        if (f_past_valid && !f_past_rst && f_past_cyc) begin
            // Induction: one answer owed exactly while ack or err is high.
            assert (f_outstanding == {3'd0, ack || err});
            // A write is never acknowledged, and a read never refused.
            if (ack || err)
                assert (err == f_was_write);
        end else if (f_past_valid) begin
            assert (!ack && !err);
        end
    end

    // A read returns the word it asked for.
    always @(*)
        if (f_past_valid && ack)
            assert (dat_r == mem[f_adr_q]);

    // These must be reachable, or an assumption has ruled them out.
    always @(*) begin
        if (f_past_valid && !rst) begin
            cover (ack);                          // a read
            cover (err);                          // a write refused
            cover (ack && cyc && stb && !stall);  // back to back
            cover (cyc && stb && stall);          // a request held back
        end
    end
`endif

endmodule
