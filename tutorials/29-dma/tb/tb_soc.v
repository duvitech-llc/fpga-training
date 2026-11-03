`timescale 1ns/1ps

// Runs every program on the whole system, the core and the DMA engine sharing the
// bus, and judges each one by what comes out: the bytes on uart_tx, decoded at bit
// level as in Tutorial 19, how it stopped, and what is in RAM at the end. Inputs
// change on the falling edge.
//
// Each program runs twice. Mode 0 holds every slave's hold input low. Mode 1 drives
// them from a pseudo-random sequence, so every slave stalls at random, and every
// program must still print what it should and stop the same way.
//
// Programs that print clock counts are checked against the testbench's own count
// of clocks between the same two reads of the cycles counter. Programs that print
// how many bytes the DMA engine moved are checked against the testbench's own
// count of the engine's write answers between the same two reads of LEN.
//
// It also watches the arbiter: for each master, how many cycles it was granted,
// its longest cycle, and its longest wait for the bus.
module tb_soc #(
    parameter CLKS_PER_BIT = 16
);

    localparam integer TIMEOUT    = 500000;    // clocks for one program
    localparam integer FRAME      = 10 * CLKS_PER_BIT;
    localparam integer MAX_OUTPUT = 1024;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg uart_rx = 1'b1;
    reg [7:0] hold = 8'd0;

    wire        uart_tx, trap, retire;
    wire [3:0]  trap_cause;
    wire [31:0] gpio_out, retire_pc, retire_instr;
    wire        dma_busy, dma_done, dma_error;

    soc #(.CLKS_PER_BIT(CLKS_PER_BIT)) dut (
        .clk(clk), .rst(rst), .uart_rx(uart_rx), .uart_tx(uart_tx), .gpio_out(gpio_out),
        .trap(trap), .trap_cause(trap_cause),
        .retire(retire), .retire_pc(retire_pc), .retire_instr(retire_instr),
        .dma_busy(dma_busy), .dma_done(dma_done), .dma_error(dma_error),
        .hold(hold)
    );

    always #5 clk = ~clk;

    integer errors = 0;
    integer mode = 0;
    integer n;
    reg     dumping   = 1'b0;   // the waveform window is open: see dump_from_here
    reg     dump_next = 1'b0;

    // ----- Random stalls, the same in both simulators -----

    reg [31:0] random = 32'h2545F491;   // xorshift32

    function [31:0] next_random(input [31:0] r);
        reg [31:0] s;
        begin
            s = r ^ (r << 13);
            s = s ^ (s >> 17);
            next_random = s ^ (s << 5);
        end
    endfunction

    always @(negedge clk) begin
        random = next_random(random);
        // Each slave stalls on about one clock in four.
        hold <= (mode == 1) ? (random[7:0] & random[15:8]) : 8'd0;
    end

    // ----- The UART decoder: uart_tx back to bytes, every clock of every bit checked -----

    reg [7:0] out [0:MAX_OUTPUT-1];
    integer   out_count = 0;
    integer   frame_bit = -1;   // -1 is idle, 0 is the start bit, 9 is the stop bit
    integer   bit_clock = 0;
    reg       bit_level = 1'b1;
    reg [7:0] frame_data = 8'd0;

    always @(posedge clk) begin
        if (rst) begin
            frame_bit = -1;
            bit_clock = 0;
        end else if (frame_bit == -1) begin
            if (uart_tx === 1'b0) begin
                frame_bit = 0;
                bit_clock = 1;
                bit_level = 1'b0;
            end
        end else begin
            if (bit_clock == 0)
                bit_level = uart_tx;
            else if (uart_tx !== bit_level) begin
                $display("FAIL t=%0t uart_tx changed inside bit %0d", $time, frame_bit);
                errors = errors + 1;
            end
            bit_clock = bit_clock + 1;
        end

        if (frame_bit != -1 && bit_clock == CLKS_PER_BIT) begin
            if (frame_bit >= 1 && frame_bit <= 8)
                frame_data[frame_bit - 1] = bit_level;
            if (frame_bit == 9) begin
                if (bit_level !== 1'b1) begin
                    $display("FAIL t=%0t stop bit on uart_tx is low", $time);
                    errors = errors + 1;
                end
                if (out_count < MAX_OUTPUT)
                    out[out_count] = frame_data;
                out_count = out_count + 1;
                frame_bit = -1;
            end else begin
                frame_bit = frame_bit + 1;
            end
            bit_clock = 0;
        end
    end

    // ----- What the programs read, and what the testbench counts itself -----

    // A request taken by a slave at this edge: the interconnect's slave side.
    wire slave_take = dut.s_cyc && !dut.s_we;
    wire counter_read = slave_take && dut.s_stb[3] && !dut.s_stall[3] && dut.s_adr[0] == 1'b0;
    wire len_read     = slave_take && dut.s_stb[5] && !dut.s_stall[5] && dut.s_adr[2:0] == 3'd2;
    wire status_read  = slave_take && dut.s_stb[5] && !dut.s_stall[5] && dut.s_adr[2:0] == 3'd4;
    // A DMA write answered at this edge: the unit is copied, and LEN goes down.
    wire dma_wrote    = dut.u_dma.state == 3'd5 && dut.dma_ack;

    integer clocks_since_reset = 0;
    integer dma_bytes = 0;           // bytes the DMA engine has written since reset
    integer status_reads = 0;        // reads of STATUS since reset

    integer cycle_at  [0:31];        // clocks_since_reset at each read of cycles
    integer status_at [0:31];        // status_reads at each read of cycles
    integer bytes_at  [0:31];        // dma_bytes at each read of LEN
    integer cycle_reads = 0;
    integer len_reads = 0;

    always @(posedge clk) begin
        if (rst) begin
            clocks_since_reset = 0;
            dma_bytes = 0;
            status_reads = 0;
            cycle_reads = 0;
            len_reads = 0;
        end else begin
            // Each read sees the count before this edge adds to it, as the
            // counters and LEN do.
            if (counter_read) begin
                if (cycle_reads < 32) begin
                    cycle_at[cycle_reads]  = clocks_since_reset;
                    status_at[cycle_reads] = status_reads;
                end
                cycle_reads = cycle_reads + 1;
            end
            if (len_read) begin
                if (len_reads < 32)
                    bytes_at[len_reads] = dma_bytes;
                len_reads = len_reads + 1;
            end
            if (status_read)
                status_reads = status_reads + 1;
            if (dma_wrote)
                dma_bytes = dma_bytes + (dut.u_dma.bytes ? 1 : 4);
            clocks_since_reset = clocks_since_reset + 1;
        end
    end

    // ----- The arbiter, watched -----

    // For each master: cycles granted, the longest cycle, and the longest wait.
    integer grants   [0:3];          // index 2 * mode + master
    integer longest  [0:3];
    integer max_wait [0:3];
    integer run_len  [0:1];          // clocks the current owner has held cyc
    integer wait_len [0:1];          // clocks a master has waited with cyc high
    wire [1:0] arb_cyc   = {dut.dma_cyc, dut.cpu_cyc};
    wire [1:0] arb_grant = dut.u_arbiter.grant;
    integer m;

    always @(posedge clk) begin
        if (rst) begin
            run_len[0] = 0;
            run_len[1] = 0;
            wait_len[0] = 0;
            wait_len[1] = 0;
        end else begin
            for (m = 0; m < 2; m = m + 1) begin
                if (arb_cyc[m] && arb_grant[m]) begin
                    if (run_len[m] == 0)
                        grants[2 * mode + m] = grants[2 * mode + m] + 1;
                    run_len[m] = run_len[m] + 1;
                    if (run_len[m] > longest[2 * mode + m])
                        longest[2 * mode + m] = run_len[m];
                end else begin
                    run_len[m] = 0;
                end
                if (arb_cyc[m] && !arb_grant[m]) begin
                    wait_len[m] = wait_len[m] + 1;
                    if (wait_len[m] > max_wait[2 * mode + m])
                        max_wait[2 * mode + m] = wait_len[m];
                end else begin
                    wait_len[m] = 0;
                end
            end
            // Never two owners, and never a request from a master without the bus.
            if (arb_grant == 2'b11) begin
                $display("FAIL t=%0t both masters granted", $time);
                errors = errors + 1;
            end
            if (dut.m_stb && !(|(arb_grant & arb_cyc))) begin
                $display("FAIL t=%0t a request on the bus with no owner", $time);
                errors = errors + 1;
            end
        end
    end

    // ----- Running one program -----

    reg [8*24-1:0] current;          // the program's name, for messages

    task load_and_run(input [8*24-1:0] name, input [8*32-1:0] hex);
        integer clocks;
        begin
            current = name;
            @(negedge clk);
            rst = 1'b1;
            $readmemh(hex, dut.u_ram.mem);
            out_count = 0;
            @(negedge clk);
            @(negedge clk);
            rst = 1'b0;
            if (dump_next) begin
                $dumpon;
                dumping   = 1'b1;
                dump_next = 1'b0;
            end
            clocks = 0;
            while (trap !== 1'b1 && clocks < TIMEOUT) begin
                @(negedge clk);
                clocks = clocks + 1;
            end
            if (trap !== 1'b1) begin
                $display("FAIL %0s: no trap after %0d clocks", name, TIMEOUT);
                errors = errors + 1;
            end
            // Let the UART finish the frame it may be sending.
            repeat (2 * FRAME) @(negedge clk);
        end
    endtask

    // The output as text, for messages.
    function automatic string output_text;
        string s;
        integer i;
        begin
            s = "";
            for (i = 0; i < out_count && i < MAX_OUTPUT; i = i + 1)
                if (out[i] == 8'h0A)
                    s = {s, "\\n"};
                else
                    s = $sformatf("%0s%c", s, out[i]);
            output_text = s;
        end
    endfunction

    // The output as it was printed, newlines and all.
    task show_output;
        begin
            for (n = 0; n < out_count && n < MAX_OUTPUT; n = n + 1)
                $write("%c", out[n]);
        end
    endtask

    // Is want in the output, starting at or after from? Returns where it ends, or -1.
    function automatic integer find(input string want, input integer from);
        integer i, j;
        reg     match;
        begin
            find = -1;
            for (i = from; i + want.len() <= out_count && find < 0; i = i + 1) begin
                match = 1'b1;
                for (j = 0; j < want.len(); j = j + 1)
                    if (out[i + j] != want[j])
                        match = 1'b0;
                if (match)
                    find = i + want.len();
            end
        end
    endfunction

    // The output must be exactly want.
    task expect_output(input string want);
        begin
            if (out_count != want.len() || find(want, 0) != want.len()) begin
                $display("FAIL %0s printed \"%0s\"", current, output_text());
                errors = errors + 1;
            end
        end
    endtask

    // The output must have want in it, after from. Returns where it ends.
    task expect_line(input string want, inout integer from);
        integer at;
        begin
            at = find(want, from);
            if (at < 0) begin
                $display("FAIL %0s did not print \"%0s\"", current, want);
                errors = errors + 1;
            end else
                from = at;
        end
    endtask

    task expect_stop(input [3:0] cause, input [31:0] pc, input [31:0] instr, input check_where);
        begin
            if (trap !== 1'b1 || trap_cause !== cause) begin
                $display("FAIL %0s stopped with trap=%b cause=%0d, not cause %0d", current, trap,
                         trap_cause, cause);
                errors = errors + 1;
            end else if (check_where && (retire_pc !== pc || retire_instr !== instr)) begin
                $display("FAIL %0s trapped at pc=%h instr=%h, not pc=%h instr=%h", current,
                         retire_pc, retire_instr, pc, instr);
                errors = errors + 1;
            end
        end
    endtask

    // A word of RAM, by byte address, and one byte of it.
    function [31:0] ram_word(input [31:0] address);
        ram_word = dut.u_ram.mem[address[15:2]];
    endfunction

    function [7:0] ram_byte(input [31:0] address);
        reg [31:0] w;
        begin
            w = dut.u_ram.mem[address[15:2]];
            ram_byte = w[8 * address[1:0] +: 8];
        end
    endfunction

    task expect_word(input [31:0] address, input [31:0] want);
        begin
            if (ram_word(address) !== want) begin
                $display("FAIL %0s left %h at %h, not %h", current, ram_word(address), address, want);
                errors = errors + 1;
            end
        end
    endtask

    // The source pattern of memcpy.asm and coherence.asm: word i.
    function [31:0] pattern(input integer i);
        pattern = 32'h1234_5678 + i * 32'h9E37_79B9;
    endfunction

    // ----- The programs -----

    task run_hello;
        begin
            load_and_run("hello.asm", "build/hello.hex");
            expect_output("Hello, world!\n");
            expect_stop(4'd3, 0, 0, 1'b0);
            $display("hello.asm, mode %0d: printed \"%0s\", trap cause %0d", mode,
                     output_text(), trap_cause);
        end
    endtask

    // Tutorial 26's program, unchanged. With the DMA engine idle, the arbiter must
    // add nothing, so in mode 0 it must print exactly what it printed there.
    task run_cpi;
        integer section, at, clocks, instrs, q;
        string  want;
        begin
            load_and_run("cpi.asm", "build/cpi.hex");
            expect_stop(4'd3, 0, 0, 1'b0);
            $display("cpi.asm, mode %0d, as printed:", mode);
            show_output;
            if (mode == 0)
                expect_output({"alu    913 clocks, 303 instructions, CPI 3.01\n",
                               "ram r  1113 clocks, 303 instructions, CPI 3.67\n",
                               "ram w  1113 clocks, 303 instructions, CPI 3.67\n",
                               "gpio r 1113 clocks, 303 instructions, CPI 3.67\n",
                               "axi r  1213 clocks, 303 instructions, CPI 4.00\n",
                               "axi w  1313 clocks, 303 instructions, CPI 4.33\n"});
            // In both modes, each line must match the testbench's own count of
            // clocks between the two reads of cycles. Each window has 303
            // instructions whatever the stalls.
            if (cycle_reads != 12) begin
                $display("FAIL cpi.asm read cycles %0d times, not 12", cycle_reads);
                errors = errors + 1;
            end else begin
                at = 0;
                instrs = 303;
                for (section = 0; section < 6; section = section + 1) begin
                    clocks = cycle_at[2 * section + 1] - cycle_at[2 * section];
                    q = clocks * 100 / instrs;
                    want = $sformatf(" %0d clocks, %0d instructions, CPI %0d.%0d%0d\n",
                                     clocks, instrs, q / 100, (q / 10) % 10, q % 10);
                    expect_line(want, at);
                end
            end
        end
    endtask

    task run_memcpy;
        integer at, i;
        begin
            load_and_run("memcpy.asm", "build/memcpy.hex");
            $display("memcpy.asm, mode %0d, as printed:", mode);
            show_output;
            expect_stop(4'd3, 0, 0, 1'b0);
            at = 0;
            if (cycle_reads != 4) begin
                $display("FAIL memcpy.asm read cycles %0d times, not 4", cycle_reads);
                errors = errors + 1;
            end else begin
                expect_line($sformatf("cpu copy: 1024 bytes in %0d clocks\n",
                                      cycle_at[1] - cycle_at[0]), at);
                expect_line($sformatf("dma copy: 1024 bytes in %0d clocks\n",
                                      cycle_at[3] - cycle_at[2]), at);
            end
            expect_line("copies match\n", at);
            expect_line("byte copy: 13 bytes from 00004001 to 00007003, match\n", at);
            // RAM, checked here too: the source, both copies, and the byte copy.
            for (i = 0; i < 256; i = i + 1) begin
                expect_word(32'h4000 + 4 * i, pattern(i));
                expect_word(32'h5000 + 4 * i, pattern(i));
                expect_word(32'h6000 + 4 * i, pattern(i));
            end
            // Nothing written past the end of either copy.
            expect_word(32'h5400, 32'd0);
            expect_word(32'h6400, 32'd0);
            for (i = 0; i < 13; i = i + 1)
                if (ram_byte(32'h7003 + i) !== ram_byte(32'h4001 + i)) begin
                    $display("FAIL memcpy.asm byte %0d of the byte copy is %h, not %h", i,
                             ram_byte(32'h7003 + i), ram_byte(32'h4001 + i));
                    errors = errors + 1;
                end
            if (ram_byte(32'h7002) !== 8'h00 || ram_byte(32'h7010) !== 8'h00) begin
                $display("FAIL memcpy.asm: the byte copy wrote outside its 13 bytes");
                errors = errors + 1;
            end
        end
    endtask

    task run_dma_uart;
        begin
            load_and_run("dma_uart.asm", "build/dma_uart.hex");
            $display("dma_uart.asm, mode %0d, as printed:", mode);
            show_output;
            expect_stop(4'd3, 0, 0, 1'b0);
            // Exactly this, with no byte lost and none extra.
            if (cycle_reads != 2) begin
                $display("FAIL dma_uart.asm read cycles %0d times, not 2", cycle_reads);
                errors = errors + 1;
            end else
                expect_output($sformatf("%0s%0s%0s", "Sent by the DMA, while the CPU counted.\n",
                    $sformatf("dma printed 40 bytes in %0d clocks\n", cycle_at[1] - cycle_at[0]),
                    $sformatf("the cpu looped %0d times\n", status_at[1] - status_at[0])));
        end
    endtask

    task run_coherence;
        integer i;
        begin
            load_and_run("coherence.asm", "build/coherence.hex");
            $display("coherence.asm, mode %0d, as printed:", mode);
            show_output;
            expect_stop(4'd3, 0, 0, 1'b0);
            expect_output($sformatf("before done: 00000000\nafter done:  %h\nwritten during the copy: c0ffee00\n",
                                    pattern(63)));
            for (i = 0; i < 64; i = i + 1)
                expect_word(32'h6000 + 4 * i, i == 62 ? 32'hC0FF_EE00 : pattern(i));
            expect_word(32'h6100, 32'd0);   // nothing past the end
        end
    endtask

    task run_dma_error;
        begin
            load_and_run("dma_error.asm", "build/dma_error.hex");
            $display("dma_error.asm, mode %0d, as printed:", mode);
            show_output;
            expect_output({"write error:  status 00000004 src 00004000 dst 30000000 len 00000010\n",
                           "read error:   status 00000004 src 30000000 dst 00006000 len 00000010\n",
                           "misaligned:   status 00000004 src 00004002 dst 00006000 len 00000010\n",
                           "now the cpu loads from 30000000\n"});
            // The address and the word come from asm.py --list.
            expect_stop(4'd5, 32'h0000_006C, 32'h0002_A303, 1'b1);
            $display("dma_error.asm, mode %0d: trap cause %0d at pc %h", mode, trap_cause, retire_pc);
        end
    endtask

    task run_slowdown;
        integer run, at;
        string  name, cond, tail;
        begin
            load_and_run("slowdown.asm", "build/slowdown.hex");
            $display("slowdown.asm, mode %0d, as printed:", mode);
            show_output;
            expect_stop(4'd3, 0, 0, 1'b0);
            at = 0;
            // The DMA engine's line comes three times, during the uart runs.
            expect_line("[the DMA printed this]\n[the DMA printed this]\n[the DMA printed this]\n", at);
            if (cycle_reads != 18 || len_reads != 18) begin
                $display("FAIL slowdown.asm read cycles %0d and LEN %0d times, not 18", cycle_reads,
                         len_reads);
                errors = errors + 1;
            end else begin
                for (run = 0; run < 9; run = run + 1) begin
                    name = run % 3 == 0 ? "alu  " : run % 3 == 1 ? "ram  " : "gpio ";
                    cond = run / 3 == 0 ? "idle " : run / 3 == 1 ? "copy " : "uart ";
                    tail = run / 3 == 0 ? "\n" : ", dma busy\n";
                    expect_line($sformatf("%0s%0s%0d clocks, dma moved %0d bytes%0s", name, cond,
                                          cycle_at[2 * run + 1] - cycle_at[2 * run],
                                          bytes_at[2 * run + 1] - bytes_at[2 * run], tail), at);
                end
            end
        end
    endtask

    // ----- Reports -----

    task report_arbiter(input integer md);
        integer mm;
        begin
            $display("Arbiter in mode %0d:", md);
            for (mm = 0; mm < 2; mm = mm + 1)
                $display("  %0s %6d cycles, longest %0d clocks, longest wait for the bus %0d clocks",
                         mm == 0 ? "cpu" : "dma", grants[2 * md + mm], longest[2 * md + mm],
                         max_wait[2 * md + mm]);
            // Each master waits at most for one cycle of the other, plus the clock
            // of cyc low that ends it.
            if (max_wait[2 * md] > longest[2 * md + 1] + 1 ||
                max_wait[2 * md + 1] > longest[2 * md] + 1) begin
                $display("FAIL a master waited longer than the other's longest cycle and a clock");
                errors = errors + 1;
            end
        end
    endtask

    // The waveform keeps two short windows in mode 0: memcpy.asm until the DMA
    // engine's copy has been timed, and dma_error.asm until its first byte
    // comes out of the UART. Everything else is left out to keep the file small.

    task dump_from_here;
        begin
            dump_next = 1'b1;   // load_and_run starts the window after reset
        end
    endtask

    always @(posedge clk) begin
        if (dumping && !rst && ((current == "memcpy.asm" && cycle_reads >= 4) ||
                        (current == "dma_error.asm" && out_count > 0))) begin
            $dumpoff;
            dumping = 1'b0;
        end
    end

    initial begin
        $dumpfile("build/tb_soc.vcd");
        // Only the scopes the README walks through, one level each, and only in the
        // two windows above. Use $dumpvars(0, tb_soc) and remove the $dumpoff calls
        // to record everything, at several hundred MB.
        $dumpvars(1, tb_soc);
        $dumpvars(1, tb_soc.dut);
        $dumpvars(1, tb_soc.dut.u_arbiter);
        $dumpvars(1, tb_soc.dut.u_dma);
        $dumpoff;

        for (n = 0; n < 4; n = n + 1) begin
            grants[n] = 0;
            longest[n] = 0;
            max_wait[n] = 0;
        end

        for (mode = 0; mode < 2; mode = mode + 1) begin
            $display("=== mode %0d: %0s", mode, mode == 0 ? "no stalls" : "random stalls");
            run_hello;
            run_cpi;
            if (mode == 0)
                dump_from_here;
            run_memcpy;
            run_dma_uart;
            run_coherence;
            if (mode == 0)
                dump_from_here;
            run_dma_error;
            run_slowdown;
        end

        for (mode = 0; mode < 2; mode = mode + 1)
            report_arbiter(mode);

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
