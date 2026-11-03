// A direct-mapped instruction cache on the core's native memory interface.
//
// It sits between the core (Tutorial 21) and rv_wb_bridge (Tutorial 26). Both of
// its ports are the native interface: the core's on one side, and on the other a
// port that looks to the bridge exactly like the core.
//
//   cacheable   says that mem_addr is in a region the cache may keep. soc.v works
//               it out from the address: RAM and the XIP flash, not peripherals.
//   invalidate  clears every line, at the next clock edge. A line being filled
//               at that time is not kept either. This is the cache's fence.i.
//
// What it does with each transfer from the core:
//
//   A fetch from a cacheable address is looked up. A hit is answered from the
//   cache, with no transfer on the other side. A miss fills the whole line, in
//   order from its first word, then answers with the word that was asked for.
//   Everything else passes straight through: loads, stores, and fetches from
//   regions that are not cacheable. A pass-through adds no clock.
//
// Stores are not looked at. A store to a word that is in the cache leaves the
// cache's copy as it was, so a program that writes code must write invalidate
// before it runs that code.
//
// Storage. The data and the tags are each a simple dual-port RAM, written the
// way Tutorial 6 wrote sync_ram, so synthesis can put them in block RAM. Their
// reads take a clock: the word read at one edge appears after it. The valid bits
// are flip-flops, because invalidate clears them all in one clock, which a block
// RAM cannot do.
//
// The read latency. The core puts an address on mem_addr at the same edge that
// starts the fetch, so a RAM read of that address is ready one clock later, and
// a hit would take two clocks, no better than a RAM on the bus. So the cache
// guesses. After every fetch it serves, it reads the next word along, pc + 4.
// When the next fetch asks for that word, the tag and data are already out of
// the RAMs, and a hit is answered in the first clock of mem_valid. When it asks
// for another word, after a jump, the cache reads that one, and the hit comes a
// clock later.
//
// Sizes. LINES lines of LINE_WORDS words, both powers of 2, so the cache holds
// 4 * LINES * LINE_WORDS bytes. A byte address splits like this:
//
//   31 ........ 2+IB+WB | 2+WB ..... | 2 ....... | 1 0
//   tag                 | line index | word      | byte, always 0 here
module icache #(
    parameter LINES      = 64,   // a power of 2, at least 2
    parameter LINE_WORDS = 4     // a power of 2, at least 1
) (
    input  wire        clk,
    input  wire        rst,          // synchronous, active high. Clears every line
    // The native interface, from the core
    input  wire        mem_valid,
    input  wire        mem_instr,
    output wire        mem_ready,
    output wire        mem_err,      // from the other side, as rv_wb_bridge gives it
    input  wire [31:0] mem_addr,
    input  wire [31:0] mem_wdata,
    input  wire [3:0]  mem_wstrb,
    output wire [31:0] mem_rdata,
    input  wire        cacheable,    // mem_addr may be kept in the cache
    input  wire        invalidate,   // clear every line
    // The native interface, to rv_wb_bridge
    output wire        d_valid,
    output wire        d_instr,
    input  wire        d_ready,
    input  wire        d_err,
    output wire [31:0] d_addr,
    output wire [31:0] d_wdata,
    output wire [3:0]  d_wstrb,
    input  wire [31:0] d_rdata,
    // One clock each, for counters: a cacheable fetch was found, or not
    output wire        hit,
    output wire        miss
);

    localparam WB = $clog2(LINE_WORDS);   // bits of word within a line
    localparam IB = $clog2(LINES);        // bits of line index
    localparam AB = IB + WB;              // bits of word within the cache
    localparam TB = 30 - AB;              // bits of tag
    localparam [AB-1:0] WORD_MASK = LINE_WORDS - 1;

    localparam [1:0] S_IDLE   = 2'd0;   // looking up, or passing through
    localparam [1:0] S_FILL   = 2'd1;   // reading the line from the other side
    localparam [1:0] S_DONE   = 2'd2;   // the line is in: answer the fetch
    localparam [1:0] S_FAILED = 2'd3;   // a fill got err: wait for mem_valid to fall

    reg [1:0] state;

    // ----- The address the core asks for -----

    wire [AB-1:0] want_word = mem_addr[2 +: AB];         // its word in the data RAM
    wire [IB-1:0] want_line = want_word[AB-1 -: IB];
    wire [TB-1:0] want_tag  = mem_addr[31 -: TB];

    // ----- The RAMs, in Tutorial 6's style -----

    reg [31:0]    data_mem [0:LINES*LINE_WORDS-1];
    reg [TB-1:0]  tag_mem  [0:LINES-1];
    reg [LINES-1:0] valid;

    wire [AB-1:0] ra;          // the word to read at this edge
    reg  [AB-1:0] ra_q;        // the word data_q and tag_q came from
    reg  [31:0]   data_q;
    reg  [TB-1:0] tag_q;
    reg           fresh;       // nothing was written at the edge that read them

    wire          data_we;
    reg  [AB-1:0] fill_word;   // the word being filled
    wire          tag_we;

    always @(posedge clk) begin
        if (data_we)
            data_mem[fill_word] <= d_rdata;
        data_q <= data_mem[ra];
    end

    always @(posedge clk) begin
        if (tag_we)
            tag_mem[want_line] <= want_tag;
        tag_q <= tag_mem[ra[AB-1 -: IB]];
    end

    // ----- Looking up -----

    wire idle      = state == S_IDLE;
    wire use_cache = mem_valid && mem_instr && cacheable;
    wire looked    = fresh && ra_q == want_word;   // the RAMs show this word now
    wire found     = valid[want_line] && tag_q == want_tag;

    assign hit  = idle && use_cache && looked && found;
    assign miss = idle && use_cache && looked && !found;

    wire pass      = idle && mem_valid && !use_cache;
    wire filling   = state == S_FILL;
    wire fill_last = (fill_word & WORD_MASK) == WORD_MASK;

    assign data_we = filling && d_ready && !d_err;
    assign tag_we  = miss;

    // After a fetch is answered, read the next word along. A fetch that was not
    // guessed reads its own word. Otherwise read the same word again, which
    // keeps data_q and tag_q up to date.
    assign ra = (hit || state == S_DONE)     ? want_word + 1'b1 :
                (idle && use_cache && !looked) ? want_word :
                                                 ra_q;

    // ----- The two ports -----

    reg [31:0] word_q;        // the word the fetch asked for, caught during the fill

    assign d_valid = pass || filling;
    assign d_instr = filling ? 1'b1 : mem_instr;
    assign d_addr  = filling ? {mem_addr[31:2+AB], fill_word, 2'b00} : mem_addr;
    assign d_wstrb = filling ? 4'd0 : mem_wstrb;
    assign d_wdata = mem_wdata;

    assign mem_ready = hit || state == S_DONE || (pass && d_ready);
    assign mem_err   = (pass || filling) && d_err;
    assign mem_rdata = (state == S_DONE) ? word_q :
                       pass              ? d_rdata :
                                           data_q;

    // ----- Control -----

    reg cancel;   // invalidate came during this fill: do not keep the line

    always @(posedge clk) begin
        ra_q  <= rst ? {AB{1'b0}} : ra;
        fresh <= !rst && !data_we && !tag_we;

        if (filling && d_ready && fill_word == want_word)
            word_q <= d_rdata;

        if (rst) begin
            state     <= S_IDLE;
            valid     <= {LINES{1'b0}};
            fill_word <= {AB{1'b0}};
            cancel    <= 1'b0;
        end else begin
            if (invalidate)
                valid <= {LINES{1'b0}};

            case (state)
                S_IDLE:
                    if (miss) begin
                        // The tag is written now, so the line is not valid
                        // until every word has arrived.
                        state            <= S_FILL;
                        fill_word        <= want_word & ~WORD_MASK;
                        valid[want_line] <= 1'b0;
                        cancel           <= invalidate;
                    end

                S_FILL: begin
                    if (invalidate)
                        cancel <= 1'b1;
                    if (d_err) begin
                        state <= S_FAILED;
                    end else if (d_ready) begin
                        fill_word <= fill_word + 1'b1;
                        if (fill_last) begin
                            state <= S_DONE;
                            if (!cancel && !invalidate)
                                valid[want_line] <= 1'b1;
                        end
                    end
                end

                S_DONE:
                    state <= S_IDLE;

                default:   // S_FAILED: Tutorial 21's core waits forever here
                    if (!mem_valid)
                        state <= S_IDLE;
            endcase
        end
    end

    // Bits 1 and 0 of the address are always 0, by the core's rules.
    wire unused = &{1'b0, mem_addr[1:0]};

`ifdef FORMAL
    // ===== The rules around the cache =====

    reg f_past_valid = 1'b0;
    always @(posedge clk)
        f_past_valid <= 1'b1;

    // The proof starts in reset.
    always @(*)
        if (!f_past_valid)
            assume (rst);

    // The core's side: Tutorial 21's rules, assumed, as in rv_wb_bridge. mem_valid
    // is low on the clock after reset. Once high, it stays high, and the request
    // stays still, until mem_ready or mem_err. A fetch is a read. cacheable
    // depends only on the address, so it holds still too.
    reg        f_past_rst = 1'b1;
    reg        f_past_wait = 1'b0;
    reg        f_past_instr, f_past_cacheable;
    reg [31:0] f_past_addr, f_past_wdata;
    reg [3:0]  f_past_wstrb;
    always @(posedge clk) begin
        f_past_rst       <= rst;
        f_past_wait      <= !rst && mem_valid && !mem_ready && !mem_err;
        f_past_instr     <= mem_instr;
        f_past_cacheable <= cacheable;
        f_past_addr      <= mem_addr;
        f_past_wdata     <= mem_wdata;
        f_past_wstrb     <= mem_wstrb;
    end

    always @(*) begin
        if (f_past_valid && f_past_rst)
            assume (!mem_valid);
        if (f_past_valid && f_past_wait && !rst)
            assume (mem_valid && mem_instr == f_past_instr && mem_addr == f_past_addr
                    && mem_wdata == f_past_wdata && mem_wstrb == f_past_wstrb
                    && cacheable == f_past_cacheable);
        assume (mem_addr[1:0] == 2'b00);
        if (mem_instr)
            assume (mem_wstrb == 4'd0);
    end

    // The other side: what rv_wb_bridge promises, which Tutorial 26 proved. An
    // answer only to a request, and never ready and err together.
    always @(*) begin
        if (!d_valid || rst)
            assume (!d_ready && !d_err);
        assume (!(d_ready && d_err));
    end

    // ===== The memory behind the cache, for one word =====

    // The solver picks one word address. f_mem is what the memory holds there:
    // any value at the start, and changed by every store that reaches it. A read
    // of that word on the other side returns f_mem.
    (* anyconst *) reg [29:0] f_word;
    reg [31:0] f_mem;

    wire f_down    = d_valid && d_ready;                 // a transfer on the other side
    wire f_at_word = d_addr[31:2] == f_word;
    integer f_k;

    always @(posedge clk)
        if (f_down && d_wstrb != 4'd0 && f_at_word)
            for (f_k = 0; f_k < 4; f_k = f_k + 1)
                if (d_wstrb[f_k])
                    f_mem[8*f_k +: 8] <= d_wdata[8*f_k +: 8];

    always @(*)
        if (f_down && d_wstrb == 4'd0 && f_at_word)
            assume (d_rdata == f_mem);

    // f_stale: the word was written since the last invalidate, and since the last
    // time a fill read it. Only then may the cache return an old copy.
    reg f_stale = 1'b0;
    always @(posedge clk) begin
        if (rst)
            f_stale <= 1'b0;
        else if (f_down && d_wstrb != 4'd0 && f_at_word)
            f_stale <= 1'b1;
        else if (invalidate || (filling && f_down && f_at_word))
            f_stale <= 1'b0;
    end

    // ===== What the cache promises =====

    // Where the watched word lives in the cache.
    wire [AB-1:0] f_slot = f_word[AB-1:0];
    wire [IB-1:0] f_line = f_word[AB-1:WB];
    wire [TB-1:0] f_tag  = f_word[29 -: TB];

    always @(*) begin
        if (f_past_valid && !rst) begin
            // THE PROPERTY. Every word the cache returns for a fetch is the memory's
            // word at that address, unless the word was written since its line was
            // filled and there has been no invalidate since.
            if (mem_valid && mem_ready && mem_instr && mem_addr[31:2] == f_word && !f_stale)
                assert (mem_rdata == f_mem);

            // The same for loads, which always pass through.
            if (mem_valid && mem_ready && !mem_instr && mem_wstrb == 4'd0
                && mem_addr[31:2] == f_word)
                assert (mem_rdata == f_mem);
        end
    end

    // ----- The native interface on both ports -----

    reg        f_dpast_wait = 1'b0;
    reg        f_dpast_instr;
    reg [31:0] f_dpast_addr, f_dpast_wdata;
    reg [3:0]  f_dpast_wstrb;
    always @(posedge clk) begin
        f_dpast_wait  <= !rst && d_valid && !d_ready && !d_err;
        f_dpast_instr <= d_instr;
        f_dpast_addr  <= d_addr;
        f_dpast_wdata <= d_wdata;
        f_dpast_wstrb <= d_wstrb;
    end

    always @(*) begin
        if (f_past_valid && !rst) begin
            // To the core: an answer only to a request, and one answer at a time.
            if (mem_ready || mem_err)
                assert (mem_valid);
            assert (!(mem_ready && mem_err));

            // To the bridge: Tutorial 21's rules, as the core keeps them.
            if (f_past_rst)
                assert (!d_valid);
            if (f_dpast_wait)
                assert (d_valid && d_instr == f_dpast_instr && d_addr == f_dpast_addr
                        && d_wdata == f_dpast_wdata && d_wstrb == f_dpast_wstrb);
            assert (d_addr[1:0] == 2'b00);
            if (d_instr)
                assert (d_wstrb == 4'd0);

            // Only cacheable fetches are cached. Anything else passes through
            // unchanged, and its answer comes straight back.
            if (mem_valid && !(mem_instr && cacheable)) begin
                assert (!hit && !miss && (idle || state == S_FAILED));
                if (idle)
                    assert (d_valid && d_addr == mem_addr && d_wstrb == mem_wstrb
                            && d_wdata == mem_wdata && d_instr == mem_instr
                            && mem_ready == d_ready && mem_err == d_err);
            end
            // A fill reads the line of the fetch, and nothing else goes out.
            if (filling)
                assert (d_valid && d_wstrb == 4'd0 && d_instr
                        && d_addr[31:2+WB] == mem_addr[31:2+WB]);
            // A hit makes no transfer on the other side.
            if (hit)
                assert (!d_valid);
        end
    end

    // ----- Inside, so that induction can succeed -----

    always @(*) begin
        if (f_past_valid && !f_past_rst && !rst) begin
            // While the cache works on a fetch, the core is still waiting for it.
            if (state == S_FILL || state == S_DONE)
                assert (f_past_wait && mem_valid && mem_instr && cacheable);
            // The line being filled has its new tag already, and is not valid yet.
            if (state == S_FILL)
                assert (tag_mem[want_line] == want_tag && !valid[want_line]
                        && fill_word[AB-1 -: IB] == want_line);
            if (state == S_DONE)
                assert (tag_mem[want_line] == want_tag);
            // The read registers show the RAMs, unless something was written.
            if (fresh)
                assert (data_q == data_mem[ra_q] && tag_q == tag_mem[ra_q[AB-1 -: IB]]);
            // A fill that has read the watched word left it fresh: nothing writes
            // memory while the core waits for a fill.
            if (filling && mem_addr[31:2+WB] == f_word[29:WB] && fill_word > f_slot)
                assert (!f_stale);
            if (state == S_DONE && mem_addr[31:2+WB] == f_word[29:WB])
                assert (!f_stale);
        end

        if (f_past_valid && !rst && !f_stale) begin
            // A valid line holding the watched word holds the memory's value.
            if (valid[f_line] && tag_mem[f_line] == f_tag)
                assert (data_mem[f_slot] == f_mem);
            // During a fill of that line, once the word has been written.
            if (filling && mem_addr[31:2+WB] == f_word[29:WB] && fill_word > f_slot)
                assert (data_mem[f_slot] == f_mem);
            if ((filling || state == S_DONE) && mem_addr[31:2] == f_word
                && (state == S_DONE || fill_word > f_slot))
                assert (word_q == f_mem);
        end
    end

    // ----- Covers, so that no proof above is empty -----

    reg f_seen_fill = 1'b0;      // a line has been filled since reset
    reg f_seen_stale = 1'b0;     // the watched word went stale, and then invalidate came
    reg f_hit_q = 1'b0;
    always @(posedge clk) begin
        f_hit_q <= !rst && hit;
        if (rst)
            f_seen_fill <= 1'b0;
        else if (state == S_DONE)
            f_seen_fill <= 1'b1;
        if (rst)
            f_seen_stale <= 1'b0;
        else if (f_stale && invalidate)
            f_seen_stale <= 1'b1;
    end

    always @(*) begin
        if (f_past_valid && !rst) begin
            cover (state == S_DONE);                               // a miss, filled
            cover (hit && mem_addr[31:2] == f_word);               // a hit on the word
            cover (hit && f_hit_q);                                // two hits in a row
            cover (hit && fresh && ra_q == want_word && f_seen_fill
                   && f_past_wait == 1'b0);                        // a hit in the first clock
            cover ((hit || state == S_DONE) && mem_addr[31:2] == f_word
                   && f_seen_stale && !f_stale);                   // fresh again after invalidate
            cover (hit && mem_addr[31:2] == f_word
                   && f_stale && mem_rdata != f_mem);              // a stale word returned
            cover (filling && invalidate);                         // invalidate during a fill
            cover (state == S_FAILED);                             // a fill got err
            cover (pass && d_ready && d_wstrb != 4'd0);            // a store passed through
            cover (pass && d_ready && mem_instr);                  // a fetch not cached
        end
    end
`endif

endmodule
