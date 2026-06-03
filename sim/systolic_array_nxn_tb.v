`timescale 1ns / 1ps

module systolic_array_nxn_tb;

    parameter N = 2;
    parameter DATA_WIDTH = 16;
    parameter ACCUM_WIDTH = 40;

    reg clk;
    reg rst;

    // We can define individual reg arrays conceptually or pack them directly
    reg signed [DATA_WIDTH-1:0] row1_x;
    reg signed [DATA_WIDTH-1:0] row2_x;
    reg signed [DATA_WIDTH-1:0] col1_y;
    reg signed [DATA_WIDTH-1:0] col2_y;

    wire [(N * DATA_WIDTH)-1:0] in_left;
    wire [(N * DATA_WIDTH)-1:0] in_top;
    wire [(N * N * ACCUM_WIDTH)-1:0] out_c;

    assign in_left = {row2_x, row1_x};
    assign in_top  = {col2_y, col1_y};

    // Unpack outputs for easy reading based on flattening indexing logic
    wire signed [ACCUM_WIDTH-1:0] c11 = out_c[(0*N + 0)*ACCUM_WIDTH +: ACCUM_WIDTH]; 
    wire signed [ACCUM_WIDTH-1:0] c12 = out_c[(0*N + 1)*ACCUM_WIDTH +: ACCUM_WIDTH]; 
    wire signed [ACCUM_WIDTH-1:0] c21 = out_c[(1*N + 0)*ACCUM_WIDTH +: ACCUM_WIDTH]; 
    wire signed [ACCUM_WIDTH-1:0] c22 = out_c[(1*N + 1)*ACCUM_WIDTH +: ACCUM_WIDTH]; 

    // 100 MHz clock
    always #5 clk = ~clk;

    systolic_array_nxn #(
        .N(N),
        .DATA_WIDTH(DATA_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH)
    ) uut (
        .clk(clk), 
        .rst(rst),
        .in_left(in_left),
        .in_top(in_top),
        .out_c(out_c)
    );

    // X = [2 3]   Y = [5 7]    C = X*Y = [28 38]
    //     [4 1]       [6 8]             [26 36]

    integer cycle_cnt;

    task drive;
        input signed [DATA_WIDTH-1:0] r1, r2, c1, c2;
        integer c;
        begin
            @(negedge clk);
            row1_x <= r1; row2_x <= r2;
            col1_y <= c1; col2_y <= c2;
            c = cycle_cnt;
            cycle_cnt = cycle_cnt + 1;

            $strobe("--- Cycle %0d @ %0t ---", c, $time);
            $strobe("  Drive: row1_x=%0d  row2_x=%0d  col1_y=%0d  col2_y=%0d",
                     r1, r2, c1, c2);
        end
    endtask

    initial begin
        clk = 0; rst = 1;
        row1_x = 0; row2_x = 0; col1_y = 0; col2_y = 0;
        cycle_cnt = 0;

        $dumpfile("systolic_array_nxn_tb.vcd");
        $dumpvars(0, systolic_array_nxn_tb);

        // Reset for 2 cycles
        repeat (2) @(posedge clk);
        rst = 0;

        // Drive on negedge. Pipeline: x_reg <= in_x (cycle N),
        // out_x <= x_reg (cycle N+1), neighbor x_reg <= out_x (cycle N+2).

        // pe11: gets (x11, y11)
        drive(16'd2, 16'd0, 16'd5, 16'd0);  // negedge 0
        drive(16'd0, 16'd0, 16'd0, 16'd0);  // negedge 1  (pipeline bubble)

        // pe11: gets (x12, y21), pe12: gets (x11, y12), pe21: gets (x21, y11)
        drive(16'd3, 16'd4, 16'd6, 16'd7);  // negedge 2
        drive(16'd0, 16'd0, 16'd0, 16'd0);  // negedge 3  (pipeline bubble)

        // pe12: gets (x12, y22), pe21: gets (x22, y21), pe22: gets (x21, y12)
        drive(16'd0, 16'd1, 16'd0, 16'd8);  // negedge 4
        drive(16'd0, 16'd0, 16'd0, 16'd0);  // negedge 5  (pipeline bubble)

        // pe22: gets (x22, y22)
        drive(16'd0, 16'd0, 16'd0, 16'd0);  // negedge 6

        // Drain pipeline
        repeat (6) drive(16'd0, 16'd0, 16'd0, 16'd0);

        @(posedge clk);
        #1;
        $display("\n--- RESULTS ---");
        $display("C = X * Y");
        $display("X = [2 3]   Y = [5 7]");
        $display("    [4 1]       [6 8]");
        $display("");
        $display("Expected: c11=28 c12=38 c21=26 c22=36");
        $display("Got:      c11=%0d c12=%0d c21=%0d c22=%0d",
                 c11, c12, c21, c22);
        
        if (c11 === 28 && c12 === 38 && c21 === 26 && c22 === 36)
            $display("*** MATRIX MULTIPLY CORRECT ***");
        else
            $display("*** MISMATCH ***");
            
        $finish;
    end

endmodule
