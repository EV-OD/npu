`timescale 1ns / 1ps

module tb_systolic_array;

    parameter N = 3;
    parameter DATA_WIDTH = 16;
    parameter ACCUM_WIDTH = 40;
    parameter DELAY_PER_STEP = 2;

    reg clk, rst;
    reg acc_clr, acc_en;
    reg [(N*DATA_WIDTH)-1:0] in_left_raw, in_top_raw;
    wire [(N*DATA_WIDTH)-1:0] in_left_skewed, in_top_skewed;
    wire [(N*N*ACCUM_WIDTH)-1:0] out_c;

    // Skew buffers (same as in system.v)
    skew_buffer #(.N(N), .DATA_WIDTH(DATA_WIDTH), .DELAY_PER_STEP(DELAY_PER_STEP)) skew_a (
        .clk(clk), .rst(rst), .din(in_left_raw), .dout(in_left_skewed)
    );
    skew_buffer #(.N(N), .DATA_WIDTH(DATA_WIDTH), .DELAY_PER_STEP(DELAY_PER_STEP)) skew_b (
        .clk(clk), .rst(rst), .din(in_top_raw), .dout(in_top_skewed)
    );

    systolic_array_nxn_ctrl #(.N(N), .DATA_WIDTH(DATA_WIDTH), .ACCUM_WIDTH(ACCUM_WIDTH)) uut (
        .clk(clk), .rst(rst),
        .acc_clr(acc_clr), .acc_en(acc_en),
        .in_left(in_left_skewed), .in_top(in_top_skewed), .out_c(out_c)
    );

    always #5 clk = ~clk;

    integer i, j, k, cc, errors, pass_count, fail_count;
    integer r, c;
    reg signed [ACCUM_WIDTH-1:0] got;
    reg signed [DATA_WIDTH-1:0] A [0:N-1][0:N-1];
    reg signed [DATA_WIDTH-1:0] B [0:N-1][0:N-1];
    reg signed [ACCUM_WIDTH-1:0] expected [0:N-1][0:N-1];

    task check;
        input [255:0] msg;
        input cond;
        begin
            if (cond) pass_count = pass_count + 1;
            else begin
                $display("  FAIL: %s @ %0t", msg, $time);
                errors = errors + 1; fail_count = fail_count + 1;
            end
        end
    endtask

    task ps;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    // Feed one pair at negedge (like system.v does with data_feed_active)
    task feed_pair;
        input integer p;
        begin
            @(negedge clk);
            in_left_raw <= 0;
            in_top_raw <= 0;
            for (i = 0; i < N; i = i + 1)
                in_left_raw[(i * DATA_WIDTH) +: DATA_WIDTH] <= A[i][p];
            for (j = 0; j < N; j = j + 1)
                in_top_raw[(j * DATA_WIDTH) +: DATA_WIDTH] <= B[p][j];
        end
    endtask

    // Feed zeros at negedge (between pairs)
    task feed_zeros;
        begin
            @(negedge clk);
            in_left_raw <= 0;
            in_top_raw <= 0;
        end
    endtask

    // Compute C = A*B, then feed N pairs separated by zero cycles,
    // wait, and verify all elements
    task run_multiply;
        input integer extra_wait;
        begin
            for (r = 0; r < N; r = r + 1)
                for (c = 0; c < N; c = c + 1) begin
                    expected[r][c] = 0;
                    for (cc = 0; cc < N; cc = cc + 1)
                        expected[r][c] = expected[r][c] + A[r][cc] * B[cc][c];
                end

            // Clear
            @(negedge clk);
            acc_clr = 1; acc_en = 1;
            in_left_raw <= 0; in_top_raw <= 0;
            ps();
            acc_clr = 0;

            // Feed N pairs with gap cycles (like system's data_valid every 2 cycles)
            for (cc = 0; cc < N; cc = cc + 1) begin
                feed_pair(cc);
                ps();  // posedge: raw latched by skew at negedge, now propagates
                feed_zeros();
                ps();  // posedge: zeros latched
            end

            // Drain
            repeat (2 + extra_wait) begin
                feed_zeros();
                ps();
            end

            // Wait for pipeline to settle
            repeat (4) ps();

            // Check
            for (r = 0; r < N; r = r + 1)
                for (c = 0; c < N; c = c + 1) begin
                    got = $signed(out_c[((r*N+c)*ACCUM_WIDTH) +: ACCUM_WIDTH]);
                    if (got !== expected[r][c]) begin
                        $display("  FAIL: C[%0d][%0d] exp=%0d got=%0d", r, c, expected[r][c], got);
                        errors = errors + 1; fail_count = fail_count + 1;
                    end else pass_count = pass_count + 1;
                end
        end
    endtask

    initial begin
        $dumpfile("tb_systolic_array.vcd");
        $dumpvars(0, tb_systolic_array);

        clk = 0; rst = 1; acc_clr = 0; acc_en = 1;
        in_left_raw = 0; in_top_raw = 0;
        errors = 0; pass_count = 0; fail_count = 0;

        #18 rst = 0;
        ps();

        $display("=== SYSTOLIC ARRAY NxN TEST (N=%0d) ===", N);
        $display("");

        // =====================================================
        // Test 1: Basic matrix multiply
        // =====================================================
        $display("--- Test 1: Basic matrix multiply ---");
        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1) begin
                A[i][j] = i * N + j + 1;
                B[i][j] = j * N + i + 1;
            end
        run_multiply(6);

        // =====================================================
        // Test 2: Negative values
        // =====================================================
        $display("--- Test 2: Negative values ---");
        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1) begin
                A[i][j] = -(i * N + j + 1);
                B[i][j] = -(j * N + i + 1);
            end
        run_multiply(6);

        // =====================================================
        // Test 3: All zeros
        // =====================================================
        $display("--- Test 3: All zeros ---");
        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1) begin
                A[i][j] = 0;
                B[i][j] = 0;
            end
        run_multiply(6);

        // =====================================================
        // Test 4: Mixed signs
        // =====================================================
        $display("--- Test 4: Mixed signs ---");
        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1) begin
                A[i][j] = (i % 2 == 0) ? (i*N+j+1) : -(i*N+j+1);
                B[i][j] = (j % 2 == 0) ? (j*N+i+1) : -(j*N+i+1);
            end
        run_multiply(6);

        // =====================================================
        // Test 5: Identity pattern (A=I => C=B)
        // =====================================================
        $display("--- Test 5: Identity pattern (A=I => C=B) ---");
        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1) begin
                A[i][j] = (i == j) ? 1 : 0;
                B[i][j] = i * N + j + 5;
            end
        run_multiply(6);

        // =====================================================
        // Test 6: acc_clr at start (realistic system usage)
        //   Run two separate matrix multiplies with acc_clr between them
        // =====================================================
        $display("--- Test 6: acc_clr between computations ---");
        // First computation: identity (A=I, B=A => C=A)
        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1) begin
                A[i][j] = (i == j) ? 1 : 0;
                B[i][j] = i * N + j + 1;
            end
        run_multiply(6);

        // Second computation without clearing (stale accumulation would corrupt)
        // Then do it again WITH clearing to show it works
        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1) begin
                A[i][j] = 2;
                B[i][j] = 3;
            end
        // run_multiply already has acc_clr=1 at start, so this verifies clearing works
        run_multiply(6);

        // =====================================================
        // Test 7: N=1 edge case
        // =====================================================
        $display("--- Test 7: N=1 sub-tile (only first pair) ---");
        begin
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin
                    A[i][j] = 5;
                    B[i][j] = 7;
                end

            for (r = 0; r < N; r = r + 1)
                for (c = 0; c < N; c = c + 1)
                    expected[r][c] = A[r][0] * B[0][c];

            @(negedge clk);
            acc_clr = 1; acc_en = 1;
            in_left_raw <= 0; in_top_raw <= 0;
            ps();
            acc_clr = 0;

            // Feed just 1 pair (like M=1 sub-tile)
            feed_pair(0); ps(); feed_zeros(); ps();

            repeat (10) begin feed_zeros(); ps(); end
            repeat (4) ps();

            for (r = 0; r < N; r = r + 1)
                for (c = 0; c < N; c = c + 1) begin
                    got = $signed(out_c[((r*N+c)*ACCUM_WIDTH) +: ACCUM_WIDTH]);
                    if (got !== expected[r][c]) begin
                        $display("  FAIL: sub-tile C[%0d][%0d] exp=%0d got=%0d", r, c, expected[r][c], got);
                        errors = errors + 1; fail_count = fail_count + 1;
                    end else pass_count = pass_count + 1;
                end
        end

        // =====================================================
        // Test 8: Large values (max 16-bit)
        // =====================================================
        $display("--- Test 8: Large values ---");
        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1) begin
                A[i][j] = 32767;
                B[i][j] = 32767;
            end
        run_multiply(6);

        // =====================================================
        // Summary
        // =====================================================
        $display("");
        $display("--- RESULTS ---");
        $display("  Checks: %0d passed, %0d failed, %0d total",
                 pass_count, fail_count, pass_count + fail_count);
        if (errors === 0)
            $display("*** SYSTOLIC ARRAY TEST PASSED ***");
        else
            $display("*** SYSTOLIC ARRAY TEST FAILED ***");
        #100 $finish;
    end

endmodule
