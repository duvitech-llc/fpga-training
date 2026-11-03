// A Wishbone B4 pipelined master that runs commands from a script.
//
// Commands come in on a valid/ready handshake, as in Tutorial 9. Each one becomes
// one bus request, and each request gets one response, in order, valid for one
// clock. The master puts a new request on the bus as soon as the last one is
// accepted, without waiting for its answer, unless one_at_a_time is high.
//
// one_at_a_time makes it wait for each answer before the next request. That is
// how a classic Wishbone cycle behaves, where stb stays high until the ack, so
// it shows what pipelining buys.
module wb_master #(
    parameter LGPEND = 3  // at most 2**LGPEND - 1 requests in flight
) (
    input  wire        clk,
    input  wire        rst,            // synchronous, active high
    input  wire        one_at_a_time,  // wait for each answer before the next request
    // Commands
    input  wire        cmd_valid,
    output wire        cmd_ready,      // the command is taken at the next rising edge
    input  wire        cmd_we,
    input  wire [29:0] cmd_adr,        // word address
    input  wire [3:0]  cmd_sel,
    input  wire [31:0] cmd_dat,
    // Responses, one per command, in order
    output reg         rsp_valid,
    output reg         rsp_err,
    output reg  [31:0] rsp_dat,        // read data. Meaningless for a write or an err
    // Wishbone master port
    output reg         cyc,
    output reg         stb,
    output reg         we,
    output reg  [29:0] adr,
    output reg  [3:0]  sel,
    output reg  [31:0] dat_w,
    input  wire        ack,
    input  wire        err,
    input  wire        stall,
    input  wire [31:0] dat_r
);

    reg [LGPEND-1:0] pending;  // requests accepted by the bus and not yet answered

    wire request = stb && !stall;        // the request on the bus goes at this edge
    wire answer  = cyc && (ack || err);  // an answer arrives at this edge

    // How many will be in flight after this edge, before any new command.
    reg [LGPEND-1:0] next_pending;
    always @(*) begin
        next_pending = pending;
        if (request && !answer)
            next_pending = pending + 1'b1;
        else if (answer && !request)
            next_pending = pending - 1'b1;
    end

    // A new request can go on the bus if the bus slot is free after this edge,
    // and there is room to count it.
    wire slot_free = !stb || !stall;
    wire room      = one_at_a_time ? (next_pending == 0)
                                   : (next_pending != {LGPEND{1'b1}});
    assign cmd_ready = !rst && slot_free && room;

    wire take = cmd_valid && cmd_ready;

    always @(posedge clk) begin
        if (rst) begin
            cyc       <= 1'b0;
            stb       <= 1'b0;
            pending   <= 0;
            rsp_valid <= 1'b0;
        end else begin
            if (take) begin
                stb   <= 1'b1;
                we    <= cmd_we;
                adr   <= cmd_adr;
                sel   <= cmd_sel;
                dat_w <= cmd_dat;
            end else if (!stall) begin
                stb   <= 1'b0;
            end
            pending   <= next_pending;
            // The cycle lasts while a request is on the bus or an answer is owed.
            cyc       <= take || (stb && stall) || next_pending != 0;
            rsp_valid <= answer;
            rsp_err   <= err;
            rsp_dat   <= dat_r;
        end
    end

`ifdef FORMAL
    // The previous clock, for the checks below. The checker keeps its own copy.
    reg f_past_valid = 1'b0;
    reg f_past_rst, f_past_cyc, f_past_stb;
    always @(posedge clk) begin
        f_past_valid <= 1'b1;
        f_past_rst   <= rst;
        f_past_cyc   <= cyc;
        f_past_stb   <= stb;
    end

    // The bus rules, from the master's side.
    wire [3:0] f_outstanding;
    wire [7:0] f_waited;
    wire [7:0] f_stalled;

    wb_checker #(
        .AW(30), .DUT_IS_SLAVE(0), .LGDEPTH(4),
        .MAX_OUTSTANDING(4), .MAX_WAIT(4), .MAX_STALL(4)
    ) f_bus (
        .clk(clk), .rst(rst),
        .cyc(cyc), .stb(stb), .we(we), .adr(adr), .sel(sel), .dat_w(dat_w),
        .ack(ack), .err(err), .stall(stall),
        .outstanding(f_outstanding), .waited(f_waited), .stalled(f_stalled)
    );

    // The command side follows Tutorial 9's handshake: a command on offer stays.
    reg f_past_offer = 1'b0;
    always @(posedge clk)
        f_past_offer <= !rst && cmd_valid && !cmd_ready;
    always @(*)
        if (f_past_offer && !rst)
            assume (cmd_valid);

    always @(*) begin
        if (f_past_valid && !f_past_rst) begin
            assert (f_outstanding == {{(4-LGPEND){1'b0}}, pending});
            assert (cyc == (stb || pending != 0));
            if (one_at_a_time)
                cover (rsp_valid && f_past_stb);
            cover (f_outstanding == 3);
            cover (rsp_valid && rsp_err);
        end
    end
`endif

endmodule
