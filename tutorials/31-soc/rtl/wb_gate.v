// Holds back requests to one Wishbone slave until go is high. Everything passes
// straight through, wires only, except the strobe and the stall:
//
//   to the slave:      stb = m_stb && go
//   to the master:     stall = s_stall || !go
//
// While go is low, the master sees its request stalled, and the slave sees no
// request at all. That is legal Wishbone on both sides, as long as go never
// falls while a request waits to be taken: the slave would see a stalled
// request withdrawn. flash_share.v promises that, and proves it.
//
// soc.v puts one in front of the SPI controller and one in front of the XIP
// slave, with go from flash_share.v, so neither starts a command on the flash
// until it owns the pins.
module wb_gate (
    input  wire        go,
    // From the interconnect: its master port for this slave
    input  wire        m_cyc,
    input  wire        m_stb,
    output wire        m_stall,
    output wire        m_ack,
    output wire        m_err,
    // To the slave
    output wire        s_cyc,
    output wire        s_stb,
    input  wire        s_stall,
    input  wire        s_ack,
    input  wire        s_err
);

    assign s_cyc   = m_cyc;
    assign s_stb   = m_stb && go;
    assign m_stall = s_stall || !go;
    assign m_ack   = s_ack;
    assign m_err   = s_err;

endmodule
