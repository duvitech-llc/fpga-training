// Tutorial 25's crc32_byte as a Wishbone B4 pipelined slave:
//
//   BASE + 0x0  CLEAR   write: start a new message. The data is ignored.
//                       Reads return 0.
//   BASE + 0x4  DATA    write with sel[0] high: add byte 0 of dat_w, bits 7 to 0,
//                       to the message. A write that leaves byte 0 out does
//                       nothing. Reads return 0.
//   BASE + 0x8  RESULT  read: the CRC-32 of every byte since the last CLEAR, or
//                       since reset, the same number as Python's zlib.crc32.
//                       A write gets err.
//   BASE + 0xC          nothing: any access gets err.
//
// crc32_byte takes one byte per clock, and every request takes at least one
// clock, so DATA never has to stall. A RESULT read accepted on the clock after
// a DATA write already includes that byte.
//
// adr is two bits: the word within the slave. The interconnect has checked the
// rest. Each request gets ack or err on the next clock. hold stalls requests,
// as in wb_regfile. Tie it low in a real design.
module wb_crc (
    input  wire        clk,
    input  wire        rst,     // synchronous, active high
    input  wire        cyc,
    input  wire        stb,
    input  wire        we,
    input  wire [1:0]  adr,     // 0 CLEAR, 1 DATA, 2 RESULT
    input  wire [3:0]  sel,
    input  wire [31:0] dat_w,
    output reg         ack,
    output reg         err,
    output wire        stall,
    output reg  [31:0] dat_r,
    input  wire        hold
);

    localparam [1:0] R_CLEAR = 2'd0, R_DATA = 2'd1, R_RESULT = 2'd2;

    assign stall = hold;

    wire accept = cyc && stb && !stall;
    wire bad    = (adr == 2'd3) || (we && adr == R_RESULT);

    wire [31:0] crc;

    // Tutorial 25's module, unchanged.
    crc32_byte u_crc (
        .clk(clk), .rst(rst),
        .clear(accept && we && adr == R_CLEAR),
        .valid(accept && we && adr == R_DATA && sel[0]),
        .data(dat_w[7:0]),
        .crc(crc)
    );

    always @(posedge clk) begin
        if (rst || !cyc) begin
            ack <= 1'b0;
            err <= 1'b0;
        end else begin
            ack <= accept && !bad;
            err <= accept && bad;
        end

        if (accept)
            dat_r <= (adr == R_RESULT) ? crc : 32'd0;
    end

    // Only byte 0 of a write is used.
    wire unused = &{1'b0, sel[3:1], dat_w[31:8]};

`ifdef FORMAL
    reg f_past_valid = 1'b0;
    reg f_past_rst, f_past_cyc, f_past_hold;
    always @(posedge clk) begin
        f_past_valid <= 1'b1;
        f_past_rst   <= rst;
        f_past_cyc   <= cyc;
        f_past_hold  <= hold;
    end

    always @(*)
        if (f_past_valid && f_past_hold)
            assume (!hold);

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

    // The last request, to check its answer.
    reg        f_bad_q = 1'b0;
    reg        f_result_q = 1'b0;
    reg [31:0] f_crc_q;
    always @(posedge clk) begin
        f_bad_q    <= accept && bad;
        f_result_q <= accept && !we && adr == R_RESULT;
        f_crc_q    <= crc;
    end

    always @(*) begin
        if (f_past_valid && !f_past_rst && f_past_cyc) begin
            assert (f_outstanding == {3'd0, ack || err});
            if (ack || err)
                assert (err == f_bad_q);
            // A RESULT read returns the CRC as it was at the edge that took it.
            if (ack && f_result_q)
                assert (dat_r == f_crc_q);
        end else if (f_past_valid) begin
            assert (!ack && !err);
        end
    end

    // The CRC changes only on an accepted write to DATA or CLEAR, and a CLEAR
    // leaves the CRC of no bytes at all, which is 0.
    reg f_feed_q  = 1'b0;
    reg f_clear_q = 1'b0;
    always @(posedge clk) begin
        f_feed_q  <= accept && we && (adr == R_DATA || adr == R_CLEAR);
        f_clear_q <= accept && we && adr == R_CLEAR;
    end

    always @(*) begin
        if (f_past_valid && !f_past_rst && crc != f_crc_q)
            assert (f_feed_q);
        if (f_past_valid && f_clear_q)
            assert (crc == 32'd0);
    end

    always @(*) begin
        if (f_past_valid && !rst) begin
            cover (ack && f_result_q && dat_r != 32'd0);  // a CRC read back
            cover (err && f_past_cyc);                    // a write to RESULT, or the hole
            cover (cyc && stb && stall);                  // a request held back
        end
    end
`endif

endmodule
