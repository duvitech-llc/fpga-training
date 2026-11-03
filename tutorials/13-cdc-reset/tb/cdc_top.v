// Two clock domains and everything that joins them, for the testbenches. One
// arst fans out to a reset_sync in each domain. Domain a sends to domain b.
module cdc_top (
    input  wire clk_a,
    input  wire clk_b,
    input  wire arst,
    input  wire a_level,
    input  wire a_pulse,
    output wire rst_a,
    output wire rst_b,
    output wire b_level,
    output wire b_pulse,    // a_pulse through pulse_sync
    output wire b_naive     // a_pulse through sync_2ff, and it loses pulses
);

    reset_sync a_reset (.clk(clk_a), .arst(arst), .rst(rst_a));
    reset_sync b_reset (.clk(clk_b), .arst(arst), .rst(rst_b));

    sync_2ff level_sync (.clk(clk_b), .rst(rst_b), .d(a_level), .q(b_level));

    pulse_sync pulse (
        .src_clk(clk_a), .src_rst(rst_a), .src_pulse(a_pulse),
        .dst_clk(clk_b), .dst_rst(rst_b), .dst_pulse(b_pulse)
    );

    // The obvious way to cross a pulse: synchronize it, then find its rising edge.
    wire b_raw;
    reg  b_raw_last;

    sync_2ff naive_sync (.clk(clk_b), .rst(rst_b), .d(a_pulse), .q(b_raw));

    always @(posedge clk_b) begin
        if (rst_b)
            b_raw_last <= 1'b0;
        else
            b_raw_last <= b_raw;
    end

    assign b_naive = b_raw && !b_raw_last;

endmodule
