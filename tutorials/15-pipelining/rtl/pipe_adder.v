// A pipelined adder. The carry chain is cut into STAGES parts, with registers
// between them, so a new add can enter on every clock. out_valid, sum and carry
// are registers, and each result appears STAGES clocks after its operands.
// STAGES must be between 1 and WIDTH.
module pipe_adder #(
    parameter WIDTH  = 32,
    parameter STAGES = 2
) (
    input  wire             clk,
    input  wire             rst,        // synchronous, active high, clears every valid bit
    input  wire             in_valid,   // a and b are a real add on this clock
    input  wire [WIDTH-1:0] a,
    input  wire [WIDTH-1:0] b,
    output wire             out_valid,  // sum and carry are a real result on this clock
    output wire [WIDTH-1:0] sum,
    output wire             carry
);

    localparam integer CHUNK = WIDTH / STAGES;  // bits added in each stage

    // Index i is what enters stage i, so index STAGES is what leaves the last one.
    wire [WIDTH-1:0] a_p [0:STAGES];    // first operand, delayed to line up
    wire [WIDTH-1:0] b_p [0:STAGES];    // second operand, delayed to line up
    wire [WIDTH-1:0] s_p [0:STAGES];    // the sum bits worked out so far
    wire             c_p [0:STAGES];    // carry into the next stage
    wire             v_p [0:STAGES];    // valid bit

    assign a_p[0] = a;
    assign b_p[0] = b;
    assign s_p[0] = {WIDTH{1'b0}};
    assign c_p[0] = 1'b0;
    assign v_p[0] = in_valid;

    genvar i;
    generate
        for (i = 0; i < STAGES; i = i + 1) begin : stage
            // The last stage takes any bits left over by the division.
            localparam integer LO   = i * CHUNK;
            localparam integer BITS = (i == STAGES - 1) ? WIDTH - LO : CHUNK;

            wire [BITS:0] part = {1'b0, a_p[i][LO +: BITS]} + {1'b0, b_p[i][LO +: BITS]}
                               + {{BITS{1'b0}}, c_p[i]};

            reg [WIDTH-1:0] a_r;
            reg [WIDTH-1:0] b_r;
            reg [WIDTH-1:0] s_r;
            reg             c_r;
            reg             v_r;

            // Only the valid bits are reset. The data is meaningless without them.
            always @(posedge clk) begin
                a_r <= a_p[i];
                b_r <= b_p[i];
                s_r <= s_p[i];
                s_r[LO +: BITS] <= part[BITS-1:0];
                c_r <= part[BITS];
                v_r <= !rst && v_p[i];
            end

            assign a_p[i + 1] = a_r;
            assign b_p[i + 1] = b_r;
            assign s_p[i + 1] = s_r;
            assign c_p[i + 1] = c_r;
            assign v_p[i + 1] = v_r;
        end
    endgenerate

    assign out_valid = v_p[STAGES];
    assign sum       = s_p[STAGES];
    assign carry     = c_p[STAGES];

`ifdef FORMAL
    // $past needs one clock of history before it is meaningful.
    reg past_valid = 1'b0;
    always @(posedge clk)
        past_valid <= 1'b1;

    always @(posedge clk) begin
        if (!past_valid)
            assume (rst);
    end

    // The shadow model does the whole add at once, then delays it by STAGES
    // clocks. One item is a valid bit, the carry and the sum. Newest at the bottom.
    localparam integer ITEM = WIDTH + 2;

    reg  [STAGES*ITEM-1:0] shadow = 0;
    wire [WIDTH:0]         total  = {1'b0, a} + {1'b0, b};
    wire [ITEM-1:0]        oldest = shadow[STAGES*ITEM-1 -: ITEM];

    always @(posedge clk) begin
        if (rst)
            shadow <= 0;
        else
            shadow <= {shadow, in_valid, total};
    end

    always @(posedge clk) begin
        if (past_valid) begin
            assert (out_valid == oldest[ITEM-1]);
            if (out_valid)
                assert ({carry, sum} == oldest[WIDTH:0]);
        end
    end
`endif

endmodule
