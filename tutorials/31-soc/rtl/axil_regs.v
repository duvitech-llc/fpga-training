// An AXI4-Lite register slave: four read/write registers and a read-only ID.
//
//   BASE + 0x00  reg0  read/write, reset to 0
//   BASE + 0x04  reg1  read/write, reset to 0
//   BASE + 0x08  reg2  read/write, reset to 0
//   BASE + 0x0C  reg3  read/write, reset to 0
//   BASE + 0x10  ID    read-only, reads 0x4158494C ("AXIL" in ASCII)
//
// Addresses are byte addresses, and bits [1:0] are ignored, so 0x05 is reg1. A
// write changes only the bytes whose wstrb bit is high. A read returns the whole
// word. Responses:
//
//   OKAY    the access was done
//   SLVERR  a write to ID: the register exists but refuses the write
//   DECERR  any other address: nothing is there. Read data is 0
//
// Every channel is a valid/ready handshake as in Tutorial 9. A write needs one
// AW and one W. BUFFERED picks how this slave takes them:
//
//   BUFFERED = 0  wait for both awvalid and wvalid, then take both in the same
//                 clock. awready and wready depend on the valids.
//   BUFFERED = 1  take each one as soon as it arrives, into a register of its
//                 own, and do the write once both are there. awready and wready
//                 come from flip-flops.
//
// At most one write and one read are in progress. Reads and writes are
// independent, so one of each can be in progress at the same time.
module axil_regs #(
    parameter [31:0] BASE     = 32'h0000_0000,  // a multiple of 32
    parameter        BUFFERED = 1
) (
    input  wire        clk,
    input  wire        rst,      // synchronous, active high
    // Write address channel
    input  wire        awvalid,
    output wire        awready,
    input  wire [31:0] awaddr,
    input  wire [2:0]  awprot,   // ignored
    // Write data channel
    input  wire        wvalid,
    output wire        wready,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,    // bit k enables wdata[8k+7:8k]
    // Write response channel
    output reg         bvalid,
    input  wire        bready,
    output reg  [1:0]  bresp,
    // Read address channel
    input  wire        arvalid,
    output wire        arready,
    input  wire [31:0] araddr,
    input  wire [2:0]  arprot,   // ignored
    // Read data channel
    output reg         rvalid,
    input  wire        rready,
    output reg  [31:0] rdata,
    output reg  [1:0]  rresp,
    // For testing only: hold[0], hold[1] and hold[2] keep awready, wready and
    // arready low on this clock. Tie it to 0 in a real design.
    input  wire [2:0]  hold
);

    localparam [1:0]  OKAY   = 2'b00;
    localparam [1:0]  SLVERR = 2'b10;
    localparam [1:0]  DECERR = 2'b11;
    localparam [31:0] ID     = 32'h4158_494C;

    reg [31:0] regs [0:3];

    // The write that happens at this edge, if wr_go is high.
    wire        wr_go;
    wire [31:2] wr_addr;
    wire [31:0] wr_data;
    wire [3:0]  wr_strb;

    generate
        if (BUFFERED) begin : g_buffered
            reg        aw_full;  // aw_addr holds an address that has no write yet
            reg        w_full;   // w_data and w_strb hold data that has no write yet
            reg [31:2] aw_addr;
            reg [31:0] w_data;
            reg [3:0]  w_strb;

            assign awready = !aw_full && !hold[0];
            assign wready  = !w_full && !hold[1];

            always @(posedge clk) begin
                if (rst) begin
                    aw_full <= 1'b0;
                    w_full  <= 1'b0;
                end else if (wr_go) begin
                    // Both readys are low, so nothing new arrives at this edge.
                    aw_full <= 1'b0;
                    w_full  <= 1'b0;
                end else begin
                    if (awvalid && awready) begin
                        aw_full <= 1'b1;
                        aw_addr <= awaddr[31:2];
                    end
                    if (wvalid && wready) begin
                        w_full <= 1'b1;
                        w_data <= wdata;
                        w_strb <= wstrb;
                    end
                end
            end

            // Both halves are here, and the response register is free.
            assign wr_go   = aw_full && w_full && !bvalid;
            assign wr_addr = aw_addr;
            assign wr_data = w_data;
            assign wr_strb = w_strb;
        end else begin : g_waiting
            // Take nothing until both halves are on offer and the response
            // register is free. Then take both, and do the write, at this edge.
            assign wr_go   = awvalid && wvalid && !bvalid && !hold[0] && !hold[1];
            assign awready = wr_go;
            assign wready  = wr_go;
            assign wr_addr = awaddr[31:2];
            assign wr_data = wdata;
            assign wr_strb = wstrb;
        end
    endgenerate

    // Address decode. A word address in this slave's 32 bytes, at 0 to 4.
    wire wr_here = wr_addr[31:5] == BASE[31:5] && wr_addr[4:2] <= 3'd4;
    wire rd_here = araddr[31:5] == BASE[31:5] && araddr[4:2] <= 3'd4;

    integer k;

    // The write, and its response.
    always @(posedge clk) begin
        if (rst) begin
            for (k = 0; k < 4; k = k + 1)
                regs[k] <= 32'd0;
            bvalid <= 1'b0;
        end else if (wr_go) begin
            if (!wr_here) begin
                bresp <= DECERR;
            end else if (wr_addr[4]) begin
                bresp <= SLVERR;  // ID is read-only
            end else begin
                bresp <= OKAY;
                for (k = 0; k < 4; k = k + 1)
                    if (wr_strb[k])
                        regs[wr_addr[3:2]][8*k +: 8] <= wr_data[8*k +: 8];
            end
            bvalid <= 1'b1;
        end else if (bready) begin
            bvalid <= 1'b0;
        end
    end

    // The read. A new address is taken only while the read data register is free.
    assign arready = !rvalid && !hold[2];

    always @(posedge clk) begin
        if (rst) begin
            rvalid <= 1'b0;
        end else if (arvalid && arready) begin
            if (!rd_here) begin
                rresp <= DECERR;
                rdata <= 32'd0;
            end else if (araddr[4]) begin
                rresp <= OKAY;
                rdata <= ID;
            end else begin
                rresp <= OKAY;
                rdata <= regs[araddr[3:2]];
            end
            rvalid <= 1'b1;
        end else if (rready) begin
            rvalid <= 1'b0;
        end
    end

    // Inputs that this slave does not need. The name keeps the linter quiet.
    wire unused = &{1'b0, awprot, arprot, awaddr[1:0], araddr[1:0]};

`ifdef FORMAL
    // ---- The bus rules, from the slave's side ----
    // The master's rules are assumed and this slave's rules are asserted. See
    // formal/axil_checker.v. The counts are handshakes not yet answered.
    wire [3:0] f_aw_out;
    wire [3:0] f_w_out;
    wire [3:0] f_ar_out;

    axil_checker #(
        .DUT_IS_SLAVE(1), .MAX_OUTSTANDING(BUFFERED ? 2 : 1)
    ) f_axi (
        .clk(clk), .rst(rst),
        .awvalid(awvalid), .awready(awready), .awaddr(awaddr), .awprot(awprot),
        .wvalid(wvalid), .wready(wready), .wdata(wdata), .wstrb(wstrb),
        .bvalid(bvalid), .bready(bready), .bresp(bresp),
        .arvalid(arvalid), .arready(arready), .araddr(araddr), .arprot(arprot),
        .rvalid(rvalid), .rready(rready), .rdata(rdata), .rresp(rresp),
        .aw_out(f_aw_out), .w_out(f_w_out), .ar_out(f_ar_out)
    );

    reg f_past_valid = 1'b0;
    always @(posedge clk)
        f_past_valid <= 1'b1;

    wire f_aw_hs = !rst && awvalid && awready;
    wire f_w_hs  = !rst && wvalid && wready;
    wire f_b_hs  = !rst && bvalid && bready;
    wire f_ar_hs = !rst && arvalid && arready;
    wire f_r_hs  = !rst && rvalid && rready;

    // ---- Induction: tie the checker's counts to this slave's state ----
    // Without these the solver may start from a state where they disagree.
    always @(*) begin
        if (f_past_valid) begin
            assert (f_ar_out == {3'd0, rvalid});
            if (!BUFFERED) begin
                assert (f_aw_out == {3'd0, bvalid});
                assert (f_w_out  == {3'd0, bvalid});
            end
        end
    end

    generate
        if (BUFFERED) begin : g_formal_buffered
            always @(*)
                if (f_past_valid) begin
                    assert (f_aw_out == {3'd0, g_buffered.aw_full} + {3'd0, bvalid});
                    assert (f_w_out  == {3'd0, g_buffered.w_full}  + {3'd0, bvalid});
                end
        end
    endgenerate

    // ---- Covers: these must be reachable, or an assumption ruled them out ----
    reg f_past_r_hs   = 1'b0, f_past2_r_hs = 1'b0;
    reg f_past_b_hs   = 1'b0, f_past2_b_hs = 1'b0;
    reg f_past_bvalid = 1'b0, f_past_bready = 1'b0;
    reg f_w_early     = 1'b0;  // wvalid was high without awvalid, for this write
    reg f_aw_early    = 1'b0;  // awvalid was high without wvalid, for this write
    always @(posedge clk) begin
        f_past_r_hs   <= f_r_hs;
        f_past2_r_hs  <= f_past_r_hs;
        f_past_b_hs   <= f_b_hs;
        f_past2_b_hs  <= f_past_b_hs;
        f_past_bvalid <= bvalid;
        f_past_bready <= bready;
        if (rst || f_aw_hs) begin
            f_w_early  <= 1'b0;
            f_aw_early <= 1'b0;
        end else begin
            if (wvalid && !awvalid)
                f_w_early <= 1'b1;
            if (awvalid && !wvalid)
                f_aw_early <= 1'b1;
        end
    end

    always @(*) begin
        if (f_past_valid && !rst) begin
            if (BUFFERED) begin
                // The order of the two handshakes of a write.
                cover (f_aw_hs && !f_w_hs && f_w_out > f_aw_out);  // W taken before AW
                cover (f_w_hs && !f_aw_hs && f_aw_out > f_w_out);  // AW taken before W
                cover (f_aw_hs && f_w_hs && f_aw_out == f_w_out);  // both at one edge
            end else begin
                // This slave takes both at one edge, so the order is in the valids.
                cover (f_aw_hs && f_w_early);                 // W offered first
                cover (f_aw_hs && f_aw_early);                // AW offered first
                cover (f_aw_hs && !f_w_early && !f_aw_early); // both on one clock
            end
            cover (f_ar_hs && f_past_r_hs);   // a read taken as the last one ends
            cover (f_r_hs && f_past2_r_hs);   // reads answered 2 clocks apart
            cover (f_b_hs && f_past2_b_hs);   // writes answered 2 clocks apart
            cover (f_aw_hs && f_ar_hs);       // a write and a read at one edge
            cover (bvalid && f_past_bvalid && !f_past_bready);  // a held response
            cover (bvalid && bresp == SLVERR);
            cover (bvalid && bresp == DECERR);
            cover (rvalid && rresp == DECERR);
        end
    end

`ifdef CHECK_DATA
    // ---- The data, seen from the ports ----
    // Pick any one register and keep a copy of what it should hold. A write
    // counts once both its halves have been taken, with the address from its AW
    // and the data from its W. The k-th AW goes with the k-th W.
    (* anyconst *) reg [1:0] f_reg;

    // old, with the bytes whose strb bit is high replaced from data.
    function [31:0] f_merge(input [31:0] old, input [31:0] data, input [3:0] strb);
        f_merge = {strb[3] ? data[31:24] : old[31:24], strb[2] ? data[23:16] : old[23:16],
                   strb[1] ? data[15:8]  : old[15:8],  strb[0] ? data[7:0]   : old[7:0]};
    endfunction

    function f_is_reg(input [31:0] a, input [1:0] r);
        f_is_reg = a[31:5] == BASE[31:5] && a[4:2] == {1'b0, r};
    endfunction

    reg [31:0] f_word;          // what register f_reg should hold
    reg [31:0] f_awaddr;        // an AW that is waiting for its W
    reg [31:0] f_wdata;         // a W that is waiting for its AW
    reg [3:0]  f_wstrb;
    reg        f_rcheck = 1'b0; // the read in progress is of f_reg, so check it
    reg [31:0] f_rexp;          // what it must return
    reg        f_partial = 1'b0;

    // Writes with both halves taken and not yet answered.
    wire [3:0] f_pairs = (f_aw_out < f_w_out) ? f_aw_out : f_w_out;

    // The two halves of a write meet at this edge.
    wire f_pair = (f_aw_hs && f_w_hs && f_aw_out == f_w_out)
               || (f_aw_hs && !f_w_hs && f_w_out > f_aw_out)
               || (f_w_hs && !f_aw_hs && f_aw_out > f_w_out);
    wire [31:0] f_pair_addr = f_aw_hs ? awaddr : f_awaddr;
    wire [31:0] f_pair_data = f_w_hs ? wdata : f_wdata;
    wire [3:0]  f_pair_strb = f_w_hs ? wstrb : f_wstrb;

    always @(posedge clk) begin
        if (rst) begin
            f_word    <= 32'd0;
            f_rcheck  <= 1'b0;
            f_partial <= 1'b0;
        end else begin
            if (f_aw_hs && !f_pair)
                f_awaddr <= awaddr;
            if (f_w_hs && !f_pair) begin
                f_wdata <= wdata;
                f_wstrb <= wstrb;
            end
            if (f_pair && f_is_reg(f_pair_addr, f_reg)) begin
                f_word <= f_merge(f_word, f_pair_data, f_pair_strb);
                if (f_pair_strb != 4'hF && f_pair_strb != 4'h0)
                    f_partial <= 1'b1;
            end
            // Only check a read that was taken while every write whose halves
            // had both arrived was already answered, so its result is certain.
            if (f_ar_hs) begin
                f_rcheck <= f_is_reg(araddr, f_reg) && f_pairs == {3'd0, bvalid};
                f_rexp   <= f_word;
            end
        end
    end

    always @(*) begin
        if (f_past_valid) begin
            // The property: a checked read returns the copy, byte lanes and all.
            if (rvalid && f_rcheck) begin
                assert (rdata == f_rexp);
                assert (rresp == OKAY);
            end

            // Induction: at most one half of a write waits for the other.
            assert (f_aw_out <= f_w_out + 4'd1);
            assert (f_w_out <= f_aw_out + 4'd1);

            // Induction: the register matches the copy, apart from a write
            // whose halves have both arrived but that is not done yet.
            if (f_pairs == {3'd0, bvalid})
                assert (regs[f_reg] == f_word);
        end
        if (f_past_valid && !rst)
            cover (rvalid && f_rcheck && f_partial);  // a byte write read back
    end

    // The same for the buffers, which only the buffered slave has.
    generate
        if (BUFFERED) begin : g_data_buffered
            wire        aw_full   = g_buffered.aw_full;
            wire        w_full    = g_buffered.w_full;
            wire [31:2] aw_addr   = g_buffered.aw_addr;
            wire [31:0] w_data    = g_buffered.w_data;
            wire [3:0]  w_strb    = g_buffered.w_strb;
            wire [31:0] f_reg_now = regs[f_reg];

            always @(*) begin
                if (f_past_valid) begin
                    if (f_pairs != {3'd0, bvalid}) begin
                        assert (aw_full && w_full);
                        if (f_is_reg({aw_addr, 2'b00}, f_reg))
                            assert (f_word == f_merge(f_reg_now, w_data, w_strb));
                        else
                            assert (f_word == f_reg_now);
                    end
                    if (aw_full && !w_full)
                        assert (f_awaddr[31:2] == aw_addr);
                    if (w_full && !aw_full)
                        assert (f_wdata == w_data && f_wstrb == w_strb);
                end
            end
        end
    endgenerate
`endif
`endif

endmodule
