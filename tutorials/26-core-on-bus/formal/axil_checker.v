// The rules of an AXI4-Lite port, for formal verification only.
//
// Attach one of these to an AXI4-Lite port of the design being proved. It
// watches the port and never drives it. The rules split into the master's rules
// and the slave's rules, and DUT_IS_SLAVE picks which side is being proved:
//
//   DUT_IS_SLAVE = 1  the design is the slave on this port.
//                     The master's rules are assumed, the slave's are asserted.
//   DUT_IS_SLAVE = 0  the design is the master on this port.
//                     The master's rules are asserted, the slave's are assumed.
//
// These rules were written from the ARM AMBA AXI specification for this course.
// They are the safety rules only: nothing here says that a response ever comes.
// The proof starts in reset.
module axil_checker #(
    parameter DUT_IS_SLAVE    = 1,
    parameter MAX_OUTSTANDING = 2   // the slave never holds more requests per channel
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        awvalid,
    input  wire        awready,
    input  wire [31:0] awaddr,
    input  wire [2:0]  awprot,
    input  wire        wvalid,
    input  wire        wready,
    input  wire [31:0] wdata,
    input  wire [3:0]  wstrb,
    input  wire        bvalid,
    input  wire        bready,
    input  wire [1:0]  bresp,
    input  wire        arvalid,
    input  wire        arready,
    input  wire [31:0] araddr,
    input  wire [2:0]  arprot,
    input  wire        rvalid,
    input  wire        rready,
    input  wire [31:0] rdata,
    input  wire [1:0]  rresp,
    // Handshakes taken and not yet answered, on each request channel.
    output reg  [3:0]  aw_out = 4'd0,
    output reg  [3:0]  w_out  = 4'd0,
    output reg  [3:0]  ar_out = 4'd0
);

    // The previous clock's values. Every rule below is a plain expression about
    // two neighbouring clocks.
    reg        past_valid = 1'b0;
    reg        past_rst;
    reg        past_awvalid, past_awready, past_wvalid, past_wready, past_arvalid, past_arready;
    reg        past_bvalid, past_bready, past_rvalid, past_rready;
    reg [31:0] past_awaddr, past_wdata, past_araddr, past_rdata;
    reg [2:0]  past_awprot, past_arprot;
    reg [3:0]  past_wstrb;
    reg [1:0]  past_bresp, past_rresp;

    always @(posedge clk) begin
        past_valid   <= 1'b1;
        past_rst     <= rst;
        past_awvalid <= awvalid;
        past_awready <= awready;
        past_awaddr  <= awaddr;
        past_awprot  <= awprot;
        past_wvalid  <= wvalid;
        past_wready  <= wready;
        past_wdata   <= wdata;
        past_wstrb   <= wstrb;
        past_bvalid  <= bvalid;
        past_bready  <= bready;
        past_bresp   <= bresp;
        past_arvalid <= arvalid;
        past_arready <= arready;
        past_araddr  <= araddr;
        past_arprot  <= arprot;
        past_rvalid  <= rvalid;
        past_rready  <= rready;
        past_rdata   <= rdata;
        past_rresp   <= rresp;
    end

    // A handshake happens at an edge where valid and ready are both high.
    wire aw_hs = !rst && awvalid && awready;
    wire w_hs  = !rst && wvalid && wready;
    wire b_hs  = !rst && bvalid && bready;
    wire ar_hs = !rst && arvalid && arready;
    wire r_hs  = !rst && rvalid && rready;

    // AXI4-Lite has no IDs, so responses come back in order and a count is all
    // the bookkeeping needed. One B answers one AW and one W together.
    always @(posedge clk) begin
        if (rst) begin
            aw_out <= 4'd0;
            w_out  <= 4'd0;
            ar_out <= 4'd0;
        end else begin
            aw_out <= aw_out + {3'd0, aw_hs} - {3'd0, b_hs};
            w_out  <= w_out  + {3'd0, w_hs}  - {3'd0, b_hs};
            ar_out <= ar_out + {3'd0, ar_hs} - {3'd0, r_hs};
        end
    end

    // The last clock offered something that was not taken, and this is not reset.
    wire held_aw = past_valid && !past_rst && !rst && past_awvalid && !past_awready;
    wire held_w  = past_valid && !past_rst && !rst && past_wvalid && !past_wready;
    wire held_ar = past_valid && !past_rst && !rst && past_arvalid && !past_arready;
    wire held_b  = past_valid && !past_rst && past_bvalid && !past_bready;
    wire held_r  = past_valid && !past_rst && past_rvalid && !past_rready;

    // ---- The master's rules ----
    // M1. No request is on offer during reset.
    wire m_reset = !rst || (!awvalid && !wvalid && !arvalid);
    // M2. A request that was not taken stays on offer, unchanged, until it is.
    wire m_aw    = !held_aw || (awvalid && awaddr == past_awaddr && awprot == past_awprot);
    wire m_w     = !held_w  || (wvalid && wdata == past_wdata && wstrb == past_wstrb);
    wire m_ar    = !held_ar || (arvalid && araddr == past_araddr && arprot == past_arprot);

    // ---- The slave's rules ----
    // S1. No response on the clock after reset.
    wire s_reset = !(past_valid && past_rst) || (!bvalid && !rvalid);
    // S2. A response that was not taken stays on offer, unchanged, until it is.
    wire s_b     = !held_b || (bvalid && bresp == past_bresp);
    wire s_r     = !held_r || (rvalid && rdata == past_rdata && rresp == past_rresp);
    // S3. No response before its request. A write response needs both an AW and
    //     a W taken at an earlier edge, and a read response needs an AR. Because
    //     each response is held until taken, this also means one response per
    //     request: a second one would find the count at zero.
    wire s_b_asked = !bvalid || (aw_out != 4'd0 && w_out != 4'd0);
    wire s_r_asked = !rvalid || ar_out != 4'd0;
    // S4. A bounded number of requests in progress on each channel.
    wire s_depth = aw_out <= MAX_OUTSTANDING && w_out <= MAX_OUTSTANDING &&
                   ar_out <= MAX_OUTSTANDING;
    // S5. EXOKAY (2'b01) is for exclusive accesses, which AXI4-Lite does not have.
    wire s_resp  = (!bvalid || bresp != 2'b01) && (!rvalid || rresp != 2'b01);

    always @(*) begin
        // The first clock is in reset, so nothing is checked until the second.
        if (!past_valid)
            assume (rst);
        else if (DUT_IS_SLAVE) begin
            assume (m_reset);
            assume (m_aw);
            assume (m_w);
            assume (m_ar);
            assert (s_reset);
            assert (s_b);
            assert (s_r);
            assert (s_b_asked);
            assert (s_r_asked);
            assert (s_depth);
            assert (s_resp);
        end else begin
            assert (m_reset);
            assert (m_aw);
            assert (m_w);
            assert (m_ar);
            assume (s_reset);
            assume (s_b);
            assume (s_r);
            assume (s_b_asked);
            assume (s_r_asked);
            assume (s_depth);
            assume (s_resp);
        end
    end

endmodule
