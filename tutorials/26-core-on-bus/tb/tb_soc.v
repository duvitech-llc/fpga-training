`timescale 1ns/1ps

// Runs every program on the whole system, and judges each one by what comes out:
// the bytes on uart_tx, decoded at bit level as in Tutorial 19, how it stopped, and
// a few registers at the end. Inputs change on the falling edge.
//
// Each program runs twice. Mode 0 holds every slave's hold input low. Mode 1 drives
// them from a pseudo-random sequence, so every slave stalls at random, and every
// program must still print the same thing and stop the same way.
//
// It also measures, from the core's memory interface:
//   - every transfer: clocks from its start to mem_ready, by kind and by target.
//     In mode 0 each must take exactly the clocks in the table in expected_clocks.
//   - every instruction: clocks from one retire to the next, by class, next to
//     what Tutorial 21's memory with no wait would have taken: 2, or 3 for a load
//     or store.
// For cpi.asm it checks the numbers the program prints against its own count of
// clocks and retires between the same two counter reads.
module tb_soc #(
    parameter CLKS_PER_BIT = 16
);

    localparam integer TIMEOUT    = 500000;    // clocks for one program
    localparam integer FRAME      = 10 * CLKS_PER_BIT;
    localparam integer MAX_OUTPUT = 512;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg uart_rx = 1'b1;
    reg [6:0] hold = 7'd0;

    wire        uart_tx, trap, retire;
    wire [3:0]  trap_cause;
    wire [31:0] gpio_out, retire_pc, retire_instr;

    soc #(.CLKS_PER_BIT(CLKS_PER_BIT)) dut (
        .clk(clk), .rst(rst), .uart_rx(uart_rx), .uart_tx(uart_tx), .gpio_out(gpio_out),
        .trap(trap), .trap_cause(trap_cause),
        .retire(retire), .retire_pc(retire_pc), .retire_instr(retire_instr),
        .hold(hold)
    );

    always #5 clk = ~clk;

    integer errors = 0;
    integer mode = 0;
    integer n;

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
        hold <= (mode == 1) ? (random[6:0] & random[14:8]) : 7'd0;
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

    // ----- Transfers on the core's memory interface -----

    wire        mem_valid = dut.mem_valid;
    wire        mem_ready = dut.mem_ready;
    wire        mem_instr = dut.mem_instr;
    wire [31:0] mem_addr  = dut.mem_addr;
    wire [3:0]  mem_wstrb = dut.mem_wstrb;

    // The testbench's own decode of the map, written from the table in soc_map.vh.
    // 0 RAM, 1 a Wishbone peripheral, 2 the AXI4-Lite block, 3 nothing.
    function integer target_of(input [31:0] a);
        if (a < 32'h0001_0000)                              target_of = 0;
        else if (a >= 32'h1000_0000 && a < 32'h1000_0008)   target_of = 1;
        else if (a >= 32'h1000_1000 && a < 32'h1000_1004)   target_of = 1;
        else if (a >= 32'h1000_2000 && a < 32'h1000_2008)   target_of = 1;
        else if (a >= 32'h2000_0000 && a < 32'h2000_0020)   target_of = 2;
        else                                                target_of = 3;
    endfunction

    // Kinds: 0 fetch, 1 load, 2 store. Index kind * 4 + target.
    integer xfer_seen  [0:23];
    integer xfer_spent [0:23];
    integer xfer_clocks = 0;            // clocks of the transfer in progress
    reg     xfer_busy = 1'b0;

    // What each transfer must take in mode 0, from the start of mem_valid to the
    // edge with mem_ready, counting both. 0: not checked.
    function integer expected_clocks(input integer kind, input integer target);
        if (target == 0 || target == 1) expected_clocks = 2;    // Wishbone slave, ack next clock
        else if (target == 2)           expected_clocks = (kind == 2) ? 4 : 3;
        else                            expected_clocks = 0;
    endfunction


    integer k, t;

    always @(posedge clk) begin
        if (rst) begin
            xfer_busy   = 1'b0;
            xfer_clocks = 0;
        end else if (mem_valid === 1'b1) begin
            if (!xfer_busy) begin
                xfer_busy   = 1'b1;
                xfer_clocks = 0;
            end
            xfer_clocks = xfer_clocks + 1;
            if (mem_ready === 1'b1) begin
                k = mem_instr ? 0 : (mem_wstrb != 4'd0) ? 2 : 1;
                t = target_of(mem_addr);
                xfer_seen[12 * mode + 4 * k + t]  = xfer_seen[12 * mode + 4 * k + t] + 1;
                xfer_spent[12 * mode + 4 * k + t] = xfer_spent[12 * mode + 4 * k + t] + xfer_clocks;
                if (mode == 0 && expected_clocks(k, t) != 0 && xfer_clocks != expected_clocks(k, t)) begin
                    $display("FAIL a transfer to %h took %0d clocks, not %0d", mem_addr,
                             xfer_clocks, expected_clocks(k, t));
                    errors = errors + 1;
                end
                xfer_busy = 1'b0;   // mem_valid may stay high: that is the next transfer
            end
        end else begin
            xfer_busy = 1'b0;
        end
    end

    // ----- Clocks per instruction, by class -----

    // 0 ALU register, 1 ALU immediate, 2 LUI and AUIPC, 3 JAL and JALR, 4 branch,
    // 5 load from RAM, 6 store to RAM, 7 load from a Wishbone peripheral,
    // 8 store to one, 9 load from AXI4-Lite, 10 store to AXI4-Lite, 11 other.
    integer seen  [0:23];
    integer spent [0:23];
    integer instr_clocks = 0;
    integer c;

    function integer class_of(input [31:0] instr, input [31:0] addr);
        integer region;
        begin
            region = target_of(addr);
            case (instr[6:0])
                7'b0110011: class_of = 0;
                7'b0010011: class_of = 1;
                7'b0110111, 7'b0010111: class_of = 2;
                7'b1101111, 7'b1100111: class_of = 3;
                7'b1100011: class_of = 4;
                7'b0000011: class_of = region == 0 ? 5 : region == 1 ? 7 : 9;
                7'b0100011: class_of = region == 0 ? 6 : region == 1 ? 8 : 10;
                default:    class_of = 11;
            endcase
        end
    endfunction

    // The clock count, and the count of retires, since reset, and their values at
    // each read of the counters, sampled before this edge adds to them, as the
    // counters do. cpi.asm is checked against these.
    integer clocks_since_reset = 0;
    integer retires_since_reset = 0;
    reg     started = 1'b0;          // the first fetch has begun

    integer cycle_at [0:15];         // clocks_since_reset at each read of cycles
    integer instr_at [0:15];         // retires_since_reset at each read of instret
    integer cycle_reads = 0;
    integer instr_reads = 0;

    wire counter_read = dut.s_cyc && dut.s_stb[3] && !dut.s_stall[3] && !dut.s_we;

    always @(posedge clk) begin
        if (rst) begin
            instr_clocks = 0;
            clocks_since_reset = 0;
            retires_since_reset = 0;
            started = 1'b0;
            cycle_reads = 0;
            instr_reads = 0;
        end else begin
            if (counter_read && dut.s_adr[0] == 1'b0) begin
                if (cycle_reads < 16)
                    cycle_at[cycle_reads] = clocks_since_reset;
                cycle_reads = cycle_reads + 1;
            end
            if (counter_read && dut.s_adr[0] == 1'b1) begin
                if (instr_reads < 16)
                    instr_at[instr_reads] = retires_since_reset;
                instr_reads = instr_reads + 1;
            end

            clocks_since_reset = clocks_since_reset + 1;
            // As in Tutorial 21, the clock before the first fetch is reset's, not
            // the first instruction's.
            if (mem_valid === 1'b1)
                started = 1'b1;
            if (started)
                instr_clocks = instr_clocks + 1;
            if (retire === 1'b1) begin
                c = class_of(retire_instr, mem_addr) + 12 * mode;
                seen[c]  = seen[c] + 1;
                spent[c] = spent[c] + instr_clocks;
                instr_clocks = 0;
                retires_since_reset = retires_since_reset + 1;
            end
        end
    end

    // ----- The stores of lanes.asm, at each step of the way -----

    reg show_stores = 1'b0;

    always @(posedge clk) begin
        if (show_stores && !rst) begin
            if (dut.m_cyc && dut.m_stb && !dut.m_stall && dut.m_we)
                $display("  store to %h: mem_wstrb %b, sel %b, dat_w %h", {dut.m_adr, 2'b00},
                         mem_wstrb, dut.m_sel, dut.m_dat_w);
            if (dut.wvalid && dut.wready)
                $display("  AXI4-Lite W:  wstrb %b, wdata %h, to awaddr %h", dut.wstrb, dut.wdata,
                         dut.awaddr);
        end
    end

    // ----- Running one program -----

    task load_and_run(input [8*32-1:0] hex);
        integer clocks;
        begin
            @(negedge clk);
            rst = 1'b1;
            $readmemh(hex, dut.u_ram.mem);
            out_count = 0;
            @(negedge clk);
            @(negedge clk);
            rst = 1'b0;
            clocks = 0;
            while (trap !== 1'b1 && clocks < TIMEOUT) begin
                @(negedge clk);
                clocks = clocks + 1;
            end
            if (trap !== 1'b1) begin
                $display("FAIL %0s: no trap after %0d clocks", hex, TIMEOUT);
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

    task expect_output(input [8*32-1:0] hex, input string want);
        begin
            if (out_count != want.len() || find(want, 0) != want.len()) begin
                $display("FAIL %0s printed \"%0s\"", hex, output_text());
                errors = errors + 1;
            end
        end
    endtask

    task expect_stop(input [8*32-1:0] hex, input [3:0] cause, input [31:0] pc,
                     input [31:0] instr, input check_where);
        begin
            if (trap !== 1'b1 || trap_cause !== cause) begin
                $display("FAIL %0s stopped with trap=%b cause=%0d, not cause %0d", hex, trap,
                         trap_cause, cause);
                errors = errors + 1;
            end else if (check_where && (retire_pc !== pc || retire_instr !== instr)) begin
                $display("FAIL %0s trapped at pc=%h instr=%h, not pc=%h instr=%h", hex,
                         retire_pc, retire_instr, pc, instr);
                errors = errors + 1;
            end
        end
    endtask

    task run_hello;
        begin
            load_and_run("build/hello.hex");
            expect_output("build/hello.hex", "Hello, world!\n");
            expect_stop("build/hello.hex", 4'd3, 0, 0, 1'b0);
            $display("hello.asm, mode %0d: printed \"%0s\", trap cause %0d", mode,
                     output_text(), trap_cause);
        end
    endtask

    task run_lanes;
        begin
            show_stores = (mode == 0);
            load_and_run("build/lanes.hex");
            show_stores = 1'b0;
            expect_output("build/lanes.hex", "AXIL\n");
            expect_stop("build/lanes.hex", 4'd3, 0, 0, 1'b0);
            if (gpio_out !== 32'h6677_88A5) begin
                $display("FAIL lanes.asm left gpio_out at %h", gpio_out);
                errors = errors + 1;
            end
            if (dut.u_axil_regs.regs[0] !== 32'h6677_8899) begin
                $display("FAIL lanes.asm left AXI4-Lite reg0 at %h", dut.u_axil_regs.regs[0]);
                errors = errors + 1;
            end
            $display("lanes.asm, mode %0d: printed \"%0s\", trap cause %0d, gpio_out %h, reg0 %h",
                     mode, output_text(), trap_cause, gpio_out, dut.u_axil_regs.regs[0]);
        end
    endtask

    task run_faults;
        begin
            // The addresses of "bad" come from asm.py --list.
            load_and_run("build/fault.hex");
            expect_output("build/fault.hex", "load from 0x30000000\n");
            expect_stop("build/fault.hex", 4'd5, 32'h0000_0010, 32'h000E_2E83, 1'b1);
            $display("fault.asm, mode %0d: printed \"%0s\", trap cause %0d at pc %h, instr %h",
                     mode, output_text(), trap_cause, retire_pc, retire_instr);

            load_and_run("build/readonly.hex");
            expect_output("build/readonly.hex", "write to the ID register\n");
            expect_stop("build/readonly.hex", 4'd7, 32'h0000_0018, 32'h01C9_2823, 1'b1);
            $display("readonly.asm, mode %0d: printed \"%0s\", trap cause %0d at pc %h, instr %h",
                     mode, output_text(), trap_cause, retire_pc, retire_instr);
        end
    endtask

    task run_cpi;
        integer section, at, clocks, instrs, q;
        string  want;
        begin
            load_and_run("build/cpi.hex");
            expect_stop("build/cpi.hex", 4'd3, 0, 0, 1'b0);
            $display("cpi.asm, mode %0d, as printed:", mode);
            for (n = 0; n < out_count; n = n + 1)
                $write("%c", out[n]);
            if (cycle_reads != 12 || instr_reads != 12) begin
                $display("FAIL cpi.asm read cycles %0d times and instret %0d times, not 12",
                         cycle_reads, instr_reads);
                errors = errors + 1;
            end else begin
                at = 0;
                for (section = 0; section < 6; section = section + 1) begin
                    clocks = cycle_at[2 * section + 1] - cycle_at[2 * section];
                    instrs = instr_at[2 * section + 1] - instr_at[2 * section];
                    q = clocks * 100 / instrs;
                    want = $sformatf(" %0d clocks, %0d instructions, CPI %0d.%0d%0d\n",
                                     clocks, instrs, q / 100, (q / 10) % 10, q % 10);
                    at = find(want, at);
                    if (at < 0) begin
                        $display("FAIL cpi.asm section %0d: the testbench counted \"%0s\"",
                                 section, want);
                        errors = errors + 1;
                        at = 0;
                    end
                end
            end
        end
    endtask

    // ----- Reports -----

    task report_transfers(input integer m);
        integer kk, tt, i;
        begin
            $display("Transfers in mode %0d: clocks from the start of mem_valid to mem_ready", m);
            for (kk = 0; kk < 3; kk = kk + 1)
                for (tt = 0; tt < 4; tt = tt + 1) begin
                    i = 12 * m + 4 * kk + tt;
                    if (xfer_seen[i] > 0)
                        $display("  %0s %0s %6d transfers, %0.2f clocks each",
                                 kk == 0 ? "fetch" : kk == 1 ? "load " : "store",
                                 tt == 0 ? "RAM      " : tt == 1 ? "Wishbone " :
                                 tt == 2 ? "AXI4-Lite" : "unmapped ",
                                 xfer_seen[i], 1.0 * xfer_spent[i] / xfer_seen[i]);
                end
        end
    endtask

    task report_classes(input integer m);
        integer cc, i, all_seen, all_spent, all_direct, direct;
        begin
            $display("Instructions in mode %0d: clocks each on this bus, and with Tutorial 21's memory with no wait", m);
            all_seen = 0;
            all_spent = 0;
            all_direct = 0;
            for (cc = 0; cc < 12; cc = cc + 1) begin
                i = 12 * m + cc;
                direct = (cc >= 5 && cc <= 10) ? 3 : 2;
                if (seen[i] > 0)
                    $display("  %0s %6d instructions, %5.2f clocks each, %0d with no wait",
                             cc == 0 ? "ALU register        " : cc == 1 ? "ALU immediate       " :
                             cc == 2 ? "LUI, AUIPC          " : cc == 3 ? "JAL, JALR           " :
                             cc == 4 ? "branch              " : cc == 5 ? "load from RAM       " :
                             cc == 6 ? "store to RAM        " : cc == 7 ? "load from Wishbone  " :
                             cc == 8 ? "store to Wishbone   " : cc == 9 ? "load from AXI4-Lite " :
                             cc == 10 ? "store to AXI4-Lite  " : "other               ",
                             seen[i], 1.0 * spent[i] / seen[i], direct);
                all_seen   = all_seen + seen[i];
                all_spent  = all_spent + spent[i];
                all_direct = all_direct + direct * seen[i];
            end
            $display("  all                  %6d instructions, %5.2f clocks each, %0.2f with no wait",
                     all_seen, 1.0 * all_spent / all_seen, 1.0 * all_direct / all_seen);
        end
    endtask

    initial begin
        $dumpfile("build/tb_soc.vcd");
        // Only the signals the README walks through, one level each. Use
        // $dumpvars(0, tb_soc) to record everything, at over 100 MB.
        $dumpvars(1, tb_soc);
        $dumpvars(1, tb_soc.dut);
        $dumpvars(1, tb_soc.dut.u_bridge);

        for (n = 0; n < 24; n = n + 1) begin
            seen[n] = 0;
            spent[n] = 0;
            xfer_seen[n] = 0;
            xfer_spent[n] = 0;
        end

        for (mode = 0; mode < 2; mode = mode + 1) begin
            // The waveform keeps only the first pass, without stalls, which keeps
            // the file small enough to open. Verilator ignores $dumpoff.
            if (mode == 1)
                $dumpoff;
            $display("=== mode %0d: %0s", mode, mode == 0 ? "no stalls" : "random stalls");
            run_hello;
            run_lanes;
            run_faults;
            run_cpi;
        end

        for (mode = 0; mode < 2; mode = mode + 1) begin
            report_transfers(mode);
            report_classes(mode);
        end

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
