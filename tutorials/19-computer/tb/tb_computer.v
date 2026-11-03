`timescale 1ns/1ps

// Runs real programs on the whole computer, and judges them only by what comes out of
// the pins. An independent decoder below turns uart_tx back into bytes at bit level,
// and send_frame drives uart_rx at bit level. Inputs change on falling edges.
module tb_computer #(
    parameter CLKS_PER_BIT = 16
);

    localparam integer TIMEOUT    = 200000;
    localparam integer FRAME      = 10 * CLKS_PER_BIT;
    localparam integer MAX_OUTPUT = 64;

    reg clk = 1'b0;
    reg rst = 1'b1;
    reg uart_rx = 1'b1;

    wire       uart_tx;
    wire [7:0] led;
    wire       halted, illegal;

    computer #(.CLKS_PER_BIT(CLKS_PER_BIT)) dut (
        .clk(clk), .rst(rst), .uart_rx(uart_rx), .uart_tx(uart_tx),
        .led(led), .halted(halted), .illegal(illegal)
    );

    always #5 clk = ~clk;

    integer errors = 0;
    integer i;

    // ----- The decoder: uart_tx back to bytes, with every clock of every bit checked -----

    reg [7:0] output_bytes [0:MAX_OUTPUT-1];
    integer   output_count = 0;

    integer   frame_bit = -1;   // -1 is idle, 0 is the start bit, 9 is the stop bit
    integer   bit_clock = 0;
    reg       bit_level = 1'b1;
    reg [7:0] frame_data = 8'd0;

    // The line must hold one level for all CLKS_PER_BIT clocks of a bit.
    task end_of_bit;
        begin
            if (frame_bit >= 1 && frame_bit <= 8)
                frame_data[frame_bit - 1] = bit_level;
            if (frame_bit == 9) begin
                if (bit_level !== 1'b1) begin
                    $display("FAIL t=%0t stop bit on uart_tx is low", $time);
                    errors = errors + 1;
                end
                if (output_count < MAX_OUTPUT)
                    output_bytes[output_count] = frame_data;
                output_count = output_count + 1;
                frame_bit = -1;
            end else begin
                frame_bit = frame_bit + 1;
            end
            bit_clock = 0;
        end
    endtask

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

        if (frame_bit != -1 && bit_clock == CLKS_PER_BIT)
            end_of_bit;
    end

    // ----- Counters for the summary lines, and the LED sequence -----

    integer   status_reads = 0;
    integer   led_changes = 0;
    reg [7:0] led_before = 8'd0;
    reg       led_step_bad = 1'b0;

    always @(posedge clk) begin
        if (rst) begin
            status_reads = 0;
            led_changes  = 0;
            led_before   = 8'd0;
            led_step_bad = 1'b0;
        end else begin
            if (dut.dmem_re === 1'b1 && dut.dmem_addr === 8'hF0)
                status_reads = status_reads + 1;
            if (led !== led_before) begin
                led_changes = led_changes + 1;
                if (led !== led_before + 8'd1)
                    led_step_bad = 1'b1;
                led_before = led;
            end
        end
    end

    // ----- Tasks -----

    task send_frame(input [7:0] data, input stop);
        integer b;
        begin
            uart_rx = 1'b0;
            repeat (CLKS_PER_BIT) @(negedge clk);
            for (b = 0; b < 8; b = b + 1) begin
                uart_rx = data[b];
                repeat (CLKS_PER_BIT) @(negedge clk);
            end
            uart_rx = stop;
            repeat (CLKS_PER_BIT) @(negedge clk);
            uart_rx = 1'b1;
            repeat (CLKS_PER_BIT) @(negedge clk);
        end
    endtask

    // Loads a program, empties RAM and output, and holds reset for two clocks.
    task load(input [8*32-1:0] hex);
        begin
            @(negedge clk);
            rst = 1'b1;
            $readmemh(hex, dut.imem);
            for (i = 0; i < 240; i = i + 1)
                dut.ram[i] = 8'd0;
            output_count = 0;
            @(negedge clk);
            @(negedge clk);
            rst = 1'b0;
        end
    endtask

    // The limits stop a bad design hanging the test.
    task wait_for_halt;
        integer limit;
        begin
            limit = 0;
            while (halted !== 1'b1 && limit < TIMEOUT) begin
                @(negedge clk);
                limit = limit + 1;
            end
            if (halted !== 1'b1 || illegal !== 1'b0) begin
                $display("FAIL after %0d clocks, halted=%b illegal=%b pc=%h",
                         limit, halted, illegal, dut.u_cpu.pc);
                errors = errors + 1;
            end
        end
    endtask

    task wait_for_output(input integer count);
        integer limit;
        begin
            limit = 0;
            while (output_count < count && limit < 8 * FRAME + TIMEOUT / 4) begin
                @(negedge clk);
                limit = limit + 1;
            end
            if (output_count < count) begin
                $display("FAIL only %0d bytes arrived, expected %0d", output_count, count);
                errors = errors + 1;
            end
        end
    endtask

    task wait_for_led(input [7:0] value);
        integer limit;
        begin
            limit = 0;
            while (led !== value && limit < TIMEOUT) begin
                @(negedge clk);
                limit = limit + 1;
            end
            if (led !== value) begin
                $display("FAIL led=%h, expected %h, pc=%h", led, value, dut.u_cpu.pc);
                errors = errors + 1;
            end
        end
    endtask

    // Prints what was decoded, in quotes. This line is the program's real output.
    task show_output(input [8*16-1:0] name);
        integer n;
        begin
            $write("%0s: \"", name);
            for (n = 0; n < output_count && n < MAX_OUTPUT; n = n + 1)
                $write("%c", output_bytes[n]);
            $write("\"\n");
        end
    endtask

    // text holds count characters, first character in the highest byte used.
    task check_output(input [8*32-1:0] text, input integer count);
        integer n;
        reg [7:0] want;
        begin
            if (output_count !== count) begin
                $display("FAIL %0d bytes on uart_tx, expected %0d", output_count, count);
                errors = errors + 1;
            end
            for (n = 0; n < count && n < output_count; n = n + 1) begin
                want = text[8 * (count - 1 - n) +: 8];
                if (output_bytes[n] !== want) begin
                    $display("FAIL byte %0d on uart_tx is %h, expected %h",
                             n, output_bytes[n], want);
                    errors = errors + 1;
                end
            end
        end
    endtask

    task check_ram(input [7:0] addr, input [7:0] expected);
        begin
            if (dut.ram[addr] !== expected) begin
                $display("FAIL ram[%h]=%h expected=%h", addr, dut.ram[addr], expected);
                errors = errors + 1;
            end
        end
    endtask

    // ----- The programs -----

    // HALT stops the CPU, not the UART, so the last frame finishes after it.
    task test_hello;
        begin
            load("build/hello.hex");
            wait_for_halt;
            if (output_count >= 5) begin
                $display("FAIL the last byte finished before HALT");
                errors = errors + 1;
            end
            repeat (3 * FRAME) @(negedge clk);
            show_output("hello");
            check_output("hello", 5);
            $display("hello: %0d status reads", status_reads);
            if (status_reads < 5) begin
                $display("FAIL hello did not poll");
                errors = errors + 1;
            end
        end
    endtask

    // Each byte waits for the one before it to come back.
    task test_echo;
        localparam integer LENGTH = 16;
        reg [8*LENGTH-1:0] text;
        reg [8*LENGTH-1:0] upper;
        integer n;
        begin
            text  = "Hello, FPGA 19!~";
            upper = "HELLO, FPGA 19!~";
            load("build/echo.hex");
            repeat (20) @(negedge clk);
            for (n = LENGTH - 1; n >= 0; n = n - 1) begin
                send_frame(text[8 * n +: 8], 1'b1);
                wait_for_output(LENGTH - n);
            end
            repeat (2 * FRAME) @(negedge clk);
            show_output("echo");
            check_output({128'd0, upper}, LENGTH);
            if (halted !== 1'b0) begin
                $display("FAIL echo should run for ever");
                errors = errors + 1;
            end
        end
    endtask

    task test_leds;
        begin
            load("build/leds.hex");
            wait_for_halt;
            $display("leds: %0d changes, ending at %h", led_changes, led);
            if (led_changes !== 256 || led_step_bad !== 1'b0 || led !== 8'h00) begin
                $display("FAIL leds: changes=%0d bad step=%b led=%h",
                         led_changes, led_step_bad, led);
                errors = errors + 1;
            end
        end
    endtask

    task test_io_rules;
        begin
            load("build/io_rules.hex");
            wait_for_led(8'd1);
            send_frame(8'hC3, 1'b1);
            wait_for_led(8'd2);
            send_frame(8'h55, 1'b0);
            wait_for_led(8'd3);
            repeat (200) @(negedge clk);
            send_frame(8'h11, 1'b1);
            send_frame(8'h22, 1'b1);
            send_frame(8'h00, 1'b0);
            wait_for_halt;
            repeat (3 * FRAME) @(negedge clk);

            check_ram(8'h10, 8'h01);  // status after reset
            check_ram(8'h11, 8'h00);  // transmitter busy
            check_ram(8'h12, 8'h5A);  // LED reads back
            check_ram(8'h13, 8'h01);  // 0xF3 to 0xFF read as 0
            check_ram(8'h14, 8'h03);  // junk on the address wires took nothing
            check_ram(8'h15, 8'hC3);  // the byte
            check_ram(8'h16, 8'h01);  // reading cleared rx waiting
            check_ram(8'h17, 8'hC3);  // the old byte again
            check_ram(8'h18, 8'h05);  // framing error, and no byte waiting
            check_ram(8'h19, 8'h05);  // not cleared by a read or by other writes
            check_ram(8'h1A, 8'h01);  // cleared by a write to status
            check_ram(8'h1B, 8'h22);  // the newer of two bytes
            check_ram(8'h1C, 8'hAA);  // reached the end
            check_ram(8'h40, 8'h03);  // a write to RAM worked in the middle of it all

            // "A" went, "B" was lost, and "C" came from a PUSH.
            show_output("io_rules");
            check_output("AC", 2);
        end
    endtask

    // Reset in the middle of a frame must leave a clean line and a clean restart.
    task test_reset;
        begin
            load("build/io_rules.hex");
            wait_for_led(8'h5A);
            wait_for_led(8'd1);
            send_frame(8'hC3, 1'b1);
            @(negedge clk);
            rst = 1'b1;
            @(negedge clk);
            @(negedge clk);
            if (uart_tx !== 1'b1 || led !== 8'd0 || dut.status !== 8'h00) begin
                $display("FAIL during reset, tx=%b led=%h status=%h", uart_tx, led, dut.status);
                errors = errors + 1;
            end
            rst = 1'b0;
            @(negedge clk);
            if (dut.status !== 8'h01) begin
                $display("FAIL after reset status=%h", dut.status);
                errors = errors + 1;
            end
            load("build/hello.hex");
            repeat (FRAME + 200) @(negedge clk);
            @(negedge clk);
            rst = 1'b1;
            @(negedge clk);
            @(negedge clk);
            rst = 1'b0;
            wait_for_halt;
            repeat (3 * FRAME) @(negedge clk);
            show_output("reset");
            if (output_count < 5 || output_bytes[output_count - 5] !== "h") begin
                $display("FAIL hello did not restart after a reset mid-frame");
                errors = errors + 1;
            end
        end
    endtask

    // For the reader's own program. It is shown, not checked.
    task test_exercise;
        begin
            load("build/exercise.hex");
            repeat (20) @(negedge clk);
            send_frame(8'h5A, 1'b1);
            repeat (4 * FRAME) @(negedge clk);
            show_output("exercise");
        end
    endtask

    initial begin
        $dumpfile("build/tb_computer.vcd");
        $dumpvars(0, tb_computer);

        repeat (3) @(negedge clk);

        test_hello;
        test_echo;
        test_leds;
        test_io_rules;
        test_reset;
        test_exercise;

        if (errors == 0)
            $display("PASS");
        else
            $display("FAIL: %0d errors", errors);
        $finish;
    end

endmodule
