`timescale 1ns / 1ps

module systolic_array_2x2_tb;

    reg         clk;
    reg         rst;
    
    // Activation column inputs (X) - 16-bit registers
    reg signed [15:0] col1_act_x;
    reg signed [15:0] col2_act_x;
    
    // Static weight matrix inputs (Y)
    reg signed [15:0] pe11_weight_y;
    reg signed [15:0] pe12_weight_y;
    reg signed [15:0] pe21_weight_y;
    reg signed [15:0] pe22_weight_y;
    
    // Outputs from UUT
    wire signed [39:0] c11;
    wire signed [39:0] c12;
    wire signed [39:0] c21;
    wire signed [39:0] c22;

    // Clock generation (100 MHz)
    always #5 clk = ~clk;

    // Instantiate UUT
    systolic_array_2x2 uut (
        .clk(clk), 
        .rst(rst),
        .col1_act_x(col1_act_x), 
        .col2_act_x(col2_act_x),
        .pe11_weight_y(pe11_weight_y), 
        .pe12_weight_y(pe12_weight_y),
        .pe21_weight_y(pe21_weight_y), 
        .pe22_weight_y(pe22_weight_y),
        .c11(c11), 
        .c12(c12), 
        .c21(c21), 
        .c22(c22)
    );

    initial begin
        clk = 0;
        rst = 1;
        col1_act_x = 0;
        col2_act_x = 0;
        
        // Matrix X (Activations): [ 2  3 ]     Matrix Y (Weights): [ 5  7 ]
        //                        [ 4  1 ]                         [ 6  8 ]
        // Expected Matrix C = X * Y:
        // c11 = 28, c12 = 38, c21 = 26, c22 = 36

        // Load stationary weight coordinates
        pe11_weight_y = 16'd5;  // y11
        pe12_weight_y = 16'd7;  // y12
        pe21_weight_y = 16'd6;  // y21
        pe22_weight_y = 16'd8;  // y22

        $dumpfile("systolic_array_2x2_tb.vcd");
        $dumpvars(0, systolic_array_2x2_tb);

        #20;
        @(posedge clk);
        rst = 0;
        
        $display("\n--- STARTING COLUMN-FED SYSTOLIC PROCESSING ---");
        
        // --- Cycle 1 ---
        // Column 1 gets x11. Column 2 is delayed (0).
        col1_act_x = 16'd2; // x11
        col2_act_x = 16'd0;
        @(posedge clk); // Typo removed here!

        // --- Cycle 2 ---
        // Column 1 gets x12. Column 2 steps up and gets x21.
        col1_act_x = 16'd3; // x12
        col2_act_x = 16'd4; // x21
        @(posedge clk);

        // --- Cycle 3 ---
        // Column 1 stream finished. Column 2 gets x22.
        col1_act_x = 16'd0;
        col2_act_x = 16'd1; // x22
        @(posedge clk);

        // --- Cycle 4 ---
        col1_act_x = 16'd0;
        col2_act_x = 16'd0;
        
        // Let the pipeline finish rolling out to the edge registers
        #50; 
        
        $display("\n--- FINAL COMPUTED RESULTS ---");
        $display("Expected: c11=28, c12=38, c21=26, c22=36");
        $display("Hardware: c11=%0d, c12=%0d, c21=%0d, c22=%0d", c11, c12, c21, c22);
        $display("----------------------------------------\n");
        
        $finish;
    end

    // Clock Edge Trace Monitor
    integer cycle_count = 0;
    always @(posedge clk) begin
        if (!rst) begin
            cycle_count = cycle_count + 1;
            $display("Time: %4t ns | Cycle: %0d", $time, cycle_count);
            $display("  Col Inputs -> Col1_X: %3d | Col2_X: %3d", col1_act_x, col2_act_x);
            $display("  Reg Values -> c11: %3d | c12: %3d | c21: %3d | c22: %3d", c11, c12, c21, c22);
            $display("  -------------------------------------------------------------");
        end
    end

endmodule