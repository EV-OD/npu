`timescale 1ns / 1ps

module systolic_array_2x2_tb;

    reg clk;
    reg rst;

    reg signed [15:0] row1_x;
    reg signed [15:0] row2_x;
    reg signed [15:0] col1_y;
    reg signed [15:0] col2_y;

    wire signed [39:0] c11;
    wire signed [39:0] c12;
    wire signed [39:0] c21;
    wire signed [39:0] c22;

    // 100 MHz clock
    always #5 clk = ~clk;

    systolic_array_2x2 uut (
        .clk(clk), .rst(rst),
        .row1_x(row1_x), .row2_x(row2_x),
        .col1_y(col1_y), .col2_y(col2_y),
        .c11(c11), .c12(c12), .c21(c21), .c22(c22)
    );

    // X = [2 3]   Y = [5 7]    C = X*Y = [28 38]
    //     [4 1]       [6 8]             [26 36]

    integer cycle_cnt;

    task show;
        begin
            $strobe("--- Cycle %0d @ %0t ---", cycle_cnt, $time);
            $strobe("  Drive: row1_x=%0d  row2_x=%0d  col1_y=%0d  col2_y=%0d",
                     row1_x, row2_x, col1_y, col2_y);
            $strobe("  PE11: in_x=%0d  in_y=%0d  c11 = accum(%0d) + psum(%0d) = %0d  | out_x=%0d  out_y=%0d",
                     row1_x, col1_y, uut.pe11.accumulator, 0, c11,
                     uut.pe11.out_x, uut.pe11.out_y);
            $strobe("  PE12: in_x=%0d  in_y=%0d  c12 = accum(%0d) + psum(%0d) = %0d  | out_x=%0d  out_y=%0d",
                     uut.x_to_pe12, col2_y, uut.pe12.accumulator, 0, c12,
                     uut.pe12.out_x, uut.pe12.out_y);
            $strobe("  PE21: in_x=%0d  in_y=%0d  c21 = accum(%0d) + psum(%0d) = %0d  | out_x=%0d  out_y=%0d",
                     row2_x, uut.y_to_pe21, uut.pe21.accumulator, 0, c21,
                     uut.pe21.out_x, uut.pe21.out_y);
            $strobe("  PE22: in_x=%0d  in_y=%0d  c22 = accum(%0d) + psum(%0d) = %0d  | out_x=%0d  out_y=%0d",
                     uut.x_to_pe22, uut.y_to_pe22, uut.pe22.accumulator, 0, c22,
                     uut.pe22.out_x, uut.pe22.out_y);
        end
    endtask

    task drive;
        input signed [15:0] r1, r2, c1, c2;
        begin
            @(negedge clk);
            row1_x <= r1; row2_x <= r2;
            col1_y <= c1; col2_y <= c2;
            show();
            cycle_cnt = cycle_cnt + 1;
        end
    endtask

    initial begin
        clk = 0; rst = 1;
        row1_x = 0; row2_x = 0; col1_y = 0; col2_y = 0;
        cycle_cnt = 0;

        $dumpfile("systolic_array_2x2_tb.vcd");
        $dumpvars(0, systolic_array_2x2_tb);

        // Reset for 2 cycles
        repeat (2) @(posedge clk);
        rst = 0;

        // Drive on negedge. Pipeline: x_reg <= in_x (cycle N),
        // out_x <= x_reg (cycle N+1), neighbor x_reg <= out_x (cycle N+2).
        // So input at cycle N reaches neighbor at cycle N+2.

        // pe11: gets (x11, y11)                    -> accum x11*y11=10
        drive(16'd2, 16'd0, 16'd5, 16'd0);  // negedge 0
        drive(16'd0, 16'd0, 16'd0, 16'd0);  // negedge 1  (pipeline bubble)

        // pe11: gets (x12, y21) -> accum += 18 = 28
        // pe12: gets (x11, y12) -> accum x11*y12=14
        // pe21: gets (x21, y11) -> accum x21*y11=20
        drive(16'd3, 16'd4, 16'd6, 16'd7);  // negedge 2
        drive(16'd0, 16'd0, 16'd0, 16'd0);  // negedge 3  (pipeline bubble)

        // pe12: gets (x12, y22) -> accum += 24 = 38
        // pe21: gets (x22, y21) -> accum += 6  = 26
        // pe22: gets (x21, y12) -> accum x21*y12=28
        drive(16'd0, 16'd1, 16'd0, 16'd8);  // negedge 4
        drive(16'd0, 16'd0, 16'd0, 16'd0);  // negedge 5  (pipeline bubble)

        // pe22: gets (x22, y22) -> accum += 8  = 36
        drive(16'd0, 16'd0, 16'd0, 16'd0);  // negedge 6

        // Drain pipeline
        repeat (4) drive(16'd0, 16'd0, 16'd0, 16'd0);

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
