`timescale 1ns / 1ps

module systolic_tester #(
    parameter N = 3,
    parameter DATA_WIDTH = 16,
    parameter ACCUM_WIDTH = 40
)(
    input clk,
    input rst,
    input en,
    output reg done
);

    reg [(N * DATA_WIDTH)-1:0] in_left;
    reg [(N * DATA_WIDTH)-1:0] in_top;
    wire [(N * N * ACCUM_WIDTH)-1:0] out_c;

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

    reg signed [DATA_WIDTH-1:0] A [0:N-1][0:N-1];
    reg signed [DATA_WIDTH-1:0] B [0:N-1][0:N-1];
    reg signed [ACCUM_WIDTH-1:0] C_exp [0:N-1][0:N-1];

    integer i, j, k, step;
    integer err_cnt;
    reg signed [ACCUM_WIDTH-1:0] actual;

    initial begin
        done = 0;
        in_left = 0;
        in_top = 0;
        err_cnt = 0;

        // Wait for enable signal
        wait(en);
        @(negedge clk);
        
        $display("--------------------------------");
        $display("Starting Test for N=%0d", N);

        // Initialize A and B with pseudo-random values and compute C_expected
        for (i = 0; i < N; i = i + 1) begin
            for (j = 0; j < N; j = j + 1) begin
                A[i][j] = ($random % 20);
                B[i][j] = ($random % 20);
                C_exp[i][j] = 0;
            end
        end

        for (i = 0; i < N; i = i + 1) begin
            for (j = 0; j < N; j = j + 1) begin
                for (k = 0; k < N; k = k + 1) begin
                    C_exp[i][j] = C_exp[i][j] + A[i][k] * B[k][j];
                end
            end
        end

        // Print Matrix A and B
        $display("Matrix A:");
        for (i = 0; i < N; i = i + 1) begin
            $write("  ");
            for (j = 0; j < N; j = j + 1) $write("%4d ", A[i][j]);
            $write("\n");
        end
        $display("Matrix B:");
        for (i = 0; i < N; i = i + 1) begin
            $write("  ");
            for (j = 0; j < N; j = j + 1) $write("%4d ", B[i][j]);
            $write("\n");
        end

        // Drive staggered inputs
        for (step = 0; step < 2*N; step = step + 1) begin
            @(negedge clk);
            for (i = 0; i < N; i = i + 1) begin
                if (step - i >= 0 && step - i < N) begin
                    in_left[i * DATA_WIDTH +: DATA_WIDTH] = A[i][step - i];
                    in_top[i * DATA_WIDTH +: DATA_WIDTH] = B[step - i][i];
                end else begin
                    in_left[i * DATA_WIDTH +: DATA_WIDTH] = 0;
                    in_top[i * DATA_WIDTH +: DATA_WIDTH] = 0;
                end
            end

            // Pipeline bubble (1 cycle delay between systolic data points as per PE design)
            @(negedge clk);
            in_left = 0;
            in_top = 0;
        end

        // Pipeline flush: wait enough cycles for the deepest computation to finish
        repeat (3*N + 5) @(negedge clk);

        // Check outputs
        $display("Matrix C (Actual):");
        for (i = 0; i < N; i = i + 1) begin
            $write("  ");
            for (j = 0; j < N; j = j + 1) begin
                actual = out_c[((i * N + j) * ACCUM_WIDTH) +: ACCUM_WIDTH];
                $write("%4d ", actual);
                
                if (actual !== C_exp[i][j]) begin
                    $display("\nERROR [N=%0d] at C[%0d][%0d]: Expected %0d, Got %0d", N, i, j, C_exp[i][j], actual);
                    err_cnt = err_cnt + 1;
                end
            end
            $write("\n");
        end

        if (err_cnt == 0)
            $display("*** N=%0d TEST PASSED *** (All results matched expected C=A*B)", N);
        else
            $display("*** N=%0d TEST FAILED with %0d errors ***", N, err_cnt);

        done = 1;
    end
endmodule

module systolic_multi_n_tb;
    reg clk;
    reg rst;
    
    always #5 clk = ~clk;
    
    reg en_3=0, en_4=0, en_5=0;
    wire done_3, done_4, done_5;
    
    systolic_tester #(.N(3)) t3 (.clk(clk), .rst(rst), .en(en_3), .done(done_3));
    systolic_tester #(.N(4)) t4 (.clk(clk), .rst(rst), .en(en_4), .done(done_4));
    systolic_tester #(.N(5)) t5 (.clk(clk), .rst(rst), .en(en_5), .done(done_5));
    
    initial begin
        $dumpfile("systolic_multi_n_tb.vcd");
        $dumpvars(0, systolic_multi_n_tb);

        clk = 0;
        rst = 1;
        // Hold reset
        #20 rst = 0;
        
        // Run N=3 Test
        en_3 = 1;
        wait(done_3);
        en_3 = 0;
        
        $display("\n");
        
        // Run N=4 Test
        en_4 = 1;
        wait(done_4);
        en_4 = 0;

        $display("\n");
        
        // Run N=5 Test
        en_5 = 1;
        wait(done_5);
        en_5 = 0;
        
        $display("\nAll multi-N tests completed successfully.");
        $finish;
    end
endmodule
