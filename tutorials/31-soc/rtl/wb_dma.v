// A DMA engine: a Wishbone B4 pipelined slave with five registers, and a Wishbone
// master that copies memory while the CPU does something else.
//
// Registers, at byte offsets from its base:
//
//   +0x00  SRC     source byte address. Moves on as the copy runs.
//   +0x04  DST     destination byte address. Moves on as the copy runs.
//   +0x08  LEN     bytes still to copy. Counts down to 0 as the copy runs.
//   +0x0C  CTRL    bit 0 START: write 1 to start. Reads as 0.
//                  bit 1 SRC_FIXED: SRC does not move, as for a peripheral's data register.
//                  bit 2 DST_FIXED: DST does not move. Set it to feed the UART.
//                  bit 3 BYTES: copy one byte at a time. Clear: whole words.
//                  bit 4 PACE: wait for the dreq input before each unit.
//   +0x10  STATUS  read-only. bit 0 BUSY, bit 1 DONE, bit 2 ERROR.
//                  START clears DONE and ERROR.
//   +0x14 to +0x1C nothing: a read or write gets err.
//
// Word copies need SRC, DST and LEN all multiples of 4. If they are not, START
// sets ERROR at once and nothing goes on the bus. Byte copies take any address
// and any length. A start with LEN 0 sets DONE at once.
//
// Each unit, a word or a byte, is one Wishbone cycle: a read of SRC, then a write
// to DST, then cyc drops for at least one clock, so another master can have the
// bus. A byte is read as the whole word that holds it, and written with sel for
// its lane only, with the byte copied to all four lanes, as the core does.
// So one unit takes at least 5 clocks: 4 with cyc high and 1 with it low.
//
// If either request gets err, the copy stops: ERROR is set, BUSY clears, and SRC,
// DST and LEN still describe the unit that failed. Nothing more goes on the bus.
//
// While BUSY, writes to SRC, DST, LEN and CTRL are acknowledged and ignored. There
// is no way to stop a copy early except reset.
//
// PACE waits for dreq outside a cycle, so a slow device does not hold the bus.
// With dreq from the UART's tx_ready, each byte waits until the transmitter can
// take it.
module wb_dma (
    input  wire        clk,
    input  wire        rst,       // synchronous, active high
    // Slave port: the registers
    input  wire        s_cyc,
    input  wire        s_stb,
    input  wire        s_we,
    input  wire [2:0]  s_adr,     // the word within the slave
    input  wire [3:0]  s_sel,
    input  wire [31:0] s_dat_w,
    output reg         s_ack,
    output reg         s_err,
    output wire        s_stall,
    output reg  [31:0] s_dat_r,
    input  wire        hold,      // stalls the slave port, as in wb_regfile. Tie low
    // Master port: the copy
    output wire        m_cyc,
    output wire        m_stb,
    output wire        m_we,
    output wire [29:0] m_adr,
    output wire [3:0]  m_sel,
    output wire [31:0] m_dat_w,
    input  wire        m_ack,
    input  wire        m_err,
    input  wire        m_stall,
    input  wire [31:0] m_dat_r,
    // A device is ready for the next unit. Used only with PACE.
    input  wire        dreq,
    // STATUS, as wires, for an interrupt later
    output wire        busy,
    output reg         done,
    output reg         error
);

    localparam [2:0] IDLE      = 3'd0;
    localparam [2:0] WAIT      = 3'd1;   // between units, cyc low
    localparam [2:0] READ      = 3'd2;   // the read request is on the bus
    localparam [2:0] READ_ACK  = 3'd3;   // waiting for its answer
    localparam [2:0] WRITE     = 3'd4;   // the write request is on the bus
    localparam [2:0] WRITE_ACK = 3'd5;   // waiting for its answer

    reg [2:0]  state;
    reg [31:0] src, dst, len;
    reg        src_fixed, dst_fixed, bytes, pace;
    reg [31:0] data;                     // the unit read, already in its write lanes

    assign busy = state != IDLE;

    // ----- The slave port -----

    assign s_stall = hold;

    wire accept = s_cyc && s_stb && !s_stall;
    wire write  = accept && s_we && !busy;      // a write that changes something
    wire start  = write && s_adr == 3'd3 && s_sel[0] && s_dat_w[0];

    // The mode of a start comes from the same write.
    wire new_bytes = s_dat_w[3];
    wire aligned   = (src[1:0] | dst[1:0] | len[1:0]) == 2'b00;

    wire [31:0] status = {29'd0, error, done, busy};
    wire [31:0] ctrl   = {27'd0, pace, bytes, dst_fixed, src_fixed, 1'b0};

    // A register write that honours sel.
    function [31:0] merge(input [31:0] old, input [31:0] new_value, input [3:0] lanes);
        integer n;
        begin
            for (n = 0; n < 4; n = n + 1)
                merge[8*n +: 8] = lanes[n] ? new_value[8*n +: 8] : old[8*n +: 8];
        end
    endfunction

    always @(posedge clk) begin
        if (rst || !s_cyc) begin
            s_ack <= 1'b0;
            s_err <= 1'b0;
        end else begin
            s_ack <= accept && s_adr <= 3'd4;
            s_err <= accept && s_adr > 3'd4;
        end

        if (accept)
            case (s_adr)
                3'd0:    s_dat_r <= src;
                3'd1:    s_dat_r <= dst;
                3'd2:    s_dat_r <= len;
                3'd3:    s_dat_r <= ctrl;
                3'd4:    s_dat_r <= status;
                default: s_dat_r <= 32'd0;
            endcase
    end

    // ----- The master port -----


    wire [31:0] unit = bytes ? 32'd1 : 32'd4;

    assign m_cyc   = state == READ || state == READ_ACK || state == WRITE || state == WRITE_ACK;
    assign m_stb   = state == READ || state == WRITE;
    assign m_we    = state == WRITE || state == WRITE_ACK;
    assign m_adr   = m_we ? dst[31:2] : src[31:2];
    assign m_sel   = !m_we ? 4'b1111 : bytes ? (4'b0001 << dst[1:0]) : 4'b1111;
    assign m_dat_w = data;

    // The byte that SRC points at, from the word read.
    wire [7:0] lane = m_dat_r[8*src[1:0] +: 8];

    always @(posedge clk) begin
        if (rst) begin
            state     <= IDLE;
            src       <= 32'd0;
            dst       <= 32'd0;
            len       <= 32'd0;
            src_fixed <= 1'b0;
            dst_fixed <= 1'b0;
            bytes     <= 1'b0;
            pace      <= 1'b0;
            data      <= 32'd0;
            done      <= 1'b0;
            error     <= 1'b0;
        end else begin
            // The CPU's writes, only while idle.
            if (write && s_adr == 3'd0) src <= merge(src, s_dat_w, s_sel);
            if (write && s_adr == 3'd1) dst <= merge(dst, s_dat_w, s_sel);
            if (write && s_adr == 3'd2) len <= merge(len, s_dat_w, s_sel);
            if (write && s_adr == 3'd3 && s_sel[0]) begin
                src_fixed <= s_dat_w[1];
                dst_fixed <= s_dat_w[2];
                bytes     <= s_dat_w[3];
                pace      <= s_dat_w[4];
            end

            if (start) begin
                done  <= 1'b0;
                error <= 1'b0;
                if (len == 32'd0)
                    done <= 1'b1;
                else if (!new_bytes && !aligned)
                    error <= 1'b1;
                else
                    state <= WAIT;
            end

            case (state)
                WAIT:
                    if (!pace || dreq)
                        state <= READ;
                READ:
                    if (!m_stall)
                        state <= READ_ACK;
                READ_ACK:
                    if (m_err) begin
                        error <= 1'b1;
                        state <= IDLE;
                    end else if (m_ack) begin
                        data  <= bytes ? {4{lane}} : m_dat_r;
                        state <= WRITE;
                    end
                WRITE:
                    if (!m_stall)
                        state <= WRITE_ACK;
                WRITE_ACK:
                    if (m_err) begin
                        error <= 1'b1;
                        state <= IDLE;
                    end else if (m_ack) begin
                        if (!src_fixed) src <= src + unit;
                        if (!dst_fixed) dst <= dst + unit;
                        len <= len - unit;
                        if (len == unit) begin
                            done  <= 1'b1;
                            state <= IDLE;
                        end else begin
                            state <= WAIT;
                        end
                    end
                default: ;   // IDLE
            endcase
        end
    end


`ifdef FORMAL
    reg f_past_valid = 1'b0;
    reg f_past_rst   = 1'b1;
    always @(posedge clk) begin
        f_past_valid <= 1'b1;
        f_past_rst   <= rst;
    end

    // ---- The bus rules on both ports ----
    // The master port's slaves answer within 4 clocks and stall for fewer than 4.
    // The slave port must answer on the next clock. Its stalls come from hold,
    // which has no limit.
    wire [3:0] f_m_outstanding, f_s_outstanding;
    wire [7:0] f_m_waited, f_m_stalled, f_s_waited, f_s_stalled;

    wb_checker #(
        .AW(30), .DUT_IS_SLAVE(0), .LGDEPTH(4),
        .MAX_OUTSTANDING(1), .MAX_WAIT(4), .MAX_STALL(4)
    ) f_master (
        .clk(clk), .rst(rst),
        .cyc(m_cyc), .stb(m_stb), .we(m_we), .adr(m_adr), .sel(m_sel), .dat_w(m_dat_w),
        .ack(m_ack), .err(m_err), .stall(m_stall),
        .outstanding(f_m_outstanding), .waited(f_m_waited), .stalled(f_m_stalled)
    );

    wb_checker #(
        .AW(3), .DUT_IS_SLAVE(1), .LGDEPTH(4),
        .MAX_OUTSTANDING(1), .MAX_WAIT(2), .MAX_STALL(0)
    ) f_slave (
        .clk(clk), .rst(rst),
        .cyc(s_cyc), .stb(s_stb), .we(s_we), .adr(s_adr), .sel(s_sel), .dat_w(s_dat_w),
        .ack(s_ack), .err(s_err), .stall(s_stall),
        .outstanding(f_s_outstanding), .waited(f_s_waited), .stalled(f_s_stalled)
    );

    // ---- A copy, followed from its start ----
    // At START the proof remembers SRC, DST and LEN, and counts the bytes written
    // since. Every request must then be at the address that count says.
    reg [31:0] f_src0, f_dst0, f_len0, f_moved;
    reg        f_read_done;    // this unit's read has been answered
    always @(posedge clk) begin
        if (start && !busy) begin
            f_src0  <= src;
            f_dst0  <= dst;
            f_len0  <= len;
            f_moved <= 32'd0;
        end else if (state == WRITE_ACK && m_ack)
            f_moved <= f_moved + unit;

        if (rst || state == IDLE || (state == WRITE_ACK && (m_ack || m_err)))
            f_read_done <= 1'b0;
        else if (state == READ_ACK && m_ack)
            f_read_done <= 1'b1;
    end

    // How long cyc has been high. Each of the four states lasts at most 4 clocks,
    // given the slaves' limits, so a cycle lasts at most 16.
    reg [7:0] f_cyc_len = 8'd0;
    always @(posedge clk) begin
        if (rst || !m_cyc)
            f_cyc_len <= 8'd0;
        else if (f_cyc_len != 8'hFF)
            f_cyc_len <= f_cyc_len + 1'b1;
    end

    always @(*) begin
        if (f_past_valid && !f_past_rst && !rst) begin
            // Induction: the checkers' counts agree with the state.
            assert (f_m_outstanding == ((state == READ_ACK || state == WRITE_ACK) ? 4'd1 : 4'd0));
            assert (f_s_outstanding == {3'd0, s_ack || s_err});
            assert (state <= WRITE_ACK);
            if (state != READ_ACK && state != WRITE_ACK)
                assert (f_m_waited == 0);

            assert (!(done && error));
            assert (!(busy && (done || error)));

            if (busy) begin
                // The count of bytes left matches the bytes written.
                assert (len != 0);
                assert (f_moved + len == f_len0);
                assert (src == (src_fixed ? f_src0 : f_src0 + f_moved));
                assert (dst == (dst_fixed ? f_dst0 : f_dst0 + f_moved));
                // A word copy never moves a misaligned word.
                if (!bytes)
                    assert (src[1:0] == 2'b00 && dst[1:0] == 2'b00 && len[1:0] == 2'b00);
                // A write comes only after the read of the same unit.
                assert (f_read_done == (state == WRITE || state == WRITE_ACK));
            end

            // A cycle is one read, then one write, and lasts at most 16 clocks.
            assert (f_cyc_len <= 8'd16);
            if (state == READ)
                assert (f_cyc_len < 8'd4);
            if (state == READ_ACK)
                assert (f_cyc_len < 8'd8);
            if (state == WRITE)
                assert (f_cyc_len < 8'd12);
            if (state == WRITE_ACK)
                assert (f_cyc_len < 8'd16);

            // While pacing, the DMA waits with cyc low.
            if (state == WAIT)
                assert (!m_cyc);
        end
    end

    // When a copy finishes, every byte was written.
    reg f_past_busy = 1'b0;
    always @(posedge clk)
        f_past_busy <= !rst && busy;

    always @(*) begin
        if (f_past_valid && !f_past_rst && !rst && f_past_busy && done)
            assert (f_moved == f_len0 && len == 0);
    end

    // ---- These must be reachable ----
    reg [3:0] f_units = 4'd0;   // units copied since the last start
    always @(posedge clk) begin
        if (rst || start)
            f_units <= 4'd0;
        else if (state == WRITE_ACK && m_ack && f_units != 4'hF)
            f_units <= f_units + 1'b1;
    end

    always @(*) begin
        if (f_past_valid && !rst) begin
            cover (done && f_units == 2 && !bytes);                 // two words copied
            cover (done && f_units == 3 && bytes && dst_fixed);     // three bytes to one address
            cover (state == READ_ACK && m_err);                     // a read got err
            cover (state == WRITE_ACK && m_err);                    // a write got err
            cover (state == WAIT && pace && !dreq);                 // waiting for dreq
            cover (busy && s_ack && s_adr == 3'd2);                 // LEN read while busy
            cover (s_err);                                          // a hole in the registers
        end
    end
`endif

endmodule
