`timescale 1ns / 1ps

// =========================================================
// Wrapper to combine Skew Buffers with the Systolic Array
// =========================================================
module systolic_system #(
    parameter N = 3,
    parameter DATA_WIDTH = 16,
    parameter ACCUM_WIDTH = 40
)(
    input clk,
    input rst,
    input  [(N * DATA_WIDTH)-1:0]        raw_a_col, // Raw column from A
    input  [(N * DATA_WIDTH)-1:0]        raw_b_row, // Raw row from B
    output [(N * N * ACCUM_WIDTH)-1:0]   out_c      // Computed Matrix C
);

    wire [(N * DATA_WIDTH)-1:0] skewed_a;
    wire [(N * DATA_WIDTH)-1:0] skewed_b;

    // Delay factor = 2 (matches the pipeline bubbles required for PEs)
    skew_buffer #(
        .N(N), .DATA_WIDTH(DATA_WIDTH), .DELAY_PER_STEP(2)
    ) skew_a (
        .clk(clk), .rst(rst), .din(raw_a_col), .dout(skewed_a)
    );

    skew_buffer #(
        .N(N), .DATA_WIDTH(DATA_WIDTH), .DELAY_PER_STEP(2)
    ) skew_b (
        .clk(clk), .rst(rst), .din(raw_b_row), .dout(skewed_b)
    );

    systolic_array_nxn #(
        .N(N), .DATA_WIDTH(DATA_WIDTH), .ACCUM_WIDTH(ACCUM_WIDTH)
    ) sys_arr (
        .clk(clk), .rst(rst), .in_left(skewed_a), .in_top(skewed_b), .out_c(out_c)
    );

endmodule


// =========================================================
// Parameterized Tester for N x N Integrated Array
// =========================================================
module sys_system_tester #(
    parameter N = 3,
    parameter DATA_WIDTH = 16,
    parameter ACCUM_WIDTH = 40
)(
    input clk, input rst, input en, output reg done
);
    reg  [(N * DATA_WIDTH)-1:0] in_a_col;
    reg  [(N * DATA_WIDTH)-1:0] in_b_row;
    wire [(N * N * ACCUM_WIDTH)-1:0] out_c;

    systolic_system #(
        .N(N), .DATA_WIDTH(DATA_WIDTH), .ACCUM_WIDTH(ACCUM_WIDTH)
    ) uut (
        .clk(clk), .rst(rst), .raw_a_col(in_a_col), .raw_b_row(in_b_row), .out_c(out_c)
    );

    reg signed [DATA_WIDTH-1:0] A [0:N-1][0:N-1];
    reg signed [DATA_WIDTH-1:0] B [0:N-1][0:N-1];
    reg signed [ACCUM_WIDTH-1:0] C_exp [0:N-1][0:N-1];

    integer i, j, k, step;
    integer err_cnt;

    initial begin
        done = 0;
        in_a_col = 0;
        in_b_row = 0;
        err_cnt = 0;

        // wait for enable
        wait(en);
        @(negedge clk);
        
        $display("\n==================================================");
        $display(" STARTING INTEGRATED TEST FOR N = %0d ", N);
        $display("==================================================");

        // Build random matrices A, B
        for (i=0; i<N; i=i+1) begin
            for(j=0; j<N; j=j+1) begin
                A[i][j] = ($random % 5) + 1; // Easy to read small positive numbers
                B[i][j] = ($random % 5) + 1;
                C_exp[i][j] = 0;
            end
        end

        // Compute Expected C = A * B
        for (i=0; i<N; i=i+1)
            for(j=0; j<N; j=j+1)
                for(k=0; k<N; k=k+1) C_exp[i][j] = C_exp[i][j] + A[i][k] * B[k][j];

        $display("Matrix A:");
        for (i=0; i<N; i=i+1) begin
            $write("  ");
            for (j=0; j<N; j=j+1) $write("%4d ", A[i][j]);
            $write("\n");
        end
        $display("\nMatrix B:");
        for (i=0; i<N; i=i+1) begin
            $write("  ");
            for (j=0; j<N; j=j+1) $write("%4d ", B[i][j]);
            $write("\n");
        end
        $display("\n--- EXTENDED CYCLE-BY-CYCLE TRACE ---");
        
        // Feed matrices sequentially (inject real column every 2nd cycle because of PE data path bubble)
        for (step = 0; step < 4*N + 10; step = step + 1) begin
            @(negedge clk);
            
            if (step % 2 == 0 && (step / 2) < N) begin
                for(i=0; i<N; i=i+1) begin
                    in_a_col[(i*DATA_WIDTH)+:DATA_WIDTH] <= A[i][step/2];
                    in_b_row[(i*DATA_WIDTH)+:DATA_WIDTH] <= B[step/2][i];
                end
            end else begin
                in_a_col <= 0;
                in_b_row <= 0;
            end
            
            #1; // Delay print to evaluate purely on latched values
            $write("[Cycle %2d] Raw A_col=[", step);
            for(i=0; i<N; i=i+1) $write("%3d ", $signed(in_a_col[i*16+:16]));
            $write("] Raw B_row=[");
            for(i=0; i<N; i=i+1) $write("%3d ", $signed(in_b_row[i*16+:16]));
            $write("]   ==>   Skew A_out=[");
            for(i=0; i<N; i=i+1) $write("%3d ", $signed(uut.skewed_a[i*16+:16]));
            $write("] Skew B_out=[");
            for(i=0; i<N; i=i+1) $write("%3d ", $signed(uut.skewed_b[i*16+:16]));
            $display("]");
        end

        // Verify Output Check
        $display("\nMatrix C (Actual vs Expected):");
        err_cnt = 0;
        for (i=0; i<N; i=i+1) begin
            $write("  ");
            for(j=0; j<N; j=j+1) begin
                $write("%4d ", $signed(out_c[((i*N+j)*ACCUM_WIDTH)+:ACCUM_WIDTH]));
                if ($signed(out_c[((i*N+j)*ACCUM_WIDTH)+:ACCUM_WIDTH]) !== C_exp[i][j]) begin
                    $display("\n[ERROR] C[%0d][%0d]: Exp=%0d, Got=%0d", i, j, C_exp[i][j], $signed(out_c[((i*N+j)*ACCUM_WIDTH)+:ACCUM_WIDTH]));
                    err_cnt = err_cnt + 1;
                end
            end
            $write("\n");
        end
        
        if (err_cnt == 0) $display("*** N=%0d TEST PASSED (C matches A*B perfectly) ***", N);
        else $display("*** N=%0d TEST FAILED wiith %0d errors ***", N, err_cnt);

        done = 1;
    end
endmodule


// =========================================================
// Top-Level Testbench
// =========================================================
module skew_buffer_tb;

    parameter DATA_WIDTH = 16;
    parameter ACCUM_WIDTH = 40;

    reg clk;
    reg rst;
    
    always #5 clk = ~clk;

    // ----- INDIVIDUAL SKEW BUFFER TEST (N=3) -----
    reg  [(3 * DATA_WIDTH)-1:0] in_skew_only;
    wire [(3 * DATA_WIDTH)-1:0] out_skew_only;

    skew_buffer #(.N(3), .DATA_WIDTH(16), .DELAY_PER_STEP(1)) ind_skew (
        .clk(clk), .rst(rst), .din(in_skew_only), .dout(out_skew_only)
    );

    // ----- SYSTOLIC TESTERS -----
    reg en_3=0, en_4=0, en_5=0;
    wire done_3, done_4, done_5;

    sys_system_tester #(.N(3)) t3 (.clk(clk), .rst(rst), .en(en_3), .done(done_3));
    sys_system_tester #(.N(4)) t4 (.clk(clk), .rst(rst), .en(en_4), .done(done_4));
    sys_system_tester #(.N(5)) t5 (.clk(clk), .rst(rst), .en(en_5), .done(done_5));

    integer step;

    initial begin
        clk = 0;
        rst = 1;
        in_skew_only = 0;

        $dumpfile("skew_buffer_tb.vcd");
        $dumpvars(0, skew_buffer_tb);

        #30 rst = 0;
        
        $display("==================================================");
        $display("   TEST 1: VERIFY INDIVIDUAL SKEW BUFFER BEHAVIOR ");
        $display("==================================================");
        @(negedge clk);
        in_skew_only[(0*DATA_WIDTH)+:DATA_WIDTH] <= 16'h0111;
        in_skew_only[(1*DATA_WIDTH)+:DATA_WIDTH] <= 16'h0222;
        in_skew_only[(2*DATA_WIDTH)+:DATA_WIDTH] <= 16'h0333;
        
        for(step=0; step<5; step=step+1) begin
            #1;
            $display("[Cycle %0d] Row0=%h, Row1=%h, Row2=%h", step, 
                out_skew_only[(0*DATA_WIDTH)+:DATA_WIDTH],
                out_skew_only[(1*DATA_WIDTH)+:DATA_WIDTH],
                out_skew_only[(2*DATA_WIDTH)+:DATA_WIDTH]);
            @(negedge clk);
            if (step == 0) in_skew_only <= 0;
        end
        $display("  -> Evaluated diagonal cascade!\n");

        // Execute N=3 Integrated Test
        en_3 = 1; wait(done_3); en_3 = 0;
        
        // Execute N=4 Integrated Test
        en_4 = 1; wait(done_4); en_4 = 0;
        
        // Execute N=5 Integrated Test
        en_5 = 1; wait(done_5); en_5 = 0;

        $display("\n==================================================");
        $display("             ALL SKEW EXPERIMENTS DONE            ");
        $display("==================================================");
        $finish;
    end

endmodule
