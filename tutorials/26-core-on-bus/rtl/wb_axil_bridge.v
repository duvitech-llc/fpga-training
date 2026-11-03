// A bridge from a Wishbone B4 pipelined slave port (Tutorial 22) to an AXI4-Lite
// master port (Tutorial 23), so that an AXI4-Lite slave can sit on a Wishbone bus.
//
// It carries one request at a time, and stalls the next until the first is done.
//
//   A write becomes one AW and one W, offered together: awaddr is {adr, 2'b00},
//   wdata is dat_w and wstrb is sel. The B response becomes the answer.
//   A read becomes one AR, and the R response becomes the answer, with rdata as
//   dat_r.
//   OKAY becomes ack. SLVERR and DECERR become err.
//
// awvalid, wvalid and arvalid come from flip-flops, so they hold still until
// taken, as AXI requires, whatever the Wishbone side does. They are also gated
// by rst, since AXI forbids a valid during reset, and a synchronous reset only
// clears a flip-flop at the end of the first reset clock. bready and rready are
// high while a request is in progress, and the answer is passed straight on in
// the clock the response arrives.
//
// If the master drops cyc while a request is in progress, the AXI side cannot be
// cancelled. The bridge lets it finish, and throws its response away.
module wb_axil_bridge (
    input  wire        clk,
    input  wire        rst,       // synchronous, active high
    // Wishbone slave port
    input  wire        cyc,
    input  wire        stb,
    input  wire        we,
    input  wire [29:0] adr,
    input  wire [3:0]  sel,
    input  wire [31:0] dat_w,
    output wire        ack,
    output wire        err,
    output wire        stall,
    output wire [31:0] dat_r,
    // AXI4-Lite master port
    output wire        awvalid,
    input  wire        awready,
    output reg  [31:0] awaddr,
    output wire [2:0]  awprot,
    output wire        wvalid,
    input  wire        wready,
    output reg  [31:0] wdata,
    output reg  [3:0]  wstrb,
    input  wire        bvalid,
    output wire        bready,
    input  wire [1:0]  bresp,
    output wire        arvalid,
    input  wire        arready,
    output reg  [31:0] araddr,
    output wire [2:0]  arprot,
    input  wire        rvalid,
    output wire        rready,
    input  wire [31:0] rdata,
    input  wire [1:0]  rresp
);

    reg busy;      // a request was accepted, and its response has not come
    reg writing;   // and it is a write
    reg orphan;    // and the master has dropped cyc since, so nobody wants the answer
    reg aw_pend;   // AW is on offer and has not been taken
    reg w_pend;    // W likewise
    reg ar_pend;   // AR likewise

    assign awvalid = aw_pend && !rst;
    assign wvalid  = w_pend && !rst;
    assign arvalid = ar_pend && !rst;

    assign stall  = busy;
    assign awprot = 3'b000;   // unprivileged, secure, data
    assign arprot = 3'b000;
    assign bready = busy && writing;
    assign rready = busy && !writing;

    wire accept = cyc && stb && !stall;
    wire done   = (bvalid && bready) || (rvalid && rready);
    wire okay   = writing ? (bresp == 2'b00) : (rresp == 2'b00);

    // The answer, in the clock the response arrives. Not after cyc has fallen.
    assign ack   = cyc && !orphan && done && okay;
    assign err   = cyc && !orphan && done && !okay;
    assign dat_r = rdata;

    always @(posedge clk) begin
        if (rst) begin
            busy    <= 1'b0;
            writing <= 1'b0;
            orphan  <= 1'b0;
            aw_pend <= 1'b0;
            w_pend  <= 1'b0;
            ar_pend <= 1'b0;
        end else begin
            if (accept) begin
                busy    <= 1'b1;
                writing <= we;
                orphan  <= 1'b0;
                aw_pend <= we;
                w_pend  <= we;
                ar_pend <= !we;
                awaddr  <= {adr, 2'b00};
                araddr  <= {adr, 2'b00};
                wdata   <= dat_w;
                wstrb   <= sel;
            end else begin
                if (awready)
                    aw_pend <= 1'b0;
                if (wready)
                    w_pend <= 1'b0;
                if (arready)
                    ar_pend <= 1'b0;
                if (done)
                    busy <= 1'b0;
                if (busy && !cyc)
                    orphan <= 1'b1;
            end
        end
    end

`ifdef FORMAL
    // How quickly the AXI slave is assumed to act: see the assumptions below.
    localparam F_WAIT = 3;

    reg f_past_valid = 1'b0;
    reg f_past_rst   = 1'b1;
    always @(posedge clk) begin
        f_past_valid <= 1'b1;
        f_past_rst   <= rst;
    end

    // ---- The Wishbone side, with this bridge as the slave ----
    wire [3:0] f_wb_out;
    wire [7:0] f_waited;
    wire [7:0] f_stalled;

    wb_checker #(
        .AW(30), .DUT_IS_SLAVE(1), .LGDEPTH(4),
        .MAX_OUTSTANDING(1), .MAX_WAIT(2 * F_WAIT + 1), .MAX_STALL(2 * F_WAIT + 2)
    ) f_wb (
        .clk(clk), .rst(rst),
        .cyc(cyc), .stb(stb), .we(we), .adr(adr), .sel(sel), .dat_w(dat_w),
        .ack(ack), .err(err), .stall(stall),
        .outstanding(f_wb_out), .waited(f_waited), .stalled(f_stalled)
    );

    // ---- The AXI side, with this bridge as the master ----
    wire [3:0] f_aw_out, f_w_out, f_ar_out;

    axil_checker #(
        .DUT_IS_SLAVE(0), .MAX_OUTSTANDING(1)
    ) f_axi (
        .clk(clk), .rst(rst),
        .awvalid(awvalid), .awready(awready), .awaddr(awaddr), .awprot(awprot),
        .wvalid(wvalid), .wready(wready), .wdata(wdata), .wstrb(wstrb),
        .bvalid(bvalid), .bready(bready), .bresp(bresp),
        .arvalid(arvalid), .arready(arready), .araddr(araddr), .arprot(arprot),
        .rvalid(rvalid), .rready(rready), .rdata(rdata), .rresp(rresp),
        .aw_out(f_aw_out), .w_out(f_w_out), .ar_out(f_ar_out)
    );

    // The AXI checker has no liveness rules. To prove that the Wishbone answer
    // comes, assume the AXI slave is quick: a valid on offer is taken within
    // F_WAIT clocks, and a response comes within F_WAIT clocks of its request.
    // These are about the slave only, so a bridge that never offered a request
    // would still fail the Wishbone checker's S5.
    reg [3:0] f_aw_wait = 4'd0, f_w_wait = 4'd0, f_ar_wait = 4'd0;
    reg [3:0] f_b_wait = 4'd0, f_r_wait = 4'd0;
    always @(posedge clk) begin
        f_aw_wait <= (rst || !awvalid || awready) ? 4'd0 : f_aw_wait + 1'b1;
        f_w_wait  <= (rst || !wvalid || wready)   ? 4'd0 : f_w_wait + 1'b1;
        f_ar_wait <= (rst || !arvalid || arready) ? 4'd0 : f_ar_wait + 1'b1;
        f_b_wait  <= (rst || f_aw_out == 0 || f_w_out == 0 || bvalid) ? 4'd0 : f_b_wait + 1'b1;
        f_r_wait  <= (rst || f_ar_out == 0 || rvalid) ? 4'd0 : f_r_wait + 1'b1;
    end
    always @(*) begin
        assume (f_aw_wait < F_WAIT);
        assume (f_w_wait < F_WAIT);
        assume (f_ar_wait < F_WAIT);
        assume (f_b_wait < F_WAIT);
        assume (f_r_wait < F_WAIT);
    end

    always @(*) begin
        if (f_past_valid && !f_past_rst && !rst) begin
            // Induction: each count agrees with the bridge's state.
            assert (f_aw_out == {3'd0, busy && writing && !aw_pend});
            assert (f_w_out  == {3'd0, busy && writing && !w_pend});
            assert (f_ar_out == {3'd0, busy && !writing && !ar_pend});
            if (!busy)
                assert (!aw_pend && !w_pend && !ar_pend);
            if (busy && writing)
                assert (!ar_pend);
            if (busy && !writing)
                assert (!aw_pend && !w_pend);
            if (orphan)
                assert (f_wb_out == 4'd0);
            else
                assert (f_wb_out == {3'd0, busy});
            if (busy)
                assert (awaddr == araddr);
        end
    end

    // The AXI request is the Wishbone request, field by field.
    reg [29:0] f_adr;
    reg [3:0]  f_sel;
    reg [31:0] f_dat;
    always @(posedge clk)
        if (accept) begin
            f_adr <= adr;
            f_sel <= sel;
            f_dat <= dat_w;
        end

    always @(*) begin
        if (f_past_valid && !f_past_rst && busy) begin
            assert (awaddr == {f_adr, 2'b00});
            if (writing)
                assert (wdata == f_dat && wstrb == f_sel);
        end
        // OKAY is ack, and anything else is err.
        if (f_past_valid && !rst && ack)
            assert ((writing ? bresp : rresp) == 2'b00);
    end

    always @(*) begin
        if (f_past_valid && !rst) begin
            cover (ack && writing);
            cover (ack && !writing);
            cover (err && writing && bresp == 2'b10);   // SLVERR
            cover (err && !writing && rresp == 2'b11);  // DECERR
            cover (cyc && stb && stall);                // a request held back
            cover (done && orphan);                     // a response thrown away
            cover (busy && writing && !aw_pend && w_pend); // AW taken before W
        end
    end
`endif

endmodule
