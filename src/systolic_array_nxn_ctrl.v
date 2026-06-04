module systolic_array_nxn_ctrl #(
    parameter N = 4,
    parameter DATA_WIDTH = 16,
    parameter ACCUM_WIDTH = 40
)(
    input  wire                               clk,
    input  wire                               rst,
    input  wire                               acc_clr,
    input  wire                               acc_en,
    input  wire [(N * DATA_WIDTH)-1:0]        in_left,
    input  wire [(N * DATA_WIDTH)-1:0]        in_top,
    output wire [(N * N * ACCUM_WIDTH)-1:0]   out_c
);

    wire signed [DATA_WIDTH-1:0] x_wire [0:N-1][0:N];
    wire signed [DATA_WIDTH-1:0] y_wire [0:N][0:N-1];

    genvar i, j;
    generate
        for (i = 0; i < N; i = i + 1) begin : init_boundaries
            assign x_wire[i][0] = in_left[(i * DATA_WIDTH) +: DATA_WIDTH];
            assign y_wire[0][i] = in_top[(i * DATA_WIDTH) +: DATA_WIDTH];
        end

        for (i = 0; i < N; i = i + 1) begin : row
            for (j = 0; j < N; j = j + 1) begin : col
                PE_ctrl #(
                    .DATA_WIDTH(DATA_WIDTH),
                    .ACCUM_WIDTH(ACCUM_WIDTH)
                ) pe_inst (
                    .clk(clk),
                    .rst(rst),
                    .acc_clr(acc_clr),
                    .acc_en(acc_en),
                    .in_x(x_wire[i][j]),
                    .in_y(y_wire[i][j]),
                    .psum_in({ACCUM_WIDTH{1'b0}}),
                    .out_x(x_wire[i][j+1]),
                    .out_y(y_wire[i+1][j]),
                    .out_c(out_c[((i * N + j) * ACCUM_WIDTH) +: ACCUM_WIDTH])
                );
            end
        end
    endgenerate

endmodule
