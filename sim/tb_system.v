`timescale 1ns / 1ps

module tb_system;

    parameter N = 3;
    parameter DATA_WIDTH = 16;
    parameter ACCUM_WIDTH = 40;

    reg clk, rst, start;
    reg act_we, wgt_we;
    reg [$clog2(N*N)-1:0] act_waddr, wgt_waddr;
    reg signed [DATA_WIDTH-1:0] act_din, wgt_din;
    reg [$clog2(N)-1:0] out_raddr;
    wire signed [(N*ACCUM_WIDTH)-1:0] out_dout;
    wire done;

    system #(.N(N), .DATA_WIDTH(DATA_WIDTH), .ACCUM_WIDTH(ACCUM_WIDTH)) uut (
        .clk(clk), .rst(rst), .start(start),
        .act_we(act_we), .act_waddr(act_waddr), .act_din(act_din),
        .wgt_we(wgt_we), .wgt_waddr(wgt_waddr), .wgt_din(wgt_din),
        .out_raddr(out_raddr), .out_dout(out_dout),
        .done(done)
    );

    always #5 clk = ~clk;

    reg signed [DATA_WIDTH-1:0] A [0:N-1][0:N-1];
    reg signed [DATA_WIDTH-1:0] B [0:N-1][0:N-1];
    reg signed [ACCUM_WIDTH-1:0] C_exp [0:N-1][0:N-1];
    reg signed [ACCUM_WIDTH-1:0] actual;

    integer i, j, k, errors, total_errors;
    integer seed;

    task ps;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task run_system_test;
        input [1024:0] test_name;
        input integer det;  // 0=deterministic, else=seed
        integer r, c, kk;
        reg signed [DATA_WIDTH-1:0] a_val, b_val;
        begin
            $display("");
            $display("==================================================");
            $display(" %s (N=%0d)", test_name, N);
            $display("==================================================");

            // Generate matrices
            seed = det;
            for (r = 0; r < N; r = r + 1) begin
                for (c = 0; c < N; c = c + 1) begin
                    if (det == 0) begin
                        a_val = (r * N + c + 1) * 2 - 5;
                        b_val = (c * N + r + 1) * 2 - 5;
                    end else begin
                        a_val = ($random(seed) % 15) - 7;
                        b_val = ($random(seed) % 15) - 7;
                    end
                    A[r][c] = a_val;
                    B[r][c] = b_val;
                end
            end

            // Print A and B
            $display("Matrix A:");
            for (r = 0; r < N; r = r + 1) begin
                $write("  ");
                for (c = 0; c < N; c = c + 1) $write("%4d ", A[r][c]);
                $write("\n");
            end
            $display("Matrix B:");
            for (r = 0; r < N; r = r + 1) begin
                $write("  ");
                for (c = 0; c < N; c = c + 1) $write("%4d ", B[r][c]);
                $write("\n");
            end

            // Compute expected C
            for (r = 0; r < N; r = r + 1)
                for (c = 0; c < N; c = c + 1) begin
                    C_exp[r][c] = 0;
                    for (kk = 0; kk < N; kk = kk + 1)
                        C_exp[r][c] = C_exp[r][c] + A[r][kk] * B[kk][c];
                end

            $display("Expected C = A*B:");
            for (r = 0; r < N; r = r + 1) begin
                $write("  ");
                for (c = 0; c < N; c = c + 1) $write("%4d ", C_exp[r][c]);
                $write("\n");
            end

            // Preload activation buffer
            $display("");
            $display("Loading activation buffer...");
            for (r = 0; r < N; r = r + 1)
                for (c = 0; c < N; c = c + 1) begin
                    @(negedge clk);
                    act_we = 1;
                    act_waddr = r * N + c;
                    act_din = A[r][c];
                    ps();
                    act_we = 0;
                end

            // Preload weight buffer
            $display("Loading weight buffer...");
            for (r = 0; r < N; r = r + 1)
                for (c = 0; c < N; c = c + 1) begin
                    @(negedge clk);
                    wgt_we = 1;
                    wgt_waddr = r * N + c;
                    wgt_din = B[r][c];
                    ps();
                    wgt_we = 0;
                end

            // Start computation (at posedge, matching original tb_system timing)
            $display("Starting computation...");
            #1;  // avoid race with posedge signals settling
            start = 1;
            @(posedge clk);
            #1 start = 0;

            // Wait for done
            wait(done);
            @(negedge clk);
            $display("Done! Checking output buffer...");

            // Read and verify output buffer
            errors = 0;
            for (r = 0; r < N; r = r + 1) begin
                out_raddr = r;
                #1;
                for (c = 0; c < N; c = c + 1) begin
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
            for (r = 0; r < N; r = r + 1) begin
                $write("  ");
                for (c = 0; c < N; c = c + 1) $write("%4d ", C_exp[r][c]);
                $write("\n");
            end

            if (errors == 0) begin
                $display(">>> %s PASSED (all %0d elements correct)", test_name, N*N);
            end else begin
                $display(">>> %s FAILED with %0d / %0d errors", test_name, errors, N*N);
            end
            total_errors = total_errors + errors;

            // Wait for sequencer to return to IDLE
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
        total_errors = 0;

        #18 rst = 0;
        ps();

        run_system_test("SYSTEM TEST 1: Deterministic Matrix Multiply", 0);
        run_system_test("SYSTEM TEST 2: Random Matrix Multiply", 42);
        run_system_test("SYSTEM TEST 3: Random Matrix Multiply", 99);

        $display("");
        $display("==================================================");
        if (total_errors == 0)
            $display(" ALL %0d SYSTEM TESTS PASSED (N=%0d)", 3, N);
        else
            $display(" %0d SYSTEM TEST(S) FAILED with %0d total errors", 3, total_errors);
        $display("==================================================");
        $finish;
    end

endmodule
