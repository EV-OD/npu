module systolic_array_2x2 (
    input  wire         clk,
    input  wire         rst,

    // X matrix enters row-by-row from the LEFT side
    input  wire signed [15:0] row1_x,  // Row 1: [x11, x12]
    input  wire signed [15:0] row2_x,  // Row 2: [x21, x22]

    // Y matrix enters column-by-column from the TOP side
    input  wire signed [15:0] col1_y,  // Col 1: [y11, y21]
    input  wire signed [15:0] col2_y,  // Col 2: [y12, y22]

    // Output matrix C = X * Y
    output wire signed [39:0] c11,
    output wire signed [39:0] c12,
    output wire signed [39:0] c21,
    output wire signed [39:0] c22
);

    // X flows left-to-right through these wires
    wire signed [15:0] x_to_pe12;
    wire signed [15:0] x_to_pe22;

    // Y flows top-to-bottom through these wires
    wire signed [15:0] y_to_pe21;
    wire signed [15:0] y_to_pe22;

    PE pe11 (
        .clk(clk),
        .rst(rst),
        .in_x(row1_x),
        .in_y(col1_y),
        .psum_in(40'd0),
        .out_x(x_to_pe12),
        .out_y(y_to_pe21),
        .out_c(c11)
    );

    PE pe12 (
        .clk(clk),
        .rst(rst),
        .in_x(x_to_pe12),
        .in_y(col2_y),
        .psum_in(40'd0),
        .out_x(),
        .out_y(y_to_pe22),
        .out_c(c12)
    );

    PE pe21 (
        .clk(clk),
        .rst(rst),
        .in_x(row2_x),
        .in_y(y_to_pe21),
        .psum_in(40'd0),
        .out_x(x_to_pe22),
        .out_y(),
        .out_c(c21)
    );

    PE pe22 (
        .clk(clk),
        .rst(rst),
        .in_x(x_to_pe22),
        .in_y(y_to_pe22),
        .psum_in(40'd0),
        .out_x(),
        .out_y(),
        .out_c(c22)
    );

endmodule
