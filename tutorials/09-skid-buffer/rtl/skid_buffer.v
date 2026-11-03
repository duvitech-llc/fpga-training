// Registered skid buffer between two valid/ready interfaces. A word moves when
// valid and ready are both high at a rising edge. m_valid, m_data and s_ready
// all come from flip-flops, so no combinational path joins m_ready to s_ready,
// and one word can still pass per clock.
module skid_buffer #(
    parameter WIDTH = 8
) (
    input  wire             clk,
    input  wire             rst,      // synchronous, active high, discards stored words
    input  wire             s_valid,  // upstream is offering s_data
    output reg              s_ready,  // this buffer takes s_data at the next rising edge
    input  wire [WIDTH-1:0] s_data,
    output reg              m_valid,  // m_data holds a word for downstream
    input  wire             m_ready,  // downstream takes m_data at the next rising edge
    output reg  [WIDTH-1:0] m_data
);

    reg             skid_valid;  // skid_data holds the word that arrived during a stall
    reg [WIDTH-1:0] skid_data;

    wire s_xfer;  // a word enters at this edge
    wire m_free;  // the output register can load at this edge

    assign s_xfer = s_valid && s_ready;
    assign m_free = !m_valid || m_ready;

    always @(posedge clk) begin
        if (rst) begin
            m_valid    <= 1'b0;
            skid_valid <= 1'b0;
            s_ready    <= 1'b0;
        end else if (m_free) begin
            // The stored word goes first, because it arrived first.
            if (skid_valid)
                m_data <= skid_data;
            else if (s_xfer)
                m_data <= s_data;
            m_valid    <= skid_valid || s_xfer;
            skid_valid <= 1'b0;
            s_ready    <= 1'b1;
        end else if (s_xfer) begin
            // The output is stalled, and s_ready was already high. This word
            // has nowhere else to go, so it skids into the second register.
            skid_data  <= s_data;
            skid_valid <= 1'b1;
            s_ready    <= 1'b0;
        end
    end

`ifdef FORMAL
    // $past needs one clock of history before it is meaningful.
    reg past_valid = 1'b0;
    always @(posedge clk)
        past_valid <= 1'b1;

    // Without this the solver may start with both registers full of nonsense.
    always @(posedge clk) begin
        if (!past_valid)
            assume (rst);
    end

    // ASSUME at the inputs: upstream keeps the rules. Reset is the one excuse
    // for dropping a word that was on offer. m_ready needs no assumption, since
    // downstream may do anything at all.
    always @(posedge clk) begin
        if (past_valid && !rst && !$past(rst) && $past(s_valid) && !$past(s_ready)) begin
            assume (s_valid);
            assume (s_data == $past(s_data));
        end
    end

    // ASSERT at the outputs: this buffer keeps the same rules for downstream.
    always @(posedge clk) begin
        if (past_valid) begin
            if ($past(rst)) begin
                assert (!m_valid);
                assert (!skid_valid);
                assert (!s_ready);
            end else begin
                // A stalled word stays, unchanged, until it is accepted.
                if ($past(m_valid) && !$past(m_ready)) begin
                    assert (m_valid);
                    assert (m_data == $past(m_data));
                end

                // An accepted word is on offer at once: valid never waits for ready.
                if ($past(s_valid) && $past(s_ready))
                    assert (m_valid);

                // A clock with m_ready high leaves s_ready high, for full throughput.
                if ($past(m_ready))
                    assert (s_ready);
            end

            // The skid register is only used while the output register is full.
            if (skid_valid) begin
                assert (m_valid);
                assert (!s_ready);
            end
        end
    end

    wire accepted;   // a word entered the buffer
    wire delivered;  // a word left the buffer
    assign accepted  = !rst && s_valid && s_ready;
    assign delivered = !rst && m_valid && m_ready;

    // These must be reachable. If one fails, an assumption has ruled it out.
    always @(posedge clk) begin
        if (past_valid && !rst) begin
            cover (skid_valid && m_ready);                // the skid register empties
            cover (accepted && m_valid && !m_ready);      // the skid register loads
            cover ($past(accepted) && $past(delivered) && accepted && delivered);
        end
    end

`ifdef CHECK_DATA
    // Words inside the buffer: accepted minus delivered, counted from the ports.
    reg [1:0] count;
    always @(posedge clk) begin
        if (rst)
            count <= 0;
        else
            count <= count + accepted - delivered;
    end

    // The solver tags any one accepted word that it likes, and tag_ahead counts
    // the words in front of it. Since the tagged word can be any word, proving
    // this one arrives in its place proves it for all of them.
    wire             pick = $anyseq;
    reg              tagged;
    reg              tag_ahead;
    reg  [WIDTH-1:0] tag_data;

    always @(posedge clk) begin
        if (rst) begin
            tagged <= 1'b0;
        end else if (!tagged) begin
            if (accepted && pick) begin
                tagged    <= 1'b1;
                tag_data  <= s_data;
                tag_ahead <= (count - delivered) != 0;
            end
        end else if (delivered) begin
            if (tag_ahead)
                tag_ahead <= 1'b0;
            else
                tagged <= 1'b0;
        end
    end

    always @(posedge clk) begin
        if (past_valid) begin
            // Nothing lost or invented: what went in and did not come out is stored.
            assert (count <= 2);
            assert (count == m_valid + skid_valid);

            // Nothing corrupted, duplicated or reordered: the tagged word is
            // always in the register that its place in the queue says.
            if (tagged) begin
                if (tag_ahead)
                    assert (skid_valid && skid_data == tag_data);
                else
                    assert (m_valid && m_data == tag_data);
            end
        end
    end
`endif
`endif

endmodule
