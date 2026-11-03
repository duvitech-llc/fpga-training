`timescale 1ns/1ps

// A behavioural SPI NOR flash, for simulation only.
//
// This is our own model, written from the behaviour that SPI NOR datasheets
// typically describe. It is not a vendor model and it does not match any real
// part. The timing limits below are in the range that datasheets give, but
// they are made up. Use the numbers from your part's datasheet instead.
//
// It knows two commands:
//   0x9F  read the 3-byte JEDEC ID
//   0x03  read data from a 24-bit address, for as long as CS stays low
//
// Like a real NOR flash it supports SPI modes 0 and 3 only. It takes the mode
// from the level of SCLK when CS falls. It samples MOSI on the rising edge of
// SCLK and changes MISO after the falling edge.
//
// Each broken rule prints a line starting "FLASH VIOLATION" and adds one to
// `violations`. The README lists what the model does not check.
module spi_flash_model #(
    parameter        MEM_FILE    = "tb/flash.hex",
    parameter        MEM_BYTES   = 256,         // the address wraps at the end
    parameter [23:0] JEDEC_ID    = 24'h5A_40_14, // made up, not a real maker's code
    // Timing limits in ns. The names in brackets are the usual datasheet ones.
    parameter real   T_SCLK      = 20.0,  // shortest SCLK period (1 / fC)
    parameter real   T_SCLK_READ = 30.0,  // shortest SCLK period for 0x03 (1 / fR)
    parameter real   T_CSS       = 5.0,   // CS low to the first SCLK edge (tSLCH)
    parameter real   T_CSH       = 5.0,   // the last SCLK edge to CS high (tCHSH)
    parameter real   T_CSD       = 10.0,  // CS high between commands (tSHSL)
    parameter real   T_SU        = 2.0,   // MOSI set up before SCLK rises (tDVCH)
    parameter real   T_HD        = 3.0,   // MOSI held after SCLK rises (tCHDX)
    parameter real   T_V         = 6.0    // SCLK low to MISO valid (tCLQV)
) (
    input  wire cs_n,
    input  wire sclk,
    input  wire mosi,
    output wire miso
);

    reg [7:0] mem [0:MEM_BYTES-1];
    initial $readmemh(MEM_FILE, mem);

    integer violations = 0;

    reg        selected = 1'b0;  // CS has fallen and not yet risen
    reg        mode3;            // SCLK was high when CS fell
    reg        any_edge;         // an SCLK edge since CS fell
    reg        any_rise;
    reg        any_fall;
    integer    bits;             // MOSI bits taken since CS fell
    reg [7:0]  in_byte;
    reg [7:0]  cmd;
    reg [8*72-1:0] msg;
    reg [23:0] addr;
    reg        out_en  = 1'b0;
    reg        out_bit = 1'b0;

    realtime t_cs_fall;
    realtime t_cs_rise = -1000.0;
    realtime t_rise;
    realtime t_fall;
    realtime t_edge;
    realtime t_mosi = -1000.0;    // when MOSI last changed

    assign miso = out_en ? out_bit : 1'bz;

    integer txn_violations = 0;  // in this transaction, to keep the log short

    task violation(input [8*72-1:0] what);
        begin
            if (txn_violations < 3)
                $display("FLASH VIOLATION t=%0t: %0s", $time, what);
            txn_violations = txn_violations + 1;
            violations     = violations + 1;
        end
    endtask

    // Edge-triggered, so that Verilator treats it as a process and not as logic.
    always @(posedge mosi or negedge mosi)
        t_mosi = $realtime;

    always @(negedge cs_n) begin
        txn_violations = 0;
        if ($realtime - t_cs_rise < T_CSD)
            violation("CS high for too short a time between commands");
        selected  = 1'b1;
        t_cs_fall = $realtime;
        mode3     = sclk;
        any_edge  = 1'b0;
        any_rise  = 1'b0;
        any_fall  = 1'b0;
        bits      = 0;
        cmd       = 8'h00;
        out_en    = 1'b0;
    end

    always @(posedge cs_n) begin
        if (selected) begin
            if (bits % 8 != 0)
                violation("CS rose in the middle of a byte");
            if (any_edge && $realtime - t_edge < T_CSH)
                violation("CS rose too soon after the last SCLK edge");
            if (sclk !== mode3)
                violation("SCLK idle level at CS high differs from CS low");
            if (txn_violations > 3)
                $display("FLASH VIOLATION t=%0t: and %0d more in this transaction",
                         $time, txn_violations - 3);
            selected  = 1'b0;
            t_cs_rise = $realtime;
            out_en    = 1'b0;
        end
    end

    // Checks shared by both edges.
    task edge_checks;
        begin
            if (!any_edge && $realtime - t_cs_fall < T_CSS)
                violation("first SCLK edge too soon after CS fell");
            any_edge = 1'b1;
            t_edge   = $realtime;
        end
    endtask

    // The period limit depends on the command once it is known.
    function real period_limit(input dummy);
        period_limit = (bits >= 8 && cmd == 8'h03) ? T_SCLK_READ : T_SCLK;
    endfunction

    always @(posedge sclk) begin
        if (selected) begin
            edge_checks;
            if (any_rise && $realtime - t_rise < period_limit(1'b0))
                violation("SCLK faster than this command allows");
            if (any_fall && $realtime - t_fall < 0.45 * period_limit(1'b0))
                violation("SCLK low time too short");
            any_rise = 1'b1;
            t_rise   = $realtime;

            // Take the bit at the end of the hold time. If MOSI moved anywhere
            // in the window from T_SU before the edge to T_HD after it, the
            // real part might latch either value. This model takes the newer
            // one, which is what a hold violation usually gives, and says so.
            #(T_HD);
            if (t_mosi > t_rise - T_SU)
                violation("MOSI changed within the setup and hold window of SCLK rising");
            take_bit(mosi);
        end
    end

    task take_bit(input b);
        begin
            in_byte = {in_byte[6:0], b};
            bits    = bits + 1;
            if (bits % 8 == 0) begin
                if (bits == 8) begin
                    cmd = in_byte;
                    if (cmd != 8'h9F && cmd != 8'h03) begin
                        $sformat(msg, "unsupported command %h", cmd);
                        violation(msg);
                    end
                end else if (cmd == 8'h03 && bits <= 32) begin
                    addr = {addr[15:0], in_byte};
                end
            end
        end
    endtask

    // After the falling edge, put out the bit for the next rising edge. bits
    // counts the rising edges so far, so it says which byte and bit that is.
    always @(negedge sclk) begin : drive
        integer   k;
        integer   i;
        reg [7:0] b;
        if (selected) begin
            edge_checks;
            if (any_rise && $realtime - t_rise < 0.45 * period_limit(1'b0))
                violation("SCLK high time too short");
            any_fall = 1'b1;
            t_fall   = $realtime;

            k = bits / 8;
            i = bits % 8;
            if (cmd == 8'h9F && k >= 1 && k <= 3) begin
                b = JEDEC_ID[8 * (3 - k) +: 8];
                out_en  <= #(T_V) 1'b1;
                out_bit <= #(T_V) b[7 - i];
            end else if (cmd == 8'h03 && k >= 4) begin
                b = mem[({8'd0, addr} + k - 4) % MEM_BYTES];
                out_en  <= #(T_V) 1'b1;
                out_bit <= #(T_V) b[7 - i];
            end else begin
                out_en  <= #(T_V) 1'b0;
            end
        end
    end

endmodule
