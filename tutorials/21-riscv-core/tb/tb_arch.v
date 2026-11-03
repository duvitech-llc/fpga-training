`timescale 1ns/1ps

// Runs the official RISC-V architecture tests on the core, and compares each test's
// signature with the reference that comes with the suite. `make archtest` fetches
// the suite, compiles each test with tb/arch/model_test.h and tb/arch/link.ld, and
// writes build/archtest/list.txt with one line per test:
//
//   name  begin_signature  end_signature        (the two addresses in hex)
//
// beside build/archtest/name.hex, the program as one 32-bit word per line from
// address 0, and build/archtest/name.ref, the reference signature from the suite.
//
// A test passes when it ends with ebreak, which this core takes as a trap with
// cause 3, and every word from begin_signature to end_signature matches the
// reference. It fails on any other trap, on a timeout, on an access outside the
// memory, or on any signature word that differs.
//
// The memory is the one from tb_trace.v in its wait mode 2: it answers on the falling
// edge after 0 to 3 wait clocks from a pseudo-random sequence, the same in Icarus
// and Verilator, and drives junk on mem_rdata while it waits.
module tb_arch;

    localparam integer WORDS     = 524288;   // 2 MiB. jal-01 alone is 1.7 MB
    localparam integer SIG_WORDS = 4096;     // longest reference here: 728 words
    localparam integer TIMEOUT   = 40;       // most clocks between two retires
    localparam integer MAX_INSNS = 1000000;  // per test

    reg clk = 1'b0;
    reg rst = 1'b1;

    wire        mem_valid, mem_instr;
    reg         mem_ready = 1'b0;
    wire [31:0] mem_addr, mem_wdata;
    wire [3:0]  mem_wstrb;
    reg  [31:0] mem_rdata = 32'd0;
    wire        trap, retire;
    wire [3:0]  trap_cause;
    wire [31:0] retire_pc, retire_instr;

    rv32i dut (
        .clk(clk), .rst(rst),
        .mem_valid(mem_valid), .mem_instr(mem_instr), .mem_ready(mem_ready),
        .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_wstrb(mem_wstrb),
        .mem_rdata(mem_rdata),
        .trap(trap), .trap_cause(trap_cause),
        .retire(retire), .retire_pc(retire_pc), .retire_instr(retire_instr)
    );

    always #5 clk = ~clk;

    // ----- The memory -----

    reg  [31:0] mem [0:WORDS-1];
    reg  [31:0] random = 32'h2545F491;   // xorshift32, the same in both simulators
    integer     wait_left = 0;
    reg         busy = 1'b0;             // a transfer has started and not finished
    reg         outside = 1'b0;          // the core went outside the memory

    wire [18:0] index = mem_addr[20:2];

    reg  [68:0] held;
    wire [68:0] request = {mem_instr, mem_addr, mem_wdata, mem_wstrb};

    integer errors = 0;                  // in this test

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
        if (rst || mem_valid !== 1'b1) begin
            mem_ready <= 1'b0;
            busy = 1'b0;
        end else begin
            if (busy && !mem_ready && request !== held) begin
                $display("  the core changed a request while it waited: %h, then %h",
                         held, request);
                errors = errors + 1;
            end

            if (!busy || mem_ready) begin
                busy = 1'b1;
                held = request;
                wait_left = {30'd0, random[1:0]};
            end

            if (mem_addr[31:21] != 11'd0) begin
                // Never answer, so the core stops here and the test times out.
                mem_ready <= 1'b0;
                outside = 1'b1;
            end else if (wait_left == 0) begin
                mem_ready <= 1'b1;
                mem_rdata <= mem[index];
                if (mem_wstrb[0]) mem[index][7:0]   = mem_wdata[7:0];
                if (mem_wstrb[1]) mem[index][15:8]  = mem_wdata[15:8];
                if (mem_wstrb[2]) mem[index][23:16] = mem_wdata[23:16];
                if (mem_wstrb[3]) mem[index][31:24] = mem_wdata[31:24];
            end else begin
                mem_ready <= 1'b0;
                mem_rdata <= next_random(random);     // junk
                wait_left = wait_left - 1;
            end
        end
    end

    // ----- One test -----

    reg  [31:0] ref_sig [0:SIG_WORDS-1];
    reg  [8*64-1:0] name;
    reg  [8*96-1:0] path;
    reg  [31:0] sig_begin, sig_end;
    integer     file, list, n, first, words, ref_words, insns, idle, differ;
    integer     ran = 0, passed = 0, failed = 0, skipped;
    reg  [8*160-1:0] line;
    reg         ok;

    task run_test;
        begin
            @(negedge clk);
            rst = 1'b1;
            errors  = 0;
            outside = 1'b0;
            for (n = 0; n < WORDS; n = n + 1)
                mem[n] = 32'd0;

            // $readmemh would warn that the files are shorter than the arrays.
            $sformat(path, "build/archtest/%0s.hex", name);
            file = $fopen(path, "r");
            if (file == 0) $fatal(1, "cannot open %0s", path);
            for (n = 0; n < WORDS && $fscanf(file, "%h\n", mem[n]) == 1; n = n + 1) ;
            if (!$feof(file)) $fatal(1, "%0s does not fit in %0d words", path, WORDS);
            $fclose(file);

            $sformat(path, "build/archtest/%0s.ref", name);
            file = $fopen(path, "r");
            if (file == 0) $fatal(1, "cannot open %0s", path);
            for (ref_words = 0; ref_words < SIG_WORDS
                 && $fscanf(file, "%h\n", ref_sig[ref_words]) == 1; ref_words = ref_words + 1) ;
            $fclose(file);

            @(negedge clk);
            @(negedge clk);
            rst = 1'b0;

            // Run until the core stops: a trap, or nothing retires for too long.
            insns = 0;
            idle  = 0;
            while (trap !== 1'b1 && idle <= TIMEOUT && insns < MAX_INSNS) begin
                @(negedge clk);
                if (retire === 1'b1) begin
                    insns = insns + 1;
                    idle  = 0;
                end else
                    idle = idle + 1;
            end

            ok = 1'b1;
            if (outside) begin
                $display("FAIL %0s: an access outside the memory, at pc %h", name, retire_pc);
                ok = 1'b0;
            end else if (trap !== 1'b1) begin
                $display("FAIL %0s: no ebreak after %0d instructions, pc %h", name, insns,
                         retire_pc);
                ok = 1'b0;
            end else if (trap_cause !== 4'd3) begin
                $display("FAIL %0s: trap with cause %0d at pc %h, instruction %h", name,
                         trap_cause, retire_pc, retire_instr);
                ok = 1'b0;
            end

            first = sig_begin / 4;
            words = (sig_end - sig_begin) / 4;
            if (ok && words != ref_words) begin
                $display("FAIL %0s: the signature has %0d words, the reference %0d", name,
                         words, ref_words);
                ok = 1'b0;
            end

            // Compare the signature, and show the first few words that differ.
            if (ok) begin
                differ = 0;
                for (n = 0; n < words; n = n + 1)
                    if (mem[first + n] !== ref_sig[n]) begin
                        if (differ < 3)
                            $display("  %0s word %0d (address %h) is %h, reference %h",
                                     name, n, sig_begin + 4 * n, mem[first + n],
                                     ref_sig[n]);
                        differ = differ + 1;
                    end
                if (differ != 0) begin
                    $display("FAIL %0s: %0d of %0d signature words differ", name, differ,
                             words);
                    ok = 1'b0;
                end
            end

            if (ok && errors != 0) begin
                $display("FAIL %0s: %0d errors in the memory interface", name, errors);
                ok = 1'b0;
            end

            ran = ran + 1;
            if (ok) begin
                passed = passed + 1;
                $display("PASS %0s: %0d signature words, %0d instructions", name, words,
                         insns);
            end else
                failed = failed + 1;
        end
    endtask

    initial begin
        list = $fopen("build/archtest/list.txt", "r");
        if (list == 0) $fatal(1, "cannot open build/archtest/list.txt");
        while ($fscanf(list, "%s %h %h\n", name, sig_begin, sig_end) == 3)
            run_test;
        $fclose(list);

        // The tests that need what this core does not have, one per line with why.
        skipped = 0;
        list = $fopen("build/archtest/skipped.txt", "r");
        if (list != 0) begin
            while ($fgets(line, list) != 0) begin
                $write("SKIP %0s", line);
                skipped = skipped + 1;
            end
            $fclose(list);
        end

        $display("%0d tests ran, %0d passed, %0d failed, %0d skipped", ran, passed, failed,
                 skipped);
        if (ran == 0 || failed != 0)
            $fatal(1, "FAIL");
        $display("PASS");
        $finish;
    end

endmodule
