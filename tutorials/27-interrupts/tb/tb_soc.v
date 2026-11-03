`timescale 1ns/1ps

// Runs every program on the whole system, and judges each one by what comes out:
// the bytes on uart_tx, decoded at bit level as in Tutorial 19, the traps the core
// took, and how it stopped. Inputs change on the falling edge.
//
// A program stops at its first EBREAK. At that moment the testbench raises every
// slave's hold input, so the core can fetch nothing more and its registers stay as
// they were, while the UART finishes sending. A C program must stop at crt0's
// _exit, whose address the Makefile writes to build/NAME.exit, with 0 in a0.
//
// Some programs print ">" when they want input. Each time a ">" goes out on
// uart_tx, the testbench sends that program's input string on uart_rx, one byte
// after another at the line's speed.
//
// Each program runs twice. Mode 0 holds every slave's hold input low. Mode 1
// drives them from a pseudo-random sequence, so every slave stalls at random.
//
// It also checks the timer on every clock against its own compare, and measures
// interrupt latency: the clocks from the first clock an enabled interrupt is
// pending to the clock it is taken, and from there to the handler's first retire.
module tb_soc #(
    parameter CLKS_PER_BIT = 16
);

    localparam integer TIMEOUT    = 400000;    // clocks for one program
    localparam integer FRAME      = 10 * CLKS_PER_BIT;
    localparam integer MAX_OUTPUT = 512;
    localparam integer MAX_TRAPS  = 64;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg uart_rx = 1'b1;
    reg [7:0] hold = 8'd0;

    wire        uart_tx, trap, retire;
    wire [31:0] trap_cause;
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

    // ----- Random stalls, the same in both simulators, and the freeze at the end -----

    reg [31:0] random = 32'h2545F491;   // xorshift32
    reg        freeze = 1'b0;           // the program has stopped: stall everything

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
        if (freeze)
            hold <= 8'hFF;
        else
            hold <= (mode == 1) ? (random[7:0] & random[15:8]) : 8'd0;
    end

    // ----- The UART decoder: uart_tx back to bytes, every clock of every bit checked -----

    reg [7:0] out [0:MAX_OUTPUT-1];
    integer   out_count = 0;
    integer   frame_bit = -1;   // -1 is idle, 0 is the start bit, 9 is the stop bit
    integer   bit_clock = 0;
    reg       bit_level = 1'b1;
    reg [7:0] frame_data = 8'd0;
    integer   prompts = 0;      // how many ">" have gone out

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
                if (frame_data == 8'h3E)
                    prompts = prompts + 1;
                frame_bit = -1;
            end else begin
                frame_bit = frame_bit + 1;
            end
            bit_clock = 0;
        end
    end

    // ----- The UART sender: input for the program, after each ">" -----

    reg [8*32-1:0] in_text = 0;    // the program's input, as a string
    integer        in_len = 0;
    integer        send_pos = 0;    // the byte being sent
    integer        send_bit = -1;   // -1 idle, 0 start, 1 to 8 data, 9 stop
    integer        send_clock = 0;
    integer        served = 0;      // how many prompts have had their input

    always @(negedge clk) begin
        if (rst) begin
            uart_rx <= 1'b1;
            send_bit = -1;
            served = 0;
        end else if (send_bit == -1) begin
            if (served < prompts && in_len > 0) begin
                served = served + 1;
                send_pos = 0;
                send_bit = 0;
                send_clock = 0;
            end
        end
        if (!rst && send_bit != -1) begin
            if (send_clock == 0)
                uart_rx <= send_bit == 0 ? 1'b0 :
                           send_bit == 9 ? 1'b1 :
                           in_text[8 * (in_len - 1 - send_pos) + (send_bit - 1)];
            send_clock = send_clock + 1;
            if (send_clock == CLKS_PER_BIT) begin
                send_clock = 0;
                send_bit = send_bit + 1;
                if (send_bit == 10) begin
                    send_pos = send_pos + 1;
                    send_bit = (send_pos < in_len) ? 0 : -1;
                end
            end
        end
    end

    // ----- Traps, as the core takes them -----

    reg [31:0] trap_causes [0:MAX_TRAPS-1];
    reg [31:0] trap_pcs    [0:MAX_TRAPS-1];
    reg [31:0] trap_tvals  [0:MAX_TRAPS-1];
    integer    trap_count = 0;
    reg        stopped = 1'b0;      // the first EBREAK has been taken
    reg [31:0] stop_pc, stop_a0;

    always @(negedge clk) begin
        if (!rst && trap === 1'b1 && !stopped) begin
            if (trap_count < MAX_TRAPS) begin
                trap_causes[trap_count] = trap_cause;
                trap_pcs[trap_count]    = retire_pc;
                trap_tvals[trap_count]  = dut.u_core.trap_tval;
            end
            trap_count = trap_count + 1;
            if (trap_cause == 32'd3) begin
                stopped = 1'b1;
                freeze  = 1'b1;
                stop_pc = retire_pc;
                stop_a0 = dut.u_core.u_regs.q[10];
            end
        end
    end

    // ----- The timer, checked on every clock -----

    // irq must show, on each clock, the compare of mtime and mtimecmp from the
    // clock before. Sampled on the falling edge, when nothing is changing.
    reg past_due = 1'b0;
    reg past_ok  = 1'b0;

    always @(negedge clk) begin
        if (past_ok && !rst && dut.irq_timer !== past_due) begin
            if (errors < 20)
                $display("FAIL t=%0t timer irq is %b, but mtime %h >= mtimecmp %h was %b a clock ago",
                         $time, dut.irq_timer, dut.u_timer.mtime, dut.u_timer.mtimecmp, past_due);
            errors = errors + 1;
        end
        past_due = dut.u_timer.mtime >= dut.u_timer.mtimecmp;
        past_ok  = !rst;
    end

    // ----- Interrupt latency -----

    // pending: clocks so far in which an enabled interrupt was pending, with MIE
    // set, and not yet taken. entering: clocks since the last interrupt was taken,
    // until the handler's first instruction retires.
    integer pending = 0;
    integer entering = -1;
    integer lat_count [0:1], lat_min [0:1], lat_max [0:1], lat_sum [0:1];
    integer ent_min [0:1], ent_max [0:1], ent_sum [0:1], ent_count [0:1];

    // For pollirq.c: clocks from each external interrupt to its handler's mret.
    integer in_handler = -1;
    integer handler_clocks = 0, handler_count = 0;

    always @(negedge clk) begin
        if (rst || stopped) begin
            pending = 0;
            entering = -1;
            in_handler = -1;
        end else begin
            if (dut.u_core.irq_pending === 1'b1)
                pending = pending + 1;
            if (entering >= 0)
                entering = entering + 1;
            if (in_handler >= 0)
                in_handler = in_handler + 1;

            if (retire === 1'b1 && entering > 0) begin
                ent_count[mode] = ent_count[mode] + 1;
                ent_sum[mode]   = ent_sum[mode] + entering;
                if (entering < ent_min[mode]) ent_min[mode] = entering;
                if (entering > ent_max[mode]) ent_max[mode] = entering;
                entering = -1;
            end
            if (retire === 1'b1 && retire_instr == 32'h3020_0073 && in_handler > 0) begin
                handler_clocks = handler_clocks + in_handler;
                handler_count  = handler_count + 1;
                in_handler = -1;
            end

            if (trap === 1'b1 && trap_cause[31]) begin
                lat_count[mode] = lat_count[mode] + 1;
                lat_sum[mode]   = lat_sum[mode] + pending;
                if (pending < lat_min[mode]) lat_min[mode] = pending;
                if (pending > lat_max[mode]) lat_max[mode] = pending;
                pending = 0;
                entering = 0;
                if (trap_cause == 32'h8000_000B)
                    in_handler = 1;
            end else if (dut.u_core.irq_pending !== 1'b1) begin
                pending = 0;
            end
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
            prompts = 0;
            trap_count = 0;
            stopped = 1'b0;
            freeze = 1'b0;
            handler_clocks = 0;
            handler_count = 0;
            @(negedge clk);
            @(negedge clk);
            rst = 1'b0;
            clocks = 0;
            while (!stopped && clocks < TIMEOUT) begin
                @(negedge clk);
                clocks = clocks + 1;
            end
            if (!stopped) begin
                $display("FAIL %0s: no EBREAK after %0d clocks", hex, TIMEOUT);
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

    // Does the output match want? In want, "#" stands for one or more digits.
    function automatic fits(input string want);
        integer i, j;
        begin
            fits = 1;
            i = 0;
            j = 0;
            while (fits && j < want.len()) begin
                if (want[j] == "#") begin
                    if (i >= out_count || out[i] < "0" || out[i] > "9")
                        fits = 0;
                    while (i < out_count && out[i] >= "0" && out[i] <= "9")
                        i = i + 1;
                end else begin
                    if (i >= out_count || out[i] != want[j])
                        fits = 0;
                    i = i + 1;
                end
                j = j + 1;
            end
            if (i != out_count)
                fits = 0;
        end
    endfunction

    task expect_output(input [8*32-1:0] hex, input string want);
        begin
            if (!fits(want)) begin
                $display("FAIL %0s printed \"%0s\"", hex, output_text());
                errors = errors + 1;
            end
        end
    endtask

    // A C program must stop at crt0's _exit, with main's return value, 0, in a0.
    reg [31:0] exit_address [0:0];

    task expect_exit(input [8*32-1:0] hex, input [8*32-1:0] exit_file);
        begin
            $readmemh(exit_file, exit_address);
            if (stop_pc !== exit_address[0] || stop_a0 !== 32'd0) begin
                $display("FAIL %0s stopped at %h with a0 = %h, not at _exit %h with 0", hex,
                         stop_pc, stop_a0, exit_address[0]);
                errors = errors + 1;
            end
        end
    endtask

    task expect_traps(input [8*32-1:0] hex, input integer count, input [32*16-1:0] causes);
        integer i;
        begin
            if (trap_count != count) begin
                $display("FAIL %0s took %0d traps, not %0d", hex, trap_count, count);
                errors = errors + 1;
            end else begin
                for (i = 0; i < count; i = i + 1)
                    if (trap_causes[i] !== causes[32 * (count - 1 - i) +: 32]) begin
                        $display("FAIL %0s trap %0d had cause %h, not %h", hex, i,
                                 trap_causes[i], causes[32 * (count - 1 - i) +: 32]);
                        errors = errors + 1;
                    end
            end
        end
    endtask

    task show_traps;
        integer i;
        begin
            for (i = 0; i < trap_count && i < MAX_TRAPS; i = i + 1)
                $display("  trap %2d: mcause %h  mepc %h  mtval %h", i, trap_causes[i],
                         trap_pcs[i], trap_tvals[i]);
        end
    endtask

    task run_traps;
        begin
            in_text = "";
            in_len = 0;
            load_and_run("build/traps.hex");
            expect_output("build/traps.hex", "traps ok\n");
            expect_traps("build/traps.hex", 12,
                          {128'd0, 32'd2, 32'd11, 32'd4, 32'd6, 32'd0, 32'd5, 32'd7, 32'd7, 32'd1,
                           32'd2, 32'd2, 32'd3});
            $display("traps.asm, mode %0d: printed \"%0s\", %0d traps", mode, output_text(),
                     trap_count);
            if (mode == 0)
                show_traps;
        end
    endtask

    task run_irq;
        begin
            in_text = "x";
            in_len = 1;
            load_and_run("build/irq.hex");
            expect_output("build/irq.hex", ">irq ok\n");
            expect_traps("build/irq.hex", 4,
                          {384'd0, 32'h8000_0007, 32'h8000_000B, 32'h8000_0007, 32'd3});
            $display("irq.asm, mode %0d: printed \"%0s\", %0d traps", mode, output_text(),
                     trap_count);
            if (mode == 0)
                show_traps;
        end
    endtask

    task run_c(input [8*32-1:0] hex, input [8*32-1:0] exit_file, input [8*32-1:0] text,
               input integer len, input string want);
        begin
            in_text = text;
            in_len = len;
            load_and_run(hex);
            expect_output(hex, want);
            expect_exit(hex, exit_file);
            $display("%0s, mode %0d: printed \"%0s\", %0d traps, stopped at %h with a0 = %0d",
                     hex, mode, output_text(), trap_count, stop_pc, stop_a0);
        end
    endtask

    // ----- Reports -----

    task report_latency(input integer m);
        begin
            if (lat_count[m] > 0)
                $display("Interrupts in mode %0d: %0d taken. Pending to taken: %0d to %0d clocks, mean %0.2f. Taken to the handler's first retire: %0d to %0d clocks, mean %0.2f",
                         m, lat_count[m], lat_min[m], lat_max[m], 1.0 * lat_sum[m] / lat_count[m],
                         ent_min[m], ent_max[m], 1.0 * ent_sum[m] / ent_count[m]);
        end
    endtask

    initial begin
`ifndef VERILATOR
        // Only the scopes the README walks through, one level each, and only while
        // traps.asm and irq.asm run without stalls. Use $dumpvars(0, tb_soc) and no
        // $dumpoff to record everything, at well over 100 MB. Verilator writes no
        // waveform here.
        $dumpfile("build/tb_soc.vcd");
        $dumpvars(1, tb_soc);
        $dumpvars(1, tb_soc.dut);
        $dumpvars(1, tb_soc.dut.u_core);
        $dumpvars(1, tb_soc.dut.u_core.u_csr);
        $dumpvars(1, tb_soc.dut.u_timer);
`endif

        for (n = 0; n < 2; n = n + 1) begin
            lat_count[n] = 0;
            lat_sum[n] = 0;
            lat_min[n] = 1000000;
            lat_max[n] = 0;
            ent_count[n] = 0;
            ent_sum[n] = 0;
            ent_min[n] = 1000000;
            ent_max[n] = 0;
        end

        for (mode = 0; mode < 2; mode = mode + 1) begin
            $display("=== mode %0d: %0s", mode, mode == 0 ? "no stalls" : "random stalls");
            run_traps;
            run_irq;
`ifndef VERILATOR
            $dumpoff;
`endif
            run_c("build/hello.hex", "build/hello.exit", "", 0, "Hello from C\n");
            run_c("build/ticks.hex", "build/ticks.exit", "", 0,
                  "10 ticks, # spins, handler read mtime # to # clocks after the deadline\n");
            run_c("build/echo.hex", "build/echo.exit", "Hello, interrupts!\n", 19,
                  ">Hello, interrupts!\n19 bytes echoed\n");
            run_c("build/pollirq.hex", "build/pollirq.exit", "abcdefghijklmnop", 16,
                  ">\npolled: 16 bytes in # clocks, all of them waiting, # status reads found nothing\n>\ninterrupts: the loop ran # times alone and # times while 16 bytes came in: they took # of 4000 clocks, # each\n");
            if (handler_count > 0)
                $display("pollirq.c, mode %0d: %0d external interrupts, %0d clocks from taking each to its mret retiring, %0.2f each",
                         mode, handler_count, handler_clocks, 1.0 * handler_clocks / handler_count);
        end

        for (mode = 0; mode < 2; mode = mode + 1)
            report_latency(mode);

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
