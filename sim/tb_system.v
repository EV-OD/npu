`timescale 1ns / 1ps

module tb_system;

    parameter N = 3;
    parameter DATA_WIDTH = 16;
    parameter ACCUM_WIDTH = 40;

    reg clk, rst, start;
    reg [31:0] matrix_size, act_base, wgt_base, out_base;
    reg act_we, wgt_we;
    reg [$clog2(2*N*N)-1:0] act_waddr, wgt_waddr;
    reg signed [DATA_WIDTH-1:0] act_din, wgt_din;
    reg [$clog2(2*N)-1:0] out_raddr;
    wire signed [(N*ACCUM_WIDTH)-1:0] out_dout;
    wire done;

    system #(.N(N), .DATA_WIDTH(DATA_WIDTH), .ACCUM_WIDTH(ACCUM_WIDTH)) uut (
        .clk(clk), .rst(rst), .start(start),
        .matrix_size(matrix_size), .act_base(act_base),
        .wgt_base(wgt_base), .out_base(out_base),
        .act_we(act_we), .act_waddr(act_waddr), .act_din(act_din),
        .wgt_we(wgt_we), .wgt_waddr(wgt_waddr), .wgt_din(wgt_din),
        .out_raddr(out_raddr), .out_dout(out_dout),
        .done(done)
    );

    always #5 clk = ~clk;

    reg signed [DATA_WIDTH-1:0] A [0:N-1][0:N-1];
    reg signed [DATA_WIDTH-1:0] B [0:N-1][0:N-1];
    reg signed [ACCUM_WIDTH-1:0] C_exp [0:N-1][0:N-1];
    reg signed [DATA_WIDTH-1:0] A2 [0:N-1][0:N-1];
    reg signed [DATA_WIDTH-1:0] B2 [0:N-1][0:N-1];
    reg signed [ACCUM_WIDTH-1:0] C_exp2 [0:N-1][0:N-1];
    reg signed [ACCUM_WIDTH-1:0] actual;

    integer i, j, k, errors, total_errors;
    integer seed;

    task ps;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task start_compute;
        begin
            #1;
            start = 1;
            @(posedge clk);
            #1;
            start = 0;
        end
    endtask

    task run_system_test;
        input [1024:0] test_name;
        input integer M;       // tile size
        input integer ab;      // act base (column offset)
        input integer wb;      // wgt base (row offset)
        input integer ob;      // out base (row offset)
        input integer det;     // 0=deterministic, else=seed
        integer r, c, kk;
        reg signed [DATA_WIDTH-1:0] a_val, b_val;
        begin
            $display("");
            $display("==================================================");
            $display(" %s  (N=%0d, M=%0d, ab=%0d, wb=%0d, ob=%0d)", test_name, N, M, ab, wb, ob);
            $display("==================================================");

            seed = det;
            for (r = 0; r < M; r = r + 1)
                for (c = 0; c < M; c = c + 1) begin
                    if (det == 0) begin
                        a_val = (r * M + c + 1) * 2 - 5;
                        b_val = (c * M + r + 1) * 2 - 5;
                    end else begin
                        a_val = ($random(seed) % 15) - 7;
                        b_val = ($random(seed) % 15) - 7;
                    end
                    A[r][c] = a_val;
                    B[r][c] = b_val;
                end

            $display("Matrix A (%0dx%0d):", M, M);
            for (r = 0; r < M; r = r + 1) begin
                $write("  ");
                for (c = 0; c < M; c = c + 1) $write("%4d ", A[r][c]);
                $write("\n");
            end
            $display("Matrix B (%0dx%0d):", M, M);
            for (r = 0; r < M; r = r + 1) begin
                $write("  ");
                for (c = 0; c < M; c = c + 1) $write("%4d ", B[r][c]);
                $write("\n");
            end

            for (r = 0; r < M; r = r + 1)
                for (c = 0; c < M; c = c + 1) begin
                    C_exp[r][c] = 0;
                    for (kk = 0; kk < M; kk = kk + 1)
                        C_exp[r][c] = C_exp[r][c] + A[r][kk] * B[kk][c];
                end

            $display("Expected C = A*B:");
            for (r = 0; r < M; r = r + 1) begin
                $write("  ");
                for (c = 0; c < M; c = c + 1) $write("%4d ", C_exp[r][c]);
                $write("\n");
            end

            // Set runtime config
            matrix_size = M;
            act_base = ab;
            wgt_base = wb;
            out_base = ob;

            // Preload tile into buffers (A with COL_MAJOR base=ab means column ab is first feed)
            // For activation COL_MAJOR: element at buffer (row r, col c) is stored at r*N + c.
            // The feed reads column (ab + feed_idx). The columns/rows must map to tile rows/cols 0..M-1.
            // We store tile row r, column c at buffer row r, column (ab + c) for activation,
            // and buffer row (wb + r), column c for weight.
            $display("Loading buffers...");
            for (r = 0; r < M; r = r + 1)
                for (c = 0; c < M; c = c + 1) begin
                    @(negedge clk);
                    act_we = 1;
                    act_waddr = r * N + (ab + c);
                    act_din = A[r][c];
                    ps();
                    act_we = 0;
                end

            for (r = 0; r < M; r = r + 1)
                for (c = 0; c < M; c = c + 1) begin
                    @(negedge clk);
                    wgt_we = 1;
                    wgt_waddr = (wb + r) * N + c;
                    wgt_din = B[r][c];
                    ps();
                    wgt_we = 0;
                end

            start_compute;
            wait(done);
            @(negedge clk);
            $display("Done! Checking output buffer...");

            errors = 0;
            for (r = 0; r < M; r = r + 1) begin
                out_raddr = ob + r;
                #1;
                for (c = 0; c < M; c = c + 1) begin
                    actual = $signed(out_dout[(c*ACCUM_WIDTH) +: ACCUM_WIDTH]);
                    if (actual == C_exp[r][c]) begin
                        $write("%4d ", actual);
                    end else begin
                        $write("%4d*", actual);
                        $display("   [ERROR] C[%0d][%0d]: exp=%0d got=%0d", r, c, C_exp[r][c], actual);
                        errors = errors + 1;
                    end
                end
                $write("\n");
            end
            $display("Expected:");
            for (r = 0; r < M; r = r + 1) begin
                $write("  ");
                for (c = 0; c < M; c = c + 1) $write("%4d ", C_exp[r][c]);
                $write("\n");
            end

            if (errors == 0)
                $display(">>> %s PASSED (all %0d elements correct)", test_name, M*M);
            else
                $display(">>> %s FAILED with %0d / %0d errors", test_name, errors, M*M);
            total_errors = total_errors + errors;

            repeat (5) @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("tb_system.vcd");
        $dumpvars(0, tb_system);

        clk = 0; rst = 1; start = 0;
        act_we = 0; wgt_we = 0;
        act_waddr = 0; wgt_waddr = 0;
        act_din = 0; wgt_din = 0;
        out_raddr = 0;
        matrix_size = N; act_base = 0; wgt_base = 0; out_base = 0;
        total_errors = 0;

        #18 rst = 0;
        ps();

        // Full N×N tests
        run_system_test("TEST 1: Full deterministic", N, 0, 0, 0, 0);
        run_system_test("TEST 2: Full random", N, 0, 0, 0, 42);
        run_system_test("TEST 3: Full random", N, 0, 0, 0, 99);

        // Sub-tile tests (M < N) — only if N > 2
        if (N > 2) begin
            run_system_test("TEST 4: Sub-tile M=2 deterministic", 2, 0, 0, 0, 0);
            run_system_test("TEST 5: Sub-tile M=2 random", 2, 0, 0, 0, 77);
            run_system_test("TEST 6: Sub-tile M=2 offset (ab=1,wb=1,ob=1)", 2, 1, 1, 1, 0);
        end

        // ============================================================
        // PING-PONG DOUBLE BUFFER TEST
        // ============================================================
        $display("");
        $display("==================================================");
        $display(" PING-PONG DOUBLE BUFFER TEST (N=%0d)", N);
        $display("==================================================");
        $display("");

        // Generate matrix 1 (Ping) — place in A, B
        $display("Generating matrix 1 (Ping)...");
        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1) begin
                A[i][j] = (i * N + j + 1) * 2 - 5;
                B[i][j] = (j * N + i + 1) * 2 - 5;
            end

        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1) begin
                C_exp[i][j] = 0;
                for (k = 0; k < N; k = k + 1)
                    C_exp[i][j] = C_exp[i][j] + A[i][k] * B[k][j];
            end

        // Preload Ping block
        $display("Preloading Ping block (activations)...");
        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1) begin
                @(negedge clk);
                act_we = 1;
                act_waddr = i * N + j;
                act_din = A[i][j];
                ps(); act_we = 0;
            end

        $display("Preloading Ping block (weights)...");
        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1) begin
                @(negedge clk);
                wgt_we = 1;
                wgt_waddr = i * N + j;
                wgt_din = B[i][j];
                ps(); wgt_we = 0;
            end

        // Generate matrix 2 (Pong) — place in A2, B2
        $display("Generating matrix 2 (Pong)...");
        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1) begin
                A2[i][j] = 100 + (i * N + j + 1) * 2 - 5;
                B2[i][j] = 100 + (j * N + i + 1) * 2 - 5;
            end

        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1) begin
                C_exp2[i][j] = 0;
                for (k = 0; k < N; k = k + 1)
                    C_exp2[i][j] = C_exp2[i][j] + A2[i][k] * B2[k][j];
            end

        // Start compute on Ping block (bases = 0)
        matrix_size = N; act_base = 0; wgt_base = 0; out_base = 0;
        $display("Compute started on Ping block (bases=0)...");
        start_compute;

        // While computing, preload Pong block into the second half of buffers
        $display("Preloading Pong block while Ping computes...");
        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1) begin
                @(negedge clk);
                act_we = 1;
                act_waddr = N*N + i * N + j;  // Pong activation block
                act_din = A2[i][j];
                ps(); act_we = 0;
            end

        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1) begin
                @(negedge clk);
                wgt_we = 1;
                wgt_waddr = N*N + i * N + j;  // Pong weight block
                wgt_din = B2[i][j];
                ps(); wgt_we = 0;
            end

        // Wait for Ping computation to finish
        wait(done);
        @(negedge clk);
        $display("Ping done! Verifying result...");

        errors = 0;
        for (i = 0; i < N; i = i + 1) begin
            out_raddr = i;
            #1;
            for (j = 0; j < N; j = j + 1) begin
                actual = $signed(out_dout[(j*ACCUM_WIDTH) +: ACCUM_WIDTH]);
                if (actual !== C_exp[i][j]) begin
                    $display("  [ERROR] Ping C[%0d][%0d]: exp=%0d got=%0d", i, j, C_exp[i][j], actual);
                    errors = errors + 1;
                end
            end
        end
        if (errors == 0)
            $display(">>> Ping result CORRECT (all %0d elements)", N*N);
        else
            $display(">>> Ping result FAILED with %0d errors", errors);
        total_errors = total_errors + errors;

        // Start compute on Pong block (bases = N)
        matrix_size = N; act_base = N; wgt_base = N; out_base = N;
        $display("Compute started on Pong block (bases=N=%0d)...", N);
        start_compute;
        wait(done);
        @(negedge clk);
        $display("Pong done! Verifying result...");

        errors = 0;
        for (i = 0; i < N; i = i + 1) begin
            out_raddr = N + i;
            #1;
            for (j = 0; j < N; j = j + 1) begin
                actual = $signed(out_dout[(j*ACCUM_WIDTH) +: ACCUM_WIDTH]);
                if (actual !== C_exp2[i][j]) begin
                    $display("  [ERROR] Pong C[%0d][%0d]: exp=%0d got=%0d", i, j, C_exp2[i][j], actual);
                    errors = errors + 1;
                end
            end
        end
        if (errors == 0)
            $display(">>> Pong result CORRECT (all %0d elements)", N*N);
        else
            $display(">>> Pong result FAILED with %0d errors", errors);
        total_errors = total_errors + errors;

        if (total_errors == 0)
            $display(">>> PING-PONG TEST PASSED");
        else
            $display(">>> PING-PONG TEST FAILED");

        $display("");
        $display("==================================================");
        if (total_errors == 0)
            $display(" ALL %0d SYSTEM TESTS PASSED (N=%0d)", (N > 2) ? 6 : 3, N);
        else
            $display(" %0d SYSTEM TEST(S) FAILED with %0d total errors", (N > 2) ? 6 : 3, total_errors);
        $display("==================================================");
        $finish;
    end

endmodule
