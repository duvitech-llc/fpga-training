// A bridge from the core's native memory interface (Tutorial 21) straight to an
// AXI4-Lite master port (Tutorial 23), with no Wishbone in between. The system
// in this lesson does not use it. It is here to measure what the route through
// Wishbone costs: see tb/tb_paths.v.
//
//   A write (mem_wstrb not 0000) offers AW and W together: awaddr is mem_addr,
//   wdata is mem_wdata and wstrb is mem_wstrb. The B response ends the transfer.
//   A read offers AR with araddr at mem_addr. The R response ends the transfer,
//   with rdata as mem_rdata.
//   OKAY becomes mem_ready. SLVERR and DECERR become mem_err.
//
// The valids are combinational, from mem_valid. The core holds its request
// still until mem_ready, so each valid holds still until its handshake, as AXI
// requires. bready and rready are always high, since the core takes a response
// as soon as it comes.
//
// After an error the bridge offers nothing more until mem_valid falls, as
// rv_wb_bridge does.
module rv_axil_bridge (
    input  wire        clk,
    input  wire        rst,        // synchronous, active high
    // Native interface, from the core
    input  wire        mem_valid,
    output wire        mem_ready,
    output wire        mem_err,
    input  wire [31:0] mem_addr,
    input  wire [31:0] mem_wdata,
    input  wire [3:0]  mem_wstrb,
    output wire [31:0] mem_rdata,
    // AXI4-Lite master port
    output wire        awvalid,
    input  wire        awready,
    output wire [31:0] awaddr,
    output wire [2:0]  awprot,
    output wire        wvalid,
    input  wire        wready,
    output wire [31:0] wdata,
    output wire [3:0]  wstrb,
    input  wire        bvalid,
    output wire        bready,
    input  wire [1:0]  bresp,
    output wire        arvalid,
    input  wire        arready,
    output wire [31:0] araddr,
    output wire [2:0]  arprot,
    input  wire        rvalid,
    output wire        rready,
    input  wire [31:0] rdata,
    input  wire [1:0]  rresp
);

    reg aw_done;   // this transfer's AW has been taken
    reg w_done;    // and its W
    reg ar_done;   // this transfer's AR has been taken
    reg failed;    // the last response was an error, and mem_valid has not fallen since

    wire write = mem_wstrb != 4'd0;
    wire go    = !rst && mem_valid && !failed;

    assign awvalid = go && write && !aw_done;
    assign wvalid  = go && write && !w_done;
    assign arvalid = go && !write && !ar_done;
    assign awaddr  = mem_addr;
    assign araddr  = mem_addr;
    assign awprot  = 3'b000;
    assign arprot  = 3'b000;
    assign wdata   = mem_wdata;
    assign wstrb   = mem_wstrb;
    assign bready  = 1'b1;
    assign rready  = 1'b1;

    wire b_done = bvalid;     // bready is always high
    wire r_done = rvalid;

    assign mem_ready = (b_done && bresp == 2'b00) || (r_done && rresp == 2'b00);
    assign mem_err   = (b_done && bresp != 2'b00) || (r_done && rresp != 2'b00);
    assign mem_rdata = rdata;

    always @(posedge clk) begin
        if (rst) begin
            aw_done <= 1'b0;
            w_done  <= 1'b0;
            ar_done <= 1'b0;
            failed  <= 1'b0;
        end else begin
            if (b_done) begin
                aw_done <= 1'b0;
                w_done  <= 1'b0;
            end else begin
                if (awvalid && awready)
                    aw_done <= 1'b1;
                if (wvalid && wready)
                    w_done <= 1'b1;
            end

            if (r_done)
                ar_done <= 1'b0;
            else if (arvalid && arready)
                ar_done <= 1'b1;

            if (mem_err)
                failed <= 1'b1;
            else if (!mem_valid)
                failed <= 1'b0;
        end
    end

`ifdef FORMAL
    reg f_past_valid = 1'b0;
    reg f_past_rst   = 1'b1;
    always @(posedge clk) begin
        f_past_valid <= 1'b1;
        f_past_rst   <= rst;
    end

    // ---- The core's side: Tutorial 21's rules, assumed, as in rv_wb_bridge ----
    reg        f_past_wait = 1'b0;
    reg [31:0] f_past_addr, f_past_wdata;
    reg [3:0]  f_past_wstrb;
    always @(posedge clk) begin
        f_past_wait  <= !rst && mem_valid && !mem_ready && !mem_err;
        f_past_addr  <= mem_addr;
        f_past_wdata <= mem_wdata;
        f_past_wstrb <= mem_wstrb;
    end

    always @(*) begin
        if (f_past_valid && f_past_rst)
            assume (!mem_valid);
        if (f_past_valid && f_past_wait && !rst)
            assume (mem_valid && mem_addr == f_past_addr && mem_wdata == f_past_wdata
                    && mem_wstrb == f_past_wstrb);
        assume (mem_addr[1:0] == 2'b00);
    end

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

    always @(*) begin
        if (f_past_valid && !f_past_rst && !rst) begin
            // Induction: the counts agree with the bridge's state.
            assert (f_aw_out == {3'd0, aw_done});
            assert (f_w_out  == {3'd0, w_done});
            assert (f_ar_out == {3'd0, ar_done});
            if (aw_done || w_done || ar_done)
                assert (mem_valid && !failed);
            if (aw_done || w_done)
                assert (write);
            if (ar_done)
                assert (!write);
            // A transfer ends only with its own response.
            if (mem_ready || mem_err)
                assert ((write && aw_done && w_done) || (!write && ar_done));
            assert (!(mem_ready && mem_err));
            if (failed)
                assert (!awvalid && !wvalid && !arvalid);
        end
    end

    always @(*) begin
        if (f_past_valid && !rst) begin
            cover (mem_ready && write);
            cover (mem_ready && !write);
            cover (mem_err && write);
            cover (mem_err && !write);
            cover (aw_done && !w_done && wvalid);   // AW taken before W
            cover (w_done && !aw_done && awvalid);  // W taken before AW
        end
    end
`endif

endmodule
