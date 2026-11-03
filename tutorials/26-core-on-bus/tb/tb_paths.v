`timescale 1ns/1ps

// Times one access on each path from the core's native interface, with a scripted
// master in place of the core. It makes requests the way the core does: the next
// one starts in the clock straight after the last one finished, and nothing moves
// while it waits. Inputs change on the falling edge.
//
//   path A  native -> rv_wb_bridge -> wb_interconnect -> wb_ram
//   path B  native -> rv_wb_bridge -> wb_interconnect -> wb_axil_bridge -> axil_regs
//   path C  native -> rv_axil_bridge -> axil_regs
//
// Each path gets 32 writes and then 32 reads of the words written, back to back.
// A clock counts from the first clock of a request to the edge that ends it, both
// included, so Tutorial 21's memory with no wait takes 1. Every read is checked.
module tb_paths;

    reg clk = 1'b0;
    reg rst = 1'b1;
    always #5 clk = ~clk;

    integer errors = 0;

    // ----- Path A and B: one native master into Wishbone -----

    reg         a_valid = 1'b0;
    reg  [31:0] a_addr = 32'd0, a_wdata = 32'd0;
    reg  [3:0]  a_wstrb = 4'd0;
    wire        a_ready, a_err;
    wire [31:0] a_rdata;

    wire        m_cyc, m_stb, m_we, m_ack, m_err, m_stall;
    wire [29:0] m_adr;
    wire [3:0]  m_sel;
    wire [31:0] m_dat_w, m_dat_r;

    rv_wb_bridge u_wb_bridge (
        .clk(clk), .rst(rst),
        .mem_valid(a_valid), .mem_ready(a_ready), .mem_err(a_err),
        .mem_addr(a_addr), .mem_wdata(a_wdata), .mem_wstrb(a_wstrb), .mem_rdata(a_rdata),
        .cyc(m_cyc), .stb(m_stb), .we(m_we), .adr(m_adr), .sel(m_sel), .dat_w(m_dat_w),
        .ack(m_ack), .err(m_err), .stall(m_stall), .dat_r(m_dat_r)
    );

    wire        s_cyc, s_we;
    wire [1:0]  s_stb, s_ack, s_err, s_stall;
    wire [29:0] s_adr;
    wire [3:0]  s_sel;
    wire [31:0] s_dat_w;
    wire [63:0] s_dat_r;

    wb_interconnect #(
        .N(2), .BASE({32'h2000_0000, 32'h0000_0000}), .MASK({32'hFFFF_FFE0, 32'hFFFF_0000})
    ) u_interconnect (
        .clk(clk), .rst(rst),
        .m_cyc(m_cyc), .m_stb(m_stb), .m_we(m_we), .m_adr(m_adr), .m_sel(m_sel),
        .m_dat_w(m_dat_w), .m_ack(m_ack), .m_err(m_err), .m_stall(m_stall), .m_dat_r(m_dat_r),
        .s_cyc(s_cyc), .s_stb(s_stb), .s_we(s_we), .s_adr(s_adr), .s_sel(s_sel),
        .s_dat_w(s_dat_w), .s_ack(s_ack), .s_err(s_err), .s_stall(s_stall), .s_dat_r(s_dat_r)
    );

    wb_ram #(.AW(14)) u_ram (
        .clk(clk), .rst(rst),
        .cyc(s_cyc), .stb(s_stb[0]), .we(s_we), .adr(s_adr[13:0]), .sel(s_sel),
        .dat_w(s_dat_w), .ack(s_ack[0]), .err(s_err[0]), .stall(s_stall[0]),
        .dat_r(s_dat_r[31:0]), .hold(1'b0)
    );

    wire        b_awvalid, b_awready, b_wvalid, b_wready, b_bvalid, b_bready;
    wire        b_arvalid, b_arready, b_rvalid, b_rready;
    wire [31:0] b_awaddr, b_wdata, b_araddr, b_rdata;
    wire [3:0]  b_wstrb;
    wire [2:0]  b_awprot, b_arprot;
    wire [1:0]  b_bresp, b_rresp;

    wb_axil_bridge u_wb_axil (
        .clk(clk), .rst(rst),
        .cyc(s_cyc), .stb(s_stb[1]), .we(s_we), .adr(s_adr), .sel(s_sel),
        .dat_w(s_dat_w), .ack(s_ack[1]), .err(s_err[1]), .stall(s_stall[1]),
        .dat_r(s_dat_r[63:32]),
        .awvalid(b_awvalid), .awready(b_awready), .awaddr(b_awaddr), .awprot(b_awprot),
        .wvalid(b_wvalid), .wready(b_wready), .wdata(b_wdata), .wstrb(b_wstrb),
        .bvalid(b_bvalid), .bready(b_bready), .bresp(b_bresp),
        .arvalid(b_arvalid), .arready(b_arready), .araddr(b_araddr), .arprot(b_arprot),
        .rvalid(b_rvalid), .rready(b_rready), .rdata(b_rdata), .rresp(b_rresp)
    );

    axil_regs #(.BASE(32'h2000_0000)) u_regs_b (
        .clk(clk), .rst(rst),
        .awvalid(b_awvalid), .awready(b_awready), .awaddr(b_awaddr), .awprot(b_awprot),
        .wvalid(b_wvalid), .wready(b_wready), .wdata(b_wdata), .wstrb(b_wstrb),
        .bvalid(b_bvalid), .bready(b_bready), .bresp(b_bresp),
        .arvalid(b_arvalid), .arready(b_arready), .araddr(b_araddr), .arprot(b_arprot),
        .rvalid(b_rvalid), .rready(b_rready), .rdata(b_rdata), .rresp(b_rresp),
        .hold(3'd0)
    );

    // ----- Path C: a second native master, straight into AXI4-Lite -----

    reg         c_valid = 1'b0;
    reg  [31:0] c_addr = 32'd0, c_wdata = 32'd0;
    reg  [3:0]  c_wstrb = 4'd0;
    wire        c_ready, c_err;
    wire [31:0] c_rdata;

    wire        c_awvalid, c_awready, c_wvalid, c_wready, c_bvalid, c_bready;
    wire        c_arvalid, c_arready, c_rvalid, c_rready;
    wire [31:0] c_awaddr, c_wdata_axi, c_araddr, c_rdata_axi;
    wire [3:0]  c_wstrb_axi;
    wire [2:0]  c_awprot, c_arprot;
    wire [1:0]  c_bresp, c_rresp;

    rv_axil_bridge u_axil_bridge (
        .clk(clk), .rst(rst),
        .mem_valid(c_valid), .mem_ready(c_ready), .mem_err(c_err),
        .mem_addr(c_addr), .mem_wdata(c_wdata), .mem_wstrb(c_wstrb), .mem_rdata(c_rdata),
        .awvalid(c_awvalid), .awready(c_awready), .awaddr(c_awaddr), .awprot(c_awprot),
        .wvalid(c_wvalid), .wready(c_wready), .wdata(c_wdata_axi), .wstrb(c_wstrb_axi),
        .bvalid(c_bvalid), .bready(c_bready), .bresp(c_bresp),
        .arvalid(c_arvalid), .arready(c_arready), .araddr(c_araddr), .arprot(c_arprot),
        .rvalid(c_rvalid), .rready(c_rready), .rdata(c_rdata_axi), .rresp(c_rresp)
    );

    axil_regs #(.BASE(32'h2000_0000)) u_regs_c (
        .clk(clk), .rst(rst),
        .awvalid(c_awvalid), .awready(c_awready), .awaddr(c_awaddr), .awprot(c_awprot),
        .wvalid(c_wvalid), .wready(c_wready), .wdata(c_wdata_axi), .wstrb(c_wstrb_axi),
        .bvalid(c_bvalid), .bready(c_bready), .bresp(c_bresp),
        .arvalid(c_arvalid), .arready(c_arready), .araddr(c_araddr), .arprot(c_arprot),
        .rvalid(c_rvalid), .rready(c_rready), .rdata(c_rdata_axi), .rresp(c_rresp),
        .hold(3'd0)
    );

    // ----- The scripted master -----

    localparam integer COUNT = 32;

    // One access on path A/B (path 0) or C (path 1). It starts on this falling
    // edge, and returns on the falling edge after the edge that ended it, ready to
    // start the next. clocks gets how many clocks it took.
    task access(input integer path, input [31:0] addr, input [3:0] strb, input [31:0] data,
                output [31:0] rdata, output integer clocks);
        reg done;
        begin
            if (path == 0) begin
                a_valid = 1'b1; a_addr = addr; a_wstrb = strb; a_wdata = data;
            end else begin
                c_valid = 1'b1; c_addr = addr; c_wstrb = strb; c_wdata = data;
            end
            clocks = 0;
            done = 1'b0;
            while (!done) begin
                @(posedge clk);
                clocks = clocks + 1;
                if (path == 0 && (a_ready || a_err)) begin
                    done = 1'b1;
                    rdata = a_rdata;
                    if (a_err) begin
                        $display("FAIL err from %h", addr);
                        errors = errors + 1;
                    end
                end
                if (path == 1 && (c_ready || c_err)) begin
                    done = 1'b1;
                    rdata = c_rdata;
                    if (c_err) begin
                        $display("FAIL err from %h", addr);
                        errors = errors + 1;
                    end
                end
                if (clocks > 20) begin
                    $display("FAIL no answer from %h", addr);
                    errors = errors + 1;
                    done = 1'b1;
                end
            end
            @(negedge clk);
        end
    endtask

    task stop_master;
        begin
            a_valid = 1'b0;
            c_valid = 1'b0;
            @(negedge clk);
        end
    endtask

    // 32 writes, then 32 reads that check them, at words of base. axil_regs has
    // four registers, so its words repeat every 16 bytes.
    task measure(input [8*40-1:0] name, input integer path, input [31:0] base,
                 input integer words);
        integer i, w_clocks, r_clocks, clocks;
        reg [31:0] rdata;
        begin
            w_clocks = 0;
            r_clocks = 0;
            for (i = 0; i < COUNT; i = i + 1) begin
                access(path, base + 4 * (i % words), 4'b1111, 32'hA5000000 + i, rdata, clocks);
                w_clocks = w_clocks + clocks;
            end
            stop_master;
            for (i = 0; i < COUNT; i = i + 1) begin
                access(path, base + 4 * (i % words), 4'b0000, 32'd0, rdata, clocks);
                r_clocks = r_clocks + clocks;
                // The last write to this word was COUNT - words + (i % words).
                if (rdata !== 32'hA5000000 + COUNT - words + (i % words)) begin
                    $display("FAIL %0s read %h from %h", name, rdata, base + 4 * (i % words));
                    errors = errors + 1;
                end
            end
            stop_master;
            $display("%0s  writes %0.2f clocks each, reads %0.2f clocks each", name,
                     1.0 * w_clocks / COUNT, 1.0 * r_clocks / COUNT);
        end
    endtask

    initial begin
        $dumpfile("build/tb_paths.vcd");
        $dumpvars(0, tb_paths);
        @(negedge clk);
        @(negedge clk);
        rst = 1'b0;
        @(negedge clk);

        measure("A  Wishbone to wb_ram:              ", 0, 32'h0000_1000, COUNT);
        measure("B  Wishbone to AXI4-Lite axil_regs: ", 0, 32'h2000_0000, 4);
        measure("C  AXI4-Lite axil_regs, direct:     ", 1, 32'h2000_0000, 4);

        if (errors == 0)
            $display("PASS");
        else
            $fatal(1, "FAIL: %0d errors", errors);
        $finish;
    end

endmodule
