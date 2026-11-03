// The whole computer: the CPU from Tutorial 17, an instruction memory, 240 bytes of
// RAM, the UART from Tutorial 14 and an LED register, joined by bus.
//
// PROGRAM names a .hex file for $readmemh. Left empty, memory starts as all NOPs and
// a testbench loads it. RAM starts as 0 here to keep tests repeatable. A real RAM
// holds whatever it powered up with.
module computer #(
    parameter CLKS_PER_BIT = 16,
    parameter PROGRAM      = ""
) (
    input  wire       clk,
    input  wire       rst,      // synchronous, active high
    input  wire       uart_rx,  // asynchronous: uart_rx synchronizes it
    output wire       uart_tx,
    output reg  [7:0] led,
    output wire       halted,
    output wire       illegal
);

    reg [15:0] imem [0:255];
    reg [7:0]  ram  [0:239];

    wire [7:0]  imem_addr, dmem_addr, dmem_wdata, dmem_rdata;
    reg  [15:0] imem_data;
    reg  [7:0]  ram_rdata;
    wire        dmem_re, dmem_we;

    wire ram_re, ram_we, status_write, rx_read, tx_write, led_write;

    // cpu reports each instruction it retires, which matters to testbenches only.
    wire        unused_retire;
    wire [7:0]  unused_retire_pc;
    wire [15:0] unused_retire_instr;

    // One or the other, never both. With this loop first and $readmemh after it,
    // simulation loaded the program, but Yosys kept the zeros and lost the program.
    integer i;
    initial begin
        if (PROGRAM != "")
            $readmemh(PROGRAM, imem);
        else
            for (i = 0; i < 256; i = i + 1)
                imem[i] = 16'd0;
        for (i = 0; i < 240; i = i + 1)
            ram[i] = 8'd0;
    end

    always @(posedge clk)
        imem_data <= imem[imem_addr];

    always @(posedge clk) begin
        if (ram_we)
            ram[dmem_addr] <= dmem_wdata;
        if (ram_re)
            ram_rdata <= ram[dmem_addr];
    end

    cpu u_cpu (
        .clk(clk),
        .rst(rst),
        .imem_addr(imem_addr),
        .imem_data(imem_data),
        .dmem_addr(dmem_addr),
        .dmem_re(dmem_re),
        .dmem_we(dmem_we),
        .dmem_wdata(dmem_wdata),
        .dmem_rdata(dmem_rdata),
        .halted(halted),
        .illegal(illegal),
        .retire(unused_retire),
        .retire_pc(unused_retire_pc),
        .retire_instr(unused_retire_instr)
    );

    // ----- The UART and its registers -----

    wire       tx_ready, rx_valid, rx_error;
    wire [7:0] rx_data;

    // uart_tx ignores tx_valid unless tx_ready is high, so a write while it is busy
    // loses the byte, as the spec says. Programs poll status.
    uart #(.CLKS_PER_BIT(CLKS_PER_BIT)) u_uart (
        .clk(clk),
        .rst(rst),
        .tx_valid(tx_write),
        .tx_data(dmem_wdata),
        .tx_ready(tx_ready),
        .tx(uart_tx),
        .rx(uart_rx),
        .rx_valid(rx_valid),
        .rx_data(rx_data),
        .rx_error(rx_error)
    );

    reg [7:0] rx_hold;     // the byte waiting to be read
    reg       rx_waiting;
    reg       rx_err_seen;
    reg [7:0] rx_rdata;    // rx_hold as it was at the edge of the read

    // A new byte can land on the very edge of a read. The read gets the old byte
    // from rx_rdata, and the new one is left waiting, so nothing is lost. A byte
    // that arrives while one is already waiting replaces it.
    always @(posedge clk) begin
        if (rst) begin
            rx_hold     <= 8'd0;
            rx_waiting  <= 1'b0;
            rx_err_seen <= 1'b0;
            rx_rdata    <= 8'd0;
            led         <= 8'd0;
        end else begin
            if (rx_read)
                rx_rdata <= rx_hold;

            if (rx_valid) begin
                rx_hold    <= rx_data;
                rx_waiting <= 1'b1;
            end else if (rx_read) begin
                rx_waiting <= 1'b0;
            end

            if (rx_error)
                rx_err_seen <= 1'b1;
            else if (status_write)
                rx_err_seen <= 1'b0;

            if (led_write)
                led <= dmem_wdata;
        end
    end

    wire [7:0] status = {5'd0, rx_err_seen, rx_waiting, tx_ready};

    // ----- The bus -----

    bus u_bus (
        .clk(clk),
        .rst(rst),
        .addr(dmem_addr),
        .re(dmem_re),
        .we(dmem_we),
        .rdata(dmem_rdata),
        .ram_re(ram_re),
        .ram_we(ram_we),
        .status_write(status_write),
        .rx_read(rx_read),
        .tx_write(tx_write),
        .led_write(led_write),
        .ram_rdata(ram_rdata),
        .status(status),
        .rx_byte(rx_rdata),
        .led(led)
    );

endmodule
