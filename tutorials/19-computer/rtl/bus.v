// The data bus between the CPU and everything it can read or write. It has no
// storage except rsel: it decodes the address, and it picks the read data.
//
//   0x00 to 0xEF  RAM
//   0xF0          UART status. Any write clears the error bit.
//   0xF1          Read the next received byte. Write a byte to transmit.
//   0xF2          LED register
//   0xF3 to 0xFF  Read as 0, and ignore writes
//
// The data for a read comes back on the clock after re, as with RAM. By then the
// address may have moved on, so rsel remembers which device the read was for. The RAM
// and the received byte are captured at the clock edge where re is high. Status and
// the LED register are not: they are shown live, as they are on that later clock.
module bus (
    input  wire       clk,
    input  wire       rst,           // synchronous, active high
    input  wire [7:0] addr,
    input  wire       re,
    input  wire       we,
    output wire [7:0] rdata,         // one clock after re
    output wire       ram_re,
    output wire       ram_we,
    output wire       status_write,  // clears the error bit
    output wire       rx_read,       // takes the waiting byte
    output wire       tx_write,      // hands a byte to the transmitter
    output wire       led_write,
    input  wire [7:0] ram_rdata,     // the other devices' data, one per device
    input  wire [7:0] status,
    input  wire [7:0] rx_byte,
    input  wire [7:0] led
);

    localparam [2:0] R_NONE   = 3'd0;
    localparam [2:0] R_RAM    = 3'd1;
    localparam [2:0] R_STATUS = 3'd2;
    localparam [2:0] R_RX     = 3'd3;
    localparam [2:0] R_LED    = 3'd4;

    // The address decoder. At most one of these is high. Above 0xF2, none of them is.
    wire sel_ram    = (addr < 8'hF0);
    wire sel_status = (addr == 8'hF0);
    wire sel_uart   = (addr == 8'hF1);
    wire sel_led    = (addr == 8'hF2);

    // Anything that changes state needs re or we as well as the address. The CPU's
    // address wires carry junk on most clocks, and that must do nothing.
    assign ram_re       = re && sel_ram;
    assign ram_we       = we && sel_ram;
    assign status_write = we && sel_status;
    assign rx_read      = re && sel_uart;
    assign tx_write     = we && sel_uart;
    assign led_write    = we && sel_led;

    wire [2:0] sel_code = sel_ram    ? R_RAM    :
                          sel_status ? R_STATUS :
                          sel_uart   ? R_RX     :
                          sel_led    ? R_LED    :
                                       R_NONE;

    // Which device the last read was for.
    reg [2:0] rsel;

    always @(posedge clk) begin
        if (rst)
            rsel <= R_NONE;
        else if (re)
            rsel <= sel_code;
    end

    assign rdata = (rsel == R_RAM)    ? ram_rdata :
                   (rsel == R_STATUS) ? status    :
                   (rsel == R_RX)     ? rx_byte   :
                   (rsel == R_LED)    ? led       :
                                        8'd0;

`ifdef FORMAL
    // addr, re, we and the read data are all free inputs, so this holds for any
    // CPU, not only ours. Nothing here looks inside the CPU, the RAM or the UART.
    reg past_valid = 1'b0;
    always @(posedge clk)
        past_valid <= 1'b1;

    always @(posedge clk) begin
        if (!past_valid)
            assume (rst);
    end

    // The spec's map, written a second way so it cannot share a typo with the code.
    wire [2:0] f_expected = (addr[7:4] != 4'hF) ? R_RAM    :
                            (addr[3:0] == 4'h0) ? R_STATUS :
                            (addr[3:0] == 4'h1) ? R_RX     :
                            (addr[3:0] == 4'h2) ? R_LED    :
                                                  R_NONE;

    wire f_io      = (addr[7:4] == 4'hF);
    wire f_nothing = f_io && (addr[3:0] > 4'h2);  // the unused addresses, which read as 0

    always @(posedge clk) begin
        // Exactly one is selected, and it is the one in the map.
        assert ({2'd0, sel_ram} + {2'd0, sel_status} + {2'd0, sel_uart} +
                {2'd0, sel_led} + {2'd0, f_nothing} == 3'd1);
        assert (sel_code == f_expected);

        // RAM is never touched at an I/O address.
        if (f_io)
            assert (!ram_we && !ram_re);

        // With re low, a read has no side effect, whatever the address says.
        if (!re)
            assert (!rx_read && !ram_re);

        // With we low, nothing is written.
        if (!we)
            assert (!ram_we && !status_write && !tx_write && !led_write);

        // Each strobe fires for its own address and no other.
        assert (ram_we       == (we && !f_io));
        assert (ram_re       == (re && !f_io));
        assert (status_write == (we && addr == 8'hF0));
        assert (rx_read      == (re && addr == 8'hF1));
        assert (tx_write     == (we && addr == 8'hF1));
        assert (led_write    == (we && addr == 8'hF2));

        // rsel only ever holds a named device.
        if (past_valid)
            assert (rsel <= R_LED);

        // The read select, one clock later. It matches the address of the read,
        // wherever addr has gone since, and holds until the next read.
        if (past_valid && $past(rst))
            assert (rsel == R_NONE);
        if (past_valid && !$past(rst) && $past(re))
            assert (rsel == $past(f_expected));
        if (past_valid && !$past(rst) && !$past(re))
            assert (rsel == $past(rsel));

        // The data on rdata comes from that device.
        case (rsel)
            R_RAM:    assert (rdata == ram_rdata);
            R_STATUS: assert (rdata == status);
            R_RX:     assert (rdata == rx_byte);
            R_LED:    assert (rdata == led);
            default:  assert (rdata == 8'd0);
        endcase
    end

    // Each kind of read can finish, even with the address already somewhere else.
    always @(posedge clk) begin
        if (past_valid && !$past(rst) && $past(re)) begin
            cover (rsel == R_RAM    && addr != $past(addr));
            cover (rsel == R_STATUS && addr != $past(addr));
            cover (rsel == R_RX     && addr != $past(addr));
            cover (rsel == R_LED    && addr != $past(addr));
            cover (rsel == R_NONE   && addr != $past(addr));
        end
    end
`endif

endmodule
