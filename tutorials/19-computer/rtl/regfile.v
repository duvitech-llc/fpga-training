// Register file: REGS registers of WIDTH bits, built from enreg, with one
// synchronous write port and two combinational read ports. REGS must be at
// least 2.
//
// A read of the register being written returns the old value until the rising
// edge, and the new value after it. rst clears every register on the edge, and
// reads are not affected by rst until then.
//
// If REGS is not a power of two, some addresses have no register. A write to one
// of them changes nothing, and a read of one returns 0.
module regfile #(
    parameter WIDTH = 8,
    parameter REGS  = 4
) (
    input  wire                    clk,
    input  wire                    rst,      // synchronous, active high, overrides we
    input  wire                    we,       // write wdata to register waddr
    input  wire [$clog2(REGS)-1:0] waddr,
    input  wire [WIDTH-1:0]        wdata,
    input  wire [$clog2(REGS)-1:0] raddr_a,
    output wire [WIDTH-1:0]        rdata_a,
    input  wire [$clog2(REGS)-1:0] raddr_b,
    output wire [WIDTH-1:0]        rdata_b
);

    localparam integer ADDR_BITS = $clog2(REGS);

    wire [WIDTH-1:0] q [0:REGS-1];

    genvar i;
    generate
        // One copy of this block per register. Each gets its own wen, the
        // output of the write decoder for that register.
        for (i = 0; i < REGS; i = i + 1) begin : gen_regs
            localparam integer INDEX = i;

            wire wen = we && (waddr == INDEX[ADDR_BITS-1:0]);

            enreg #(.WIDTH(WIDTH)) u_reg (
                .clk(clk),
                .rst(rst),
                .en(wen),
                .d(wdata),
                .q(q[i])
            );
        end

        // Only a REGS that is not a power of two has addresses to check.
        if (REGS == (1 << ADDR_BITS)) begin : gen_read_all
            assign rdata_a = q[raddr_a];
            assign rdata_b = q[raddr_b];
        end else begin : gen_read_checked
            localparam integer LAST = REGS - 1;

            assign rdata_a = (raddr_a <= LAST[ADDR_BITS-1:0]) ? q[raddr_a] : {WIDTH{1'b0}};
            assign rdata_b = (raddr_b <= LAST[ADDR_BITS-1:0]) ? q[raddr_b] : {WIDTH{1'b0}};
        end
    endgenerate

`ifdef FORMAL
    // The solver chooses one register, and the proof follows it. It may choose
    // any of them, so the proof covers them all.
    (* anyconst *) reg [ADDR_BITS-1:0] watch_addr;

    // With a REGS that is not a power of two, some addresses have no register.
    always @(*)
        assume (watch_addr < REGS);

    // A copy of the watched register. known goes high at the first reset, since
    // before that the register holds an unknown value.
    reg [WIDTH-1:0] shadow = {WIDTH{1'b0}};
    reg             known  = 1'b0;
    always @(posedge clk) begin
        if (rst) begin
            shadow <= {WIDTH{1'b0}};
            known  <= 1'b1;
        end else if (we && waddr == watch_addr) begin
            shadow <= wdata;
        end
    end

    always @(*) begin
        // The invariant. Without it k-induction may start from a state where
        // shadow and the register disagree.
        if (known)
            assert (q[watch_addr] == shadow);

        // shadow changes on the clock edge, so these also say that a read of
        // the register being written returns the old value.
        if (known && raddr_a == watch_addr)
            assert (rdata_a == shadow);
        if (known && raddr_b == watch_addr)
            assert (rdata_b == shadow);

        if (raddr_a >= REGS)
            assert (rdata_a == {WIDTH{1'b0}});
        if (raddr_b >= REGS)
            assert (rdata_b == {WIDTH{1'b0}});
    end

    // Cover asks whether the behaviour above can happen at all.
    always @(*) begin
        if (known) begin
            cover (!rst && we && waddr == watch_addr && wdata != shadow);
            cover (!rst && we && waddr == raddr_a && rdata_a != wdata);
            cover (!rst && we && waddr == raddr_b && rdata_b != wdata);
            cover (rdata_a != {WIDTH{1'b0}} && rdata_b != {WIDTH{1'b0}} && rdata_a != rdata_b);
            cover (rst && shadow != {WIDTH{1'b0}});
        end
    end

    // At REGS=4 these could never be reached, and the cover task would fail.
    generate
        if (REGS != (1 << ADDR_BITS)) begin : gen_cover_checked
            always @(*) begin
                if (known) begin
                    cover (!rst && we && waddr >= REGS);
                    cover (raddr_a >= REGS);
                    cover (raddr_b >= REGS);
                end
            end
        end
    endgenerate
`endif

endmodule
