module systolic_array_nxn #(
    parameter N = 4,
    parameter DATA_WIDTH = 16,
    parameter ACCUM_WIDTH = 40
)(
    input  wire                               clk,
    input  wire                               rst,

    // Flattened arrays for inputs to ensure standard Verilog compatibility at module boundaries.
    // Indexing: Element `i` takes bits [(i+1)*DATA_WIDTH-1 : i*DATA_WIDTH]
    input  wire [(N * DATA_WIDTH)-1:0]        in_left,
    input  wire [(N * DATA_WIDTH)-1:0]        in_top,

    // Flattened array for outputs.
    // Indexing: Element at row `i`, col `j` (0-indexed) starts at bit ((i * N + j) * ACCUM_WIDTH)
    output wire [(N * N * ACCUM_WIDTH)-1:0]   out_c
);

    // Internal wires to connect PEs 
    // x_wire[i][j] runs horizontally connecting PE(i, j-1) to PE(i, j)
    wire signed [DATA_WIDTH-1:0] x_wire [0:N-1][0:N];
    
    // y_wire[i][j] runs vertically connecting PE(i-1, j) to PE(i, j)
    wire signed [DATA_WIDTH-1:0] y_wire [0:N][0:N-1];

    genvar i, j;
    generate
        // 1. Assign flattened inputs to the boundary wires (0-th index of arrays)
        for (i = 0; i < N; i = i + 1) begin : init_boundaries
            assign x_wire[i][0] = in_left[(i * DATA_WIDTH) +: DATA_WIDTH];
            assign y_wire[0][i] = in_top[(i * DATA_WIDTH) +: DATA_WIDTH];
        end

        // 2. Instantiate N x N PEs
        for (i = 0; i < N; i = i + 1) begin : row
            for (j = 0; j < N; j = j + 1) begin : col
                
                PE #(
                    .DATA_WIDTH(DATA_WIDTH),
                    .ACCUM_WIDTH(ACCUM_WIDTH)
                ) pe_inst (
                    .clk(clk),
                    .rst(rst),
                    
                    // Inputs from prev PE or boundary
                    .in_x(x_wire[i][j]),
                    .in_y(y_wire[i][j]),
                    .psum_in({ACCUM_WIDTH{1'b0}}), // Defaulting to 0 since accumulation happens internally
                    
                    // Outputs to next PE
                    .out_x(x_wire[i][j+1]),
                    .out_y(y_wire[i+1][j]),
                    
                    // Connect C directly to the flattened output port
                    .out_c(out_c[((i * N + j) * ACCUM_WIDTH) +: ACCUM_WIDTH])
                );
                
            end
        end
    endgenerate

endmodule
