// A bridge from the core's native memory interface (Tutorial 21) to a Wishbone B4
// pipelined master port (Tutorial 22). One native transfer becomes one Wishbone
// request, and its answer ends the transfer.
//
//   mem_addr[31:2]  becomes adr. Bits 1 and 0 are always 0, by the core's rules.
//   mem_wstrb       becomes sel for a write, and we is high. A read has wstrb 0000,
//                   and asks for the whole word with sel 1111.
//   mem_wdata       becomes dat_w. The core has already put the bytes in their lanes.
//   ack             becomes mem_ready, with dat_r as mem_rdata.
//   err             becomes mem_err, and mem_ready stays low.
//
// The request side is combinational: stb is mem_valid, unless an answer is owed.
// The core holds its request still until mem_ready, which is exactly what
// Wishbone asks of a stalled request, so nothing needs to be stored. This saves a
// clock on every access over a bridge that registers the request first.
//
// After an err the bridge sends nothing more until mem_valid falls. Tutorial 21's
// core does not know about mem_err, so it keeps waiting with mem_valid high, and
// the system stops there. soc.v turns that into a trap. A core that handles
// errors must drop mem_valid for at least one clock after mem_err.
module rv_wb_bridge (
    input  wire        clk,
    input  wire        rst,        // synchronous, active high
    // Native interface, from the core
    input  wire        mem_valid,
    output wire        mem_ready,  // the transfer is done
    output wire        mem_err,    // the transfer failed. Ends it, like mem_ready
    input  wire [31:0] mem_addr,
    input  wire [31:0] mem_wdata,
    input  wire [3:0]  mem_wstrb,
    output wire [31:0] mem_rdata,
    // Wishbone master port
    output wire        cyc,
    output wire        stb,
    output wire        we,
    output wire [29:0] adr,
    output wire [3:0]  sel,
    output wire [31:0] dat_w,
    input  wire        ack,
    input  wire        err,
    input  wire        stall,
    input  wire [31:0] dat_r
);

    reg busy;    // the request was accepted, and its answer is owed
    reg failed;  // the last answer was err, and mem_valid has not fallen since

    assign stb   = !rst && mem_valid && !busy && !failed;
    assign cyc   = stb || busy;
    assign we    = mem_wstrb != 4'd0;
    assign adr   = mem_addr[31:2];
    assign sel   = we ? mem_wstrb : 4'b1111;
    assign dat_w = mem_wdata;

    wire answer = busy && (ack || err);

    assign mem_ready = busy && ack;
    assign mem_err   = busy && err;
    assign mem_rdata = dat_r;

    always @(posedge clk) begin
        if (rst) begin
            busy   <= 1'b0;
            failed <= 1'b0;
        end else begin
            if (stb && !stall)
                busy <= 1'b1;
            else if (answer)
                busy <= 1'b0;

            if (answer && err)
                failed <= 1'b1;
            else if (!mem_valid)
                failed <= 1'b0;
        end
    end

    // Bits 1 and 0 of the address are always 0. The name keeps the linter quiet.
    wire unused = &{1'b0, mem_addr[1:0]};

`ifdef FORMAL
    reg f_past_valid = 1'b0;
    always @(posedge clk)
        f_past_valid <= 1'b1;

    // ---- The core's side: Tutorial 21's rules, assumed ----
    // mem_valid is low on the clock after reset. Once high, it stays high, and the
    // request stays still, until a clock with mem_ready. After mem_err the core may
    // do either: keep waiting, as Tutorial 21's does, or drop mem_valid.
    reg        f_past_rst = 1'b1;
    reg        f_past_wait = 1'b0;   // a request was waiting at the last edge
    reg [31:0] f_past_addr, f_past_wdata;
    reg [3:0]  f_past_wstrb;
    always @(posedge clk) begin
        f_past_rst   <= rst;
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

    // ---- The Wishbone side: Tutorial 22's checker, with this bridge as master ----
    // The slaves are assumed to answer within 4 clocks and stall for fewer than 4.
    wire [3:0] f_outstanding;
    wire [7:0] f_waited;
    wire [7:0] f_stalled;

    wb_checker #(
        .AW(30), .DUT_IS_SLAVE(0), .LGDEPTH(4),
        .MAX_OUTSTANDING(1), .MAX_WAIT(4), .MAX_STALL(4)
    ) f_bus (
        .clk(clk), .rst(rst),
        .cyc(cyc), .stb(stb), .we(we), .adr(adr), .sel(sel), .dat_w(dat_w),
        .ack(ack), .err(err), .stall(stall),
        .outstanding(f_outstanding), .waited(f_waited), .stalled(f_stalled)
    );

    // ---- What the bridge promises ----
    // How many Wishbone requests this native transfer has made. Exactly one, by
    // the time it ends.
    reg [1:0] f_sent = 2'd0;
    always @(posedge clk) begin
        if (rst || mem_ready || mem_err || !mem_valid)
            f_sent <= 2'd0;
        else if (stb && !stall)
            f_sent <= f_sent + 1'b1;
    end

    always @(*) begin
        if (f_past_valid && !f_past_rst && !rst) begin
            // Induction: the bridge's state agrees with the checker's count.
            assert (f_outstanding == {3'd0, busy});
            assert (!(busy && failed));
            if (busy)
                assert (mem_valid && f_sent == 2'd1);
            if (!busy && !failed && mem_valid)
                assert (f_sent == 2'd0);

            // Never more than one request for one transfer.
            assert (f_sent <= 2'd1);
            // A transfer ends only with the answer to its own request.
            if (mem_ready || mem_err)
                assert (busy && f_sent == 2'd1);
            assert (!(mem_ready && mem_err));
            // The request is the transfer, field by field.
            if (stb) begin
                assert (adr == mem_addr[31:2]);
                assert (we == (mem_wstrb != 4'd0));
                assert (sel == (we ? mem_wstrb : 4'b1111));
                assert (dat_w == mem_wdata);
            end
            // After an err, nothing more until mem_valid falls.
            if (failed)
                assert (!stb && !cyc);
        end
    end

    // These must be reachable, or an assumption has ruled them out.
    // The fastest a transfer can go is two clocks: one to send the request, one
    // for the answer. So back to back means mem_ready on every other clock.
    reg f_past_ready = 1'b0, f_past2_ready = 1'b0;
    always @(posedge clk) begin
        f_past_ready  <= !rst && mem_ready;
        f_past2_ready <= !rst && f_past_ready;
    end

    always @(*) begin
        if (f_past_valid && !rst) begin
            cover (mem_ready && we);                    // a write done
            cover (mem_ready && !we && f_past2_ready);  // a read straight after another transfer
            cover (stb && stall);                       // a stalled request
            cover (mem_err);                            // an err
            cover (failed && mem_valid && f_waited == 0 && !busy); // waiting after an err
        end
    end
`endif

endmodule
