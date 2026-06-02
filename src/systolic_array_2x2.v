// systolic_array_2x2.v
module systolic_array_2x2 (
    input  wire         clk,
    input  wire         rst,
    
    // External Matrix Activations (X) streaming into the COLUMNS from the top
    input  wire signed [15:0] col1_act_x, // Streams [x11, x12] down Column 1
    input  wire signed [15:0] col2_act_x, // Streams [x21, x22] down Column 2
    
    // Stationary Weights (Y) loaded into the PEs spatially
    input  wire signed [15:0] pe11_weight_y, // Static weight y11
    input  wire signed [15:0] pe12_weight_y, // Static weight y12
    input  wire signed [15:0] pe21_weight_y, // Static weight y21
    input  wire signed [15:0] pe22_weight_y, // Static weight y22
    
    // 2x2 Matrix Outputs exiting the right edge of the rows
    output wire signed [39:0] c11,
    output wire signed [39:0] c12,
    output wire signed [39:0] c21,
    output wire signed [39:0] c22
);

    // Interconnect wires for activations passing vertically down columns
    wire signed [15:0] x11_to_x21;
    wire signed [15:0] x12_to_x22;
    
    // Interconnect wires for partial sums accumulating horizontally across rows
    wire signed [39:0] c11_to_c12;
    wire signed [39:0] c21_to_c22;
    
    // Unused boundary outputs from the bottom edge
    wire signed [15:0] dead_y21, dead_y22;

    // ==========================================
    //  ROW 1
    // ==========================================
    
    // Top-Left Element (PE11)
    PE pe11 (
        .clk(clk), 
        .rst(rst),
        .in_x(col1_act_x),      // Activations enter Column 1 from the top
        .in_y(pe11_weight_y),   // Stationary Weight y11
        .out_x(x11_to_x21),     // Passes activation DOWN to pe21
        .out_y(dead_y21),       
        .out_c(c11_to_c12)      // Outputs partial sum RIGHT to pe12
    );
    assign c11 = c11_to_c12;    // Captures the Row 1, Col 1 partial result

    // Top-Right Element (PE12)
    PE pe12 (
        .clk(clk), 
        .rst(rst),
        .in_x(col2_act_x),      // Activations enter Column 2 from the top
        .in_y(pe12_weight_y),   // Stationary Weight y12
        .out_x(x12_to_x22),     // Passes activation DOWN to pe22
        .out_y(dead_y22), 
        .out_c(c12)             // Final row accumulation output for Row 1 (c12)
    );

    // ==========================================
    //  ROW 2
    // ==========================================

    // Bottom-Left Element (PE21)
    PE pe21 (
        .clk(clk), 
        .rst(rst),
        .in_x(x11_to_x21),      // Receives activation from pe11 above
        .in_y(pe21_weight_y),   // Stationary Weight y21
        .out_x(),               
        .out_y(), 
        .out_c(c21_to_c22)      // Outputs partial sum RIGHT to pe22
    );
    assign c21 = c21_to_c22;    // Captures the Row 2, Col 1 partial result

    // Bottom-Right Element (PE22)
    PE pe22 (
        .clk(clk), 
        .rst(rst),
        .in_x(x12_to_x22),      // Receives activation from pe12 above
        .in_y(pe22_weight_y),   // Stationary Weight y22
        .out_x(),               
        .out_y(), 
        .out_c(c22)             // Final row accumulation output for Row 2 (c22)
    );

endmodule