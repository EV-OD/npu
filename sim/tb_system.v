`timescale 1ns / 1ps

// =============================================================
// Full NPU Core
// =============================================================
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

    readout_unit #(.N(N), .ACCUM_WIDTH(ACCUM_WIDTH)) rdout (
        .clk(clk), .rst(rst),
        .trigger(readout_trig),
        .pe_c(pe_c),
        .valid(result_valid),
        .result(result)
    );

endmodule


// =============================================================
// System Testbench
// =============================================================
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

    integer i, j, k, errors;
    integer di;
    reg trigger_driven;

    // Drive data based on seq_data_valid from the npu_core's sequencer
    // Registered version to align with skew buffer timing
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
                $display("  FEED[%0d] @ %0t: A_col=[%0d %0d %0d] B_row=[%0d %0d %0d]",
                         feed_idx, $time,
                         A[0][feed_idx], A[1][feed_idx], A[2][feed_idx],
                         B[feed_idx][0], B[feed_idx][1], B[feed_idx][2]);
            end
        end else begin
            raw_a_col <= 0;
            raw_b_row <= 0;
        end
    end

    initial begin
        $dumpfile("tb_system.vcd");
        $dumpvars(0, tb_system);

        clk = 0; rst = 1; start = 0;
        raw_a_col = 0; raw_b_row = 0;
        #20 rst = 0;
        @(negedge clk);
        @(negedge clk);

        // -------------------------------------------------------
        // TEST 1: Fixed matrix
        // -------------------------------------------------------
        $display("==================================================");
        $display(" TEST 1: N=%0d Fixed Matrix Multiply", N);
        $display("==================================================");

        A[0][0] =  4; A[0][1] = -3; A[0][2] =  3;
        A[1][0] =  0; A[1][1] =  2; A[1][2] =  4;
        A[2][0] =  5; A[2][1] =  5; A[2][2] = -3;

        B[0][0] = -3; B[0][1] = -3; B[0][2] =  3;
        B[1][0] = -3; B[1][1] =  5; B[1][2] =  3;
        B[2][0] =  3; B[2][1] =  1; B[2][2] = -3;

        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1)
                C_exp[i][j] = 0;

        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1)
                for (k = 0; k < N; k = k + 1)
                    C_exp[i][j] = C_exp[i][j] + A[i][k] * B[k][j];

        $display("Matrix A:");
        for (i = 0; i < N; i = i + 1) begin
            $write("  ");
            for (j = 0; j < N; j = j + 1) $write("%4d ", A[i][j]);
            $write("\n");
        end
        $display("\nMatrix B:");
        for (i = 0; i < N; i = i + 1) begin
            $write("  ");
            for (j = 0; j < N; j = j + 1) $write("%4d ", B[i][j]);
            $write("\n");
        end

        // Debug expected values
        $display("\nExpected C = A*B:");
        for (i = 0; i < N; i = i + 1) begin
            $write("  ");
            for (j = 0; j < N; j = j + 1) $write("%4d ", C_exp[i][j]);
            $write("\n");
        end

        @(posedge clk);
        start = 1;
        wait(done);
        @(negedge clk);

        errors = 0;
        $display("\nReadout valid: %b", result_valid);
        $display("\nMatrix C (result vs expected):");
        for (i = 0; i < N; i = i + 1) begin
            $write("  ");
            for (j = 0; j < N; j = j + 1) begin
                actual = $signed(result[((i*N+j)*ACCUM_WIDTH)+:ACCUM_WIDTH]);
                if (actual == C_exp[i][j])
                    $write("%4d ", actual);
                else begin
                    $write("%4d*", actual);
                    errors = errors + 1;
                end
            end
            $write("\n");
        end
        $display("\nExpected:");
        for (i = 0; i < N; i = i + 1) begin
            $write("  ");
            for (j = 0; j < N; j = j + 1) $write("%4d ", C_exp[i][j]);
            $write("\n");
        end
        if (errors == 0) $display("*** TEST 1 PASSED ***");
        else             $display("*** TEST 1 FAILED with %0d errors ***", errors);

        // -------------------------------------------------------
        // TEST 2: Random
        // -------------------------------------------------------
        #100;
        @(negedge clk); start = 0;
        repeat (5) @(posedge clk);
        @(negedge clk);

        errors = 0;

        $display("\n==================================================");
        $display(" TEST 2: N=%0d Random Matrix Multiply", N);
        $display("==================================================");

        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1) begin
                A[i][j] = ($random % 7) + 1;
                B[i][j] = ($random % 7) + 1;
                C_exp[i][j] = 0;
            end

        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1)
                for (k = 0; k < N; k = k + 1)
                    C_exp[i][j] = C_exp[i][j] + A[i][k] * B[k][j];

        $display("Matrix A:");
        for (i = 0; i < N; i = i + 1) begin
            $write("  ");
            for (j = 0; j < N; j = j + 1) $write("%4d ", A[i][j]);
            $write("\n");
        end
        $display("\nMatrix B:");
        for (i = 0; i < N; i = i + 1) begin
            $write("  ");
            for (j = 0; j < N; j = j + 1) $write("%4d ", B[i][j]);
            $write("\n");
        end

        @(posedge clk);
        start = 1;
        wait(done);
        @(negedge clk);

        $display("\nMatrix C (Actual vs Expected):");
        for (i = 0; i < N; i = i + 1) begin
            $write("  ");
            for (j = 0; j < N; j = j + 1) begin
                actual = $signed(result[((i*N+j)*ACCUM_WIDTH)+:ACCUM_WIDTH]);
                $write("%4d ", actual);
                if (actual !== C_exp[i][j]) begin
                    $display(" [ERROR at [%0d][%0d]: exp=%0d got=%0d]", i, j, C_exp[i][j], actual);
                    errors = errors + 1;
                end
            end
            $write("\n");
        end

        if (errors == 0) $display("*** TEST 2 PASSED ***");
        else             $display("*** TEST 2 FAILED with %0d errors ***", errors);

        $display("\n==================================================");
        if (errors == 0) $display(" ALL SYSTEM TESTS PASSED ");
        else             $display(" SYSTEM TESTS FAILED with %0d errors", errors);
        $display("==================================================");
        $finish;
    end

endmodule
