`timescale 1ns / 1ps
`include "../src/instruction_defines.vh"

// ── Full-system cosimulation testbench ──────────────────────────
// Loads A/B matrix data, runs MATMUL via actual RTL, outputs result
// ────────────────────────────────────────────────────────────────

module tb_cosim;

    parameter N = 4;
    parameter DATA_WIDTH = 16;
    parameter ACCUM_WIDTH = 40;

    reg clk, rst;
    reg start;
    wire busy, done;
    wire result_valid;
    wire [(N*N*ACCUM_WIDTH)-1:0] result_data;

    // Feed buffer write
    reg a_we, b_we;
    reg [$clog2(2*N*N)-1:0] a_waddr, b_waddr;
    reg signed [DATA_WIDTH-1:0] a_din, b_din;

    npu_exec_unit #(
        .N(N), .DATA_WIDTH(DATA_WIDTH), .ACCUM_WIDTH(ACCUM_WIDTH)
    ) u_exec (
        .clk(clk), .rst(rst),
        .start(start), .matrix_size(N),
        .busy(busy), .done(done),
        .a_we(a_we), .a_waddr(a_waddr), .a_din(a_din),
        .b_we(b_we), .b_waddr(b_waddr), .b_din(b_din),
        .result_valid(result_valid), .result_data(result_data)
    );

    always #5 clk = ~clk;

    integer i, j, file_id;
    reg signed [DATA_WIDTH-1:0] A [0:N-1][0:N-1];
    reg signed [DATA_WIDTH-1:0] B [0:N-1][0:N-1];
    reg signed [ACCUM_WIDTH-1:0] C_flat [0:N*N-1];

    task load_matrix;
        input string name;
        input string hexfile;
        // Not used — we load via $readmemh at init
    endtask

    initial begin
        $dumpfile("tb_cosim.vcd");
        $dumpvars(0, tb_cosim);

        clk = 0; rst = 1;
        start = 0;
        a_we = 0; b_we = 0;

        // Read A and B from hex files
        $readmemh("tb_cosim_A.hex", A);
        $readmemh("tb_cosim_B.hex", B);

        repeat (2) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // Preload feed buffer A (column-major: store A col by col)
        // feed_buffer addr layout: pong_base + j*N + row
        // For k=0..N-1, column k: A[0][k], A[1][k], ..., A[N-1][k]
        // Stored at address k + j*N for j=0..N-1
        for (i = 0; i < N; i = i + 1) begin
            for (j = 0; j < N; j = j + 1) begin
                @(negedge clk);
                a_we <= 1;
                a_waddr <= i + j * N;  // column i, row j
                a_din <= A[i][j];       // A[i][j] where i=row idx, j=col idx
            end
        end

        // Preload feed buffer B (row-major: store B row by row)
        for (i = 0; i < N; i = i + 1) begin
            for (j = 0; j < N; j = j + 1) begin
                @(negedge clk);
                b_we <= 1;
                b_waddr <= i * N + j;  // row i, column j
                b_din <= B[i][j];
            end
        end

        @(negedge clk);
        a_we <= 0; b_we <= 0;

        // Start execution
        @(posedge clk);
        start <= 1;
        @(posedge clk);
        start <= 0;

        // Wait for done
        wait(done);
        @(posedge clk);

        // Read result
        $display("RESULT_MATRIX");
        for (i = 0; i < N; i = i + 1) begin
            for (j = 0; j < N; j = j + 1) begin
                $display("C[%0d][%0d] = %0d", i, j,
                    $signed(result_data[((i * N + j) * ACCUM_WIDTH) +: ACCUM_WIDTH]));
            end
        end
        $display("END_RESULT");
        $display("COSIM_DONE");

        #100 $finish;
    end

endmodule
