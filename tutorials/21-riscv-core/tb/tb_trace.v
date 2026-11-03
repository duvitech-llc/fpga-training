`timescale 1ns/1ps

// Replays what the reference model did, as in Tutorial 18. tools/iss.py runs each
// program and writes one trace line per instruction. This testbench runs the same
// program on the core, and after each instruction compares the PC, all 32 registers
// and any memory write with the next line. It stops a program at its first difference.
//
// The memory is a model in this file. It answers on the falling edge, like every
// other input here, after a number of wait clocks that depends on the mode:
//   0  no wait: mem_ready is high in the first clock of mem_valid
//   1  one wait, like a synchronous RAM
//   2  0 to 3 waits, from a pseudo-random sequence, so Icarus and Verilator match
// While mem_ready is low, mem_rdata holds junk, so a core that reads early fails.
//
// It also times every instruction. An instruction must take exactly 2 clocks, or 3
// for a load or store, plus every clock the memory made it wait. It prints the
// clocks per instruction for each class and each mode.
module tb_trace;

    localparam integer WORDS   = 16384;     // 64 KiB
    localparam integer LINES   = 4096;
    localparam integer TIMEOUT = 40;        // most clocks between two retires

    // A trace line: pc, instr, next_pc, rd value, info, write address, write data.
    // info is {4'b0, wstrb, 4'b0, cause, 3'b0, trap, 3'b0, writes rd, 3'b0, rd}.
    localparam [223:0] END_OF_TRACE = {224{1'b1}};

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

    // The registers, by path, as in Tutorial 18.
    wire [31:0] x [0:31];
    genvar g;
    generate
        for (g = 0; g < 32; g = g + 1) begin : gen_x
            assign x[g] = dut.u_regs.q[g];
        end
    endgenerate

    // ----- The memory -----

    reg  [31:0] mem [0:WORDS-1];
    reg  [31:0] random = 32'h2545F491;   // xorshift32, the same in both simulators
    integer     mode = 0;
    integer     wait_left = 0;
    reg         busy = 1'b0;             // a transfer has started and not finished
    integer     waits = 0;               // wait clocks since the last retire

    wire [13:0] index = mem_addr[15:2];  // 64 KiB, repeated through the address space

    // What the memory saw while a transfer waited, to check that nothing moved.
    reg  [68:0] held;
    wire [68:0] request = {mem_instr, mem_addr, mem_wdata, mem_wstrb};

    // The last store, waiting for its instruction to retire.
    reg         wrote = 1'b0;
    reg  [31:0] wrote_addr, wrote_data;
    reg  [3:0]  wrote_strb;

    integer errors = 0;

    function [31:0] next_random(input [31:0] r);
        reg [31:0] s;
        begin
            s = r ^ (r << 13);
            s = s ^ (s >> 17);
            next_random = s ^ (s << 5);
        end
    endfunction

    function [31:0] strobed(input [31:0] data, input [3:0] strb);
        strobed = data & {{8{strb[3]}}, {8{strb[2]}}, {8{strb[1]}}, {8{strb[0]}}};
    endfunction

    always @(negedge clk) begin
        random = next_random(random);
        if (rst || mem_valid !== 1'b1) begin
            mem_ready <= 1'b0;
            busy = 1'b0;
        end else begin
            if (busy && !mem_ready && request !== held) begin
                $display("FAIL the core changed a request while it waited: %h, then %h",
                         held, request);
                errors = errors + 1;
            end

            // mem_ready was high at the last rising edge, so that transfer is done,
            // and mem_valid still high means the next one has begun.
            if (!busy || mem_ready) begin
                busy = 1'b1;
                held = request;
                wait_left = (mode == 0) ? 0 : (mode == 1) ? 1 : {30'd0, random[1:0]};
            end

            if (wait_left == 0) begin
                mem_ready <= 1'b1;
                mem_rdata <= mem[index];
                if (mem_wstrb != 4'd0) begin
                    if (mem_wstrb[0]) mem[index][7:0]   = mem_wdata[7:0];
                    if (mem_wstrb[1]) mem[index][15:8]  = mem_wdata[15:8];
                    if (mem_wstrb[2]) mem[index][23:16] = mem_wdata[23:16];
                    if (mem_wstrb[3]) mem[index][31:24] = mem_wdata[31:24];
                    if (wrote) begin
                        $display("FAIL two stores in one instruction");
                        errors = errors + 1;
                    end
                    wrote      = 1'b1;
                    wrote_addr = mem_addr;
                    wrote_strb = mem_wstrb;
                    wrote_data = strobed(mem_wdata, mem_wstrb);
                end
            end else begin
                mem_ready <= 1'b0;
                mem_rdata <= next_random(random);     // junk
                wait_left = wait_left - 1;
                waits = waits + 1;
            end
        end
    end

    // ----- Checking against the trace -----

    reg  [223:0] trace [0:LINES-1];
    reg  [31:0]  shadow [0:31];        // the registers, as the trace says they should be

    integer line   = 0;
    integer total  = 0;
    integer idle   = 0;
    integer clocks = 0;                // clocks in this instruction so far
    reg     stop   = 1'b0;
    reg     check_next = 1'b0;         // compare registers and pc on this clock
    reg     started = 1'b0;            // the first fetch has begun

    wire [223:0] expected = trace[line];
    wire [31:0]  e_pc     = expected[223:192];
    wire [31:0]  e_instr  = expected[191:160];
    wire [31:0]  e_next   = expected[159:128];
    wire [31:0]  e_value  = expected[127:96];
    wire [31:0]  e_info   = expected[95:64];
    wire [31:0]  e_addr   = expected[63:32];
    wire [31:0]  e_data   = expected[31:0];
    wire [4:0]   e_rd     = e_info[4:0];
    wire         e_writes = e_info[8];
    wire         e_trap   = e_info[12];
    wire [3:0]   e_cause  = e_info[19:16];
    wire [3:0]   e_strb   = e_info[27:24];

    // Clocks per instruction, by class and mode. Classes: 0 ALU register, 1 ALU
    // immediate, 2 LUI and AUIPC, 3 JAL and JALR, 4 branch, 5 load, 6 store, 7 FENCE.
    integer seen [0:23];
    integer spent [0:23];
    integer n;

    function integer class_of(input [31:0] instr);
        case (instr[6:0])
            7'b0110011: class_of = 0;
            7'b0010011: class_of = 1;
            7'b0110111, 7'b0010111: class_of = 2;
            7'b1101111, 7'b1100111: class_of = 3;
            7'b1100011: class_of = 4;
            7'b0000011: class_of = 5;
            7'b0100011: class_of = 6;
            default:    class_of = 7;
        endcase
    endfunction

    task fail(input [8*40-1:0] why);
        begin
            $display("FAIL %0s, line %0d", why, line);
            $display("  model pc=%h instr=%h next=%h rd=x%0d value=%h trap=%b cause=%0d",
                     e_pc, e_instr, e_next, e_rd, e_value, e_trap, e_cause);
            $display("  core  pc=%h instr=%h trap=%b cause=%0d",
                     retire_pc, retire_instr, trap, trap_cause);
            errors = errors + 1;
            stop = 1'b1;
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            idle    <= 0;
            clocks  <= 0;
            waits    = 0;
            started <= 1'b0;
            check_next <= 1'b0;
        end else if (!stop) begin
            // The clock after a retire: the new state is in place.
            if (check_next) begin
                check_next <= 1'b0;
                if (retire_pc !== e_next)
                    fail("the next pc differs");
                for (n = 1; n < 32; n = n + 1)
                    if (x[n] !== shadow[n]) begin
                        $display("  x%0d is %h, and should be %h", n, x[n], shadow[n]);
                        fail("a register differs");
                    end
                line = line + 1;
            end

            if (mem_valid === 1'b1)
                started <= 1'b1;
            if (started || mem_valid === 1'b1)
                clocks <= clocks + 1;

            if (retire === 1'b1) begin
                if (e_trap || retire_pc !== e_pc || retire_instr !== e_instr)
                    fail("a different instruction retired");
                else if (wrote !== (e_strb != 4'd0))
                    fail("a store happened, or did not");
                else if (wrote && (wrote_addr !== e_addr || wrote_strb !== e_strb
                                   || wrote_data !== e_data)) begin
                    $display("  core wrote %h with wstrb %b to %h", wrote_data, wrote_strb, wrote_addr);
                    $display("  model wrote %h with wstrb %b to %h", e_data, e_strb, e_addr);
                    fail("the store differs");
                end else begin
                    if (e_writes && e_rd != 5'd0)
                        shadow[e_rd] = e_value;
                    check_next <= 1'b1;

                    // Time it. clocks counts this one too.
                    n = class_of(retire_instr) + 8 * mode;
                    seen[n]  = seen[n] + 1;
                    spent[n] = spent[n] + clocks + 1;
                    if (clocks + 1 != waits + ((n % 8 == 5 || n % 8 == 6) ? 3 : 2)) begin
                        $display("  %0d clocks, with %0d of them waits", clocks + 1, waits);
                        fail("an instruction took the wrong time");
                    end
                end
                wrote   = 1'b0;
                waits   = 0;
                clocks <= 0;
                idle   <= 0;
                total   = total + 1;
            end else if (trap === 1'b1) begin
                if (!e_trap || retire_pc !== e_pc || retire_instr !== e_instr
                    || trap_cause !== e_cause || wrote)
                    fail("a different trap");
                stop = 1'b1;
                line = line + 1;
            end else begin
                idle <= idle + 1;
                if (idle > TIMEOUT)
                    fail("nothing retired for too long");
            end
        end
    end

    integer file;

    // Runs one program from reset, and checks that the whole trace was used.
    task run(input [8*32-1:0] hex, input [8*32-1:0] golden);
        begin
            @(negedge clk);
            rst = 1'b1;
            for (n = 0; n < WORDS; n = n + 1)
                mem[n] = 32'd0;
            for (n = 0; n < 32; n = n + 1)
                shadow[n] = 32'd0;
            // $readmemh would warn that the files are shorter than the arrays.
            file = $fopen(hex, "r");
            for (n = 0; $fscanf(file, "%h\n", mem[n]) == 1; n = n + 1) ;
            $fclose(file);
            file = $fopen(golden, "r");
            for (n = 0; $fscanf(file, "%h\n", trace[n]) == 1; n = n + 1) ;
            $fclose(file);
            line = 0;
            stop = 1'b0;
            wrote = 1'b0;
            @(negedge clk);
            @(negedge clk);
            rst = 1'b0;

            while (!stop)
                @(negedge clk);

            if (errors == 0 && expected !== END_OF_TRACE) begin
                $display("FAIL stopped after %0d instructions, but the trace goes on", line);
                errors = errors + 1;
            end
            if (errors == 0 && (trap !== 1'b1 || trap_cause !== 4'd3)) begin
                $display("FAIL trap=%b cause=%0d at the end, not EBREAK", trap, trap_cause);
                errors = errors + 1;
            end
            $display("%0s, wait mode %0d: %0d instructions compared", hex, mode, line);
        end
    endtask

    task run_all;
        begin
            run("build/sum.hex", "build/sum.trace");
            run("build/fibonacci.hex", "build/fibonacci.trace");
            run("build/alu.hex", "build/alu.trace");
            run("build/shifts.hex", "build/shifts.trace");
            run("build/branches.hex", "build/branches.trace");
            run("build/subword.hex", "build/subword.trace");
            run("build/memcpy.hex", "build/memcpy.trace");
            run("build/calls.hex", "build/calls.trace");
            run("build/x0.hex", "build/x0.trace");
        end
    endtask

    task report(input integer m);
        integer c;
        begin
            for (c = 0; c < 8; c = c + 1)
                if (seen[c + 8 * m] > 0)
                    $display("  mode %0d %0s %5d instructions, %0.2f clocks each", m,
                             c == 0 ? "ALU register " : c == 1 ? "ALU immediate" :
                             c == 2 ? "LUI, AUIPC   " : c == 3 ? "JAL, JALR    " :
                             c == 4 ? "branch       " : c == 5 ? "load         " :
                             c == 6 ? "store        " : "FENCE        ",
                             seen[c + 8 * m], 1.0 * spent[c + 8 * m] / seen[c + 8 * m]);
        end
    endtask

    integer all_seen, all_spent, c2;

    initial begin
        $dumpfile("build/tb_trace.vcd");
        $dumpvars(0, tb_trace);

        for (n = 0; n < 24; n = n + 1) begin
            seen[n]  = 0;
            spent[n] = 0;
        end

        for (mode = 0; mode < 3; mode = mode + 1)
            run_all;

        for (mode = 0; mode < 3; mode = mode + 1) begin
            report(mode);
            all_seen = 0;
            all_spent = 0;
            for (c2 = 0; c2 < 8; c2 = c2 + 1) begin
                all_seen  = all_seen + seen[c2 + 8 * mode];
                all_spent = all_spent + spent[c2 + 8 * mode];
            end
            $display("  mode %0d all           %5d instructions, %0.2f clocks each", mode,
                     all_seen, 1.0 * all_spent / all_seen);
        end

        if (errors == 0)
            $display("PASS: %0d instructions matched the model", total);
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
