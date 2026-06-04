module output_buffer #(
    parameter N = 4,
    parameter ACCUM_WIDTH = 40
)(
    input  wire                                clk,
    input  wire                                rst,

    // Row-level write port (from readout)
    input  wire                                we,
    input  wire [$clog2(N)-1:0]                waddr,
    input  wire signed [(N*ACCUM_WIDTH)-1:0]   row_in,

    // Row-level async read port (for verification / DMA)
    input  wire [$clog2(N)-1:0]                raddr,
    output wire signed [(N*ACCUM_WIDTH)-1:0]   dout
);

    reg signed [ACCUM_WIDTH-1:0] mem [0:N*N-1];
    integer i, j;

    initial begin
        for (i = 0; i < N*N; i = i + 1)
            mem[i] = {ACCUM_WIDTH{1'b0}};
    end

    always @(posedge clk) begin
        if (we) begin
            for (j = 0; j < N; j = j + 1)
                mem[waddr*N + j] <= row_in[(j*ACCUM_WIDTH) +: ACCUM_WIDTH];
        end
    end

    genvar gj;
    generate
        for (gj = 0; gj < N; gj = gj + 1) begin
            assign dout[(gj*ACCUM_WIDTH) +: ACCUM_WIDTH] = mem[raddr*N + gj];
        end
    endgenerate

endmodule
