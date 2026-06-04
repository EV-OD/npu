`timescale 1ns / 1ps

module npu_core #(
    parameter N = 4,
    parameter DATA_WIDTH = 16,
    parameter ACCUM_WIDTH = 40
)(
    input  wire                              clk,
    input  wire                              rst,
    input  wire                              start,
    output wire                              seq_data_valid,
    output wire [31:0]                       seq_data_idx,
    input  wire [(N * DATA_WIDTH)-1:0]       raw_a_col,
    input  wire [(N * DATA_WIDTH)-1:0]       raw_b_row,
    output wire                              result_valid,
    output wire [(N * N * ACCUM_WIDTH)-1:0]  result,
    output wire                              done
);

    wire acc_clr, acc_en, readout_trig, busy;
    wire [(N * DATA_WIDTH)-1:0] skewed_a, skewed_b;
    wire [(N * N * ACCUM_WIDTH)-1:0] pe_c;
    wire [(N * ACCUM_WIDTH)-1:0] shift_row;
    wire shift_row_valid;

    execution_sequencer #(.N(N)) seq (
        .clk(clk), .rst(rst), .start(start),
        .data_valid(seq_data_valid), .data_idx(seq_data_idx),
        .acc_clr(acc_clr), .acc_en(acc_en),
        .readout_trig(readout_trig),
        .busy(busy), .done(done)
    );

    skew_buffer #(.N(N), .DATA_WIDTH(DATA_WIDTH), .DELAY_PER_STEP(2)) skew_a (
        .clk(clk), .rst(rst), .din(raw_a_col), .dout(skewed_a)
    );
    skew_buffer #(.N(N), .DATA_WIDTH(DATA_WIDTH), .DELAY_PER_STEP(2)) skew_b (
        .clk(clk), .rst(rst), .din(raw_b_row), .dout(skewed_b)
    );

    systolic_array_nxn_ctrl #(.N(N), .DATA_WIDTH(DATA_WIDTH), .ACCUM_WIDTH(ACCUM_WIDTH)) sys_arr (
        .clk(clk), .rst(rst),
        .acc_clr(acc_clr), .acc_en(acc_en),
        .in_left(skewed_a), .in_top(skewed_b),
        .out_c(pe_c)
    );

    readout_shifter #(.N(N), .ACCUM_WIDTH(ACCUM_WIDTH)) rdout_shift (
        .clk(clk), .rst(rst),
        .load(readout_trig),
        .pe_c(pe_c),
        .row_out(shift_row),
        .row_valid(shift_row_valid),
        .shift_done()
    );

    readout_unit #(.N(N), .ACCUM_WIDTH(ACCUM_WIDTH)) rdout (
        .clk(clk), .rst(rst),
        .shift_valid(shift_row_valid),
        .row_in(shift_row),
        .valid(result_valid),
        .result(result)
    );

endmodule


module tb_system;

    parameter N = 3;
    parameter DATA_WIDTH = 16;
    parameter ACCUM_WIDTH = 40;

    reg clk, rst, start;
    reg [(N * DATA_WIDTH)-1:0] raw_a_col, raw_b_row;
    wire result_valid, done;
    wire [(N * N * ACCUM_WIDTH)-1:0] result;
    wire seq_data_valid;
    wire [31:0] seq_data_idx;

    npu_core #(.N(N), .DATA_WIDTH(DATA_WIDTH), .ACCUM_WIDTH(ACCUM_WIDTH)) uut (
        .clk(clk), .rst(rst), .start(start),
        .seq_data_valid(seq_data_valid), .seq_data_idx(seq_data_idx),
        .raw_a_col(raw_a_col), .raw_b_row(raw_b_row),
        .result_valid(result_valid), .result(result), .done(done)
    );

    always #5 clk = ~clk;

    reg signed [DATA_WIDTH-1:0] A [0:N-1][0:N-1];
    reg signed [DATA_WIDTH-1:0] B [0:N-1][0:N-1];
    reg signed [ACCUM_WIDTH-1:0] C_exp [0:N-1][0:N-1];
    reg signed [ACCUM_WIDTH-1:0] actual;

    integer i, j, k, errors, total_errors;
    integer di;

    reg data_feed_active;
    reg [31:0] feed_idx;

    always @(posedge clk) begin
        if (rst) begin
            data_feed_active <= 0;
            feed_idx <= 0;
        end else begin
            data_feed_active <= seq_data_valid;
            feed_idx <= seq_data_idx;
        end
    end

    always @(negedge clk) begin
        if (rst) begin
            raw_a_col <= 0;
            raw_b_row <= 0;
        end else if (data_feed_active) begin
            if (feed_idx < N) begin
                for (di = 0; di < N; di = di + 1) begin
                    raw_a_col[(di * DATA_WIDTH) +: DATA_WIDTH] <= A[di][feed_idx];
                    raw_b_row[(di * DATA_WIDTH) +: DATA_WIDTH] <= B[feed_idx][di];
                end
                $write("  FEED[%0d] @ %0t: A_col=[", feed_idx, $time);
                for (di = 0; di < N; di = di + 1) begin
                    $write("%0d", A[di][feed_idx]);
                    if (di < N-1) $write(" ");
                end
                $write("] B_row=[");
                for (di = 0; di < N; di = di + 1) begin
                    $write("%0d", B[feed_idx][di]);
                    if (di < N-1) $write(" ");
                end
                $write("]\n");
            end
        end else begin
            raw_a_col <= 0;
            raw_b_row <= 0;
        end
    end

    task print_matrix;
        input [256:0] label;
        reg signed [DATA_WIDTH-1:0] m [0:N-1][0:N-1];
        integer r, c;
        begin
            $display("%s:", label);
            for (r = 0; r < N; r = r + 1) begin
                $write("  ");
                for (c = 0; c < N; c = c + 1) $write("%4d ", m[r][c]);
                $write("\n");
            end
        end
    endtask

    task run_test_det;
        input [1024:0] test_name;
        integer r, c, kk;
        reg signed [DATA_WIDTH-1:0] a_val, b_val;
        begin
            $display("\n==================================================");
            $display(" %s (N=%0d)", test_name, N);
            $display("==================================================");

            for (r = 0; r < N; r = r + 1) begin
                for (c = 0; c < N; c = c + 1) begin
                    a_val = (r * N + c + 1) * 2 - 5;
                    b_val = (c * N + r + 1) * 2 - 5;
                    A[r][c] = a_val;
                    B[r][c] = b_val;
                    C_exp[r][c] = 0;
                end
            end

            for (r = 0; r < N; r = r + 1)
                for (c = 0; c < N; c = c + 1)
                    for (kk = 0; kk < N; kk = kk + 1)
                        C_exp[r][c] = C_exp[r][c] + A[r][kk] * B[kk][c];

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
            $display("Expected C = A*B:");
            for (r = 0; r < N; r = r + 1) begin
                $write("  ");
                for (c = 0; c < N; c = c + 1) $write("%4d ", C_exp[r][c]);
                $write("\n");
            end

            @(posedge clk);
            start = 1;
            wait(done);
            @(negedge clk);

            errors = 0;
            $display("\nResult C (from hardware):");
            for (r = 0; r < N; r = r + 1) begin
                $write("  ");
                for (c = 0; c < N; c = c + 1) begin
                    actual = $signed(result[((r*N+c)*ACCUM_WIDTH)+:ACCUM_WIDTH]);
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

            @(negedge clk); start = 0;
            repeat (5) @(posedge clk);
        end
    endtask

    task run_test_rnd;
        input [1024:0] test_name;
        input integer seed;
        integer r, c, kk;
        reg signed [DATA_WIDTH-1:0] a_val, b_val;
        begin
            $display("\n==================================================");
            $display(" %s (N=%0d, seed=%0d)", test_name, N, seed);
            $display("==================================================");

            for (r = 0; r < N; r = r + 1) begin
                for (c = 0; c < N; c = c + 1) begin
                    a_val = ($random(seed) % 15) - 7;
                    b_val = ($random(seed) % 15) - 7;
                    A[r][c] = a_val;
                    B[r][c] = b_val;
                    C_exp[r][c] = 0;
                end
            end

            for (r = 0; r < N; r = r + 1)
                for (c = 0; c < N; c = c + 1)
                    for (kk = 0; kk < N; kk = kk + 1)
                        C_exp[r][c] = C_exp[r][c] + A[r][kk] * B[kk][c];

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
            $display("Expected C = A*B:");
            for (r = 0; r < N; r = r + 1) begin
                $write("  ");
                for (c = 0; c < N; c = c + 1) $write("%4d ", C_exp[r][c]);
                $write("\n");
            end

            @(posedge clk);
            start = 1;
            wait(done);
            @(negedge clk);

            errors = 0;
            $display("\nResult C (from hardware):");
            for (r = 0; r < N; r = r + 1) begin
                $write("  ");
                for (c = 0; c < N; c = c + 1) begin
                    actual = $signed(result[((r*N+c)*ACCUM_WIDTH)+:ACCUM_WIDTH]);
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

            @(negedge clk); start = 0;
            repeat (5) @(posedge clk);
        end
    endtask

    initial begin
        $dumpfile("tb_system.vcd");
        $dumpvars(0, tb_system);

        clk = 0; rst = 1; start = 0;
        raw_a_col = 0; raw_b_row = 0;
        total_errors = 0;
        #20 rst = 0;
        @(negedge clk);
        @(negedge clk);

        run_test_det("SYSTEM TEST 1: Deterministic Matrix Multiply");
        run_test_rnd("SYSTEM TEST 2: Random Matrix Multiply", 42);
        run_test_rnd("SYSTEM TEST 3: Random Matrix Multiply", 99);

        $display("\n==================================================");
        if (total_errors == 0)
            $display(" ALL %0d SYSTEM TESTS PASSED (N=%0d)", 3, N);
        else
            $display(" %0d SYSTEM TEST(S) FAILED with %0d total errors", 3, total_errors);
        $display("==================================================");
        $finish;
    end

endmodule
