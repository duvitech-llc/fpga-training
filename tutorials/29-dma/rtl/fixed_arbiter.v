// Grants the lowest-numbered active request. Purely combinational, so it has no
// memory of past grants: a busy requester 0 can starve all the others.
module fixed_arbiter #(
    parameter N = 4
) (
    input  wire [N-1:0] req,
    output wire [N-1:0] grant   // one-hot, or zero when req is zero
);

    // In two's complement, -req keeps the lowest set bit of req and inverts
    // every bit above it, so the AND leaves only that lowest bit.
    assign grant = req & -req;

endmodule
