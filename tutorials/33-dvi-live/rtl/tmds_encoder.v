// TMDS encoder: one channel of DVI 1.0. Each pixel clock it turns 8 bits of
// colour, or 2 control bits during blanking, into a 10-bit character.
//
// While de is high, the byte goes through two steps, as the DVI 1.0 spec's
// flow chart has them:
//
//   1. Transition minimisation. q_m[0] = d[0], and each next bit is the last
//      one XORed, or XNORed, with the next bit of d. XNOR is chosen when d has
//      more than four 1s, or exactly four and d[0] is 0. That choice gives
//      fewer changes of level along the wire. q_m[8] says which was used:
//      1 for XOR, 0 for XNOR.
//   2. DC balance. cnt is the running disparity: 1s minus 0s sent since the
//      last blanking. If the new character would push cnt further from 0, its
//      low 8 bits are sent inverted, and q[9] says so. A receiver undoes both.
//
// While de is low, q is one of four control tokens, chosen by c = {C1, C0}, and
// cnt goes back to 0. The tokens have many changes of level, unlike any data
// character, so a receiver can find where each character starts from them.
//
// q is registered: it is the character for the inputs of the clock before.
// Bit 0 is sent first. cnt only ever holds even values from -8 to 8, so 5
// bits are enough; the proof below shows the bound.
module tmds_encoder (
    input  wire       clk,       // the pixel clock
    input  wire       rst,       // synchronous, active high
    input  wire       de,        // 1: d is a pixel. 0: blanking, send c
    input  wire [7:0] d,
    input  wire [1:0] c,         // {C1, C0}
    output reg  [9:0] q          // the character, bit 0 first on the wire
);

    // The four control tokens of DVI 1.0, written q[9:0].
    localparam [9:0] CTRL_00 = 10'b1101010100;
    localparam [9:0] CTRL_01 = 10'b0010101011;
    localparam [9:0] CTRL_10 = 10'b0101010100;
    localparam [9:0] CTRL_11 = 10'b1010101011;

    function [3:0] ones8(input [7:0] v);
        integer k;
        begin
            ones8 = 4'd0;
            for (k = 0; k < 8; k = k + 1)
                ones8 = ones8 + {3'd0, v[k]};
        end
    endfunction

    // ----- Step 1: transition minimisation -----

    wire [3:0] d_ones   = ones8(d);
    wire       use_xnor = (d_ones > 4'd4) || (d_ones == 4'd4 && !d[0]);

    reg  [8:0] q_m;
    integer i;
    always @(*) begin
        q_m[0] = d[0];
        for (i = 1; i < 8; i = i + 1)
            q_m[i] = use_xnor ? !(q_m[i-1] ^ d[i]) : (q_m[i-1] ^ d[i]);
        q_m[8] = !use_xnor;
    end

    // ----- Step 2: DC balance -----

    // 1s minus 0s in q_m[7:0]: 2 * ones - 8, from -8 to 8.
    wire [3:0]        m_ones = ones8(q_m[7:0]);
    wire signed [4:0] m_disp = $signed({m_ones, 1'b0}) - 5'sd8;
    // 2 * q_m[8] and 2 * !q_m[8], for the corrections the flow chart adds.
    wire signed [4:0] two_q8  = q_m[8] ? 5'sd2 : 5'sd0;
    wire signed [4:0] two_nq8 = q_m[8] ? 5'sd0 : 5'sd2;

    reg signed [4:0] cnt;

    always @(posedge clk) begin
        if (rst) begin
            q   <= CTRL_00;
            cnt <= 5'sd0;
        end else if (!de) begin
            cnt <= 5'sd0;
            case (c)
                2'b00:   q <= CTRL_00;
                2'b01:   q <= CTRL_01;
                2'b10:   q <= CTRL_10;
                default: q <= CTRL_11;
            endcase
        end else if (cnt == 5'sd0 || m_ones == 4'd4) begin
            // No disparity to correct, or none to add: invert only after XNOR,
            // so q[9] is always the opposite of q[8].
            q   <= {!q_m[8], q_m[8], q_m[8] ? q_m[7:0] : ~q_m[7:0]};
            cnt <= q_m[8] ? cnt + m_disp : cnt - m_disp;
        end else if ((cnt > 5'sd0 && m_ones > 4'd4) || (cnt < 5'sd0 && m_ones < 4'd4)) begin
            // Sending q_m as it is would move further from 0: invert it.
            q   <= {1'b1, q_m[8], ~q_m[7:0]};
            cnt <= cnt + two_q8 - m_disp;
        end else begin
            q   <= {1'b0, q_m[8], q_m[7:0]};
            cnt <= cnt - two_nq8 + m_disp;
        end
    end

`ifdef FORMAL
    // A decoder written from the DVI 1.0 decode flow chart, not from the code
    // above, and a count of the disparity actually sent.
    reg f_past_valid = 1'b0;
    always @(posedge clk)
        f_past_valid <= 1'b1;

    always @(*)
        if (!f_past_valid)
            assume (rst);

    function f_is_token(input [9:0] w);
        f_is_token = w == CTRL_00 || w == CTRL_01 || w == CTRL_10 || w == CTRL_11;
    endfunction

    function [1:0] f_token(input [9:0] w);
        f_token = (w == CTRL_00) ? 2'b00 : (w == CTRL_01) ? 2'b01 :
                  (w == CTRL_10) ? 2'b10 : 2'b11;
    endfunction

    // Undo the inversion that q[9] marks, then the XOR or XNOR that q[8] marks.
    function [7:0] f_decode(input [9:0] w);
        reg [7:0] v;
        integer k;
        begin
            v = w[9] ? ~w[7:0] : w[7:0];
            f_decode[0] = v[0];
            for (k = 1; k < 8; k = k + 1)
                f_decode[k] = w[8] ? (v[k] ^ v[k-1]) : !(v[k] ^ v[k-1]);
        end
    endfunction

    // 1s minus 0s in a whole character.
    function signed [5:0] f_disp10(input [9:0] w);
        integer k;
        begin
            f_disp10 = -6'sd10;
            for (k = 0; k < 10; k = k + 1)
                if (w[k])
                    f_disp10 = f_disp10 + 6'sd2;
        end
    endfunction

    // The inputs of the clock before, which q now encodes.
    reg       f_de;
    reg [7:0] f_d;
    reg [1:0] f_c;
    reg       f_rst = 1'b1;
    always @(posedge clk) begin
        f_de  <= de;
        f_d   <= d;
        f_c   <= c;
        f_rst <= rst;
    end

    // The disparity of the characters sent since the last control token, up to
    // and including q, counted from the wire.
    reg  signed [7:0] f_run = 8'sd0;   // up to the character before q
    wire signed [5:0] f_dq = f_disp10(q);
    wire signed [7:0] f_run_now = f_is_token(q) ? 8'sd0 : f_run + {{2{f_dq[5]}}, f_dq};
    always @(posedge clk)
        f_run <= rst ? 8'sd0 : f_run_now;

    always @(*) begin
        if (f_past_valid && !f_rst) begin
            if (f_de) begin
                // A data character is never a control token, and decodes back
                // to the byte, whatever cnt was.
                assert (!f_is_token(q));
                assert (f_decode(q) == f_d);
            end else begin
                assert (q == (f_c == 2'b00 ? CTRL_00 : f_c == 2'b01 ? CTRL_01 :
                              f_c == 2'b10 ? CTRL_10 : CTRL_11));
                assert (f_token(q) == f_c);
            end
        end
        if (f_past_valid) begin
            // The bound: cnt is even and never beyond 8 either way.
            assert (cnt >= -5'sd8 && cnt <= 5'sd8);
            assert (!cnt[0]);
            // cnt is exactly the disparity on the wire since the last blanking.
            assert ({{3{cnt[4]}}, cnt} == f_run_now);
        end
    end

    // The bound is reached, both ways, so 8 is the smallest bound that holds.
    always @(*) begin
        if (f_past_valid && !rst) begin
            cover (cnt == 5'sd8);
            cover (cnt == -5'sd8);
            cover (f_past_valid && !f_rst && !f_de && f_c == 2'b11);
        end
    end
`endif

endmodule
