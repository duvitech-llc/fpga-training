// Proves that neither LFSR ever reaches 0 unless it is loaded with 0.
module lfsr_formal #(
    parameter [15:0] POLY = 16'h6801
) (
    input wire clk
);

    (* anyseq *) reg        en;
    (* anyseq *) reg        load;
    (* anyseq *) reg [15:0] load_value;

    reg  past_valid = 1'b0;
    wire rst = !past_valid;

    wire [15:0] fib_q;
    wire [15:0] gal_q;

    lfsr_fib #(.WIDTH(16), .POLY(POLY)) fib (
        .clk(clk), .rst(rst), .en(en), .load(load), .load_value(load_value),
        .q(fib_q), .out()
    );

    lfsr_galois #(.WIDTH(16), .POLY(POLY)) gal (
        .clk(clk), .rst(rst), .en(en), .load(load), .load_value(load_value),
        .q(gal_q), .out()
    );

    always @(posedge clk)
        past_valid <= 1'b1;

    always @(*) begin
        if (load)
            assume (load_value != 16'd0);
        if (past_valid) begin
            assert (fib_q != 16'd0);
            assert (gal_q != 16'd0);
        end
    end

endmodule
