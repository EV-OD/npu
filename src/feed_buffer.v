module feed_buffer #(
    parameter N = 4,
    parameter DATA_WIDTH = 16,
    parameter COL_MAJOR = 0  // 1=column read (strided), 0=row read (consecutive)
)(
    input  wire                                clk,
    input  wire                                rst,

    // Element-level write port (for preload)
    input  wire                                we,
    input  wire [$clog2(2*N*N)-1:0]            waddr,
    input  wire signed [DATA_WIDTH-1:0]        din,

    // Row-level async read port (for feed)
    input  wire [$clog2(2*N)-1:0]              raddr,
    output wire signed [(N*DATA_WIDTH)-1:0]    dout
);

    reg signed [DATA_WIDTH-1:0] mem [0:2*N*N-1];

    integer i;
    initial begin
        for (i = 0; i < 2*N*N; i = i + 1)
            mem[i] = {DATA_WIDTH{1'b0}};
    end

    always @(posedge clk) begin
        if (we) mem[waddr] <= din;
    end

    wire [$clog2(2*N*N)-1:0] pong_base = raddr >= N ? N*N : 0;
    wire [$clog2(N)-1:0] r_adj = raddr >= N ? raddr - N : raddr;

    genvar j;
    generate
        if (COL_MAJOR) begin
            // Column read: dout[j] = mem[pong_base + j*N + r_adj]
            for (j = 0; j < N; j = j + 1) begin
                assign dout[(j*DATA_WIDTH) +: DATA_WIDTH] = mem[pong_base + j*N + r_adj];
            end
        end else begin
            // Row read: dout[j] = mem[pong_base + r_adj*N + j]
            for (j = 0; j < N; j = j + 1) begin
                assign dout[(j*DATA_WIDTH) +: DATA_WIDTH] = mem[pong_base + r_adj*N + j];
            end
        end
    endgenerate

endmodule
