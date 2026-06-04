module readout_shifter #(
    parameter N = 4,
    parameter ACCUM_WIDTH = 40
)(
    input  wire                               clk,
    input  wire                               rst,
    input  wire                               load,
    input  wire [(N*N*ACCUM_WIDTH)-1:0]       pe_c,
    output wire [(N*ACCUM_WIDTH)-1:0]         row_out,
    output wire                               row_valid,
    output reg                                shift_done
);

    reg [(N*ACCUM_WIDTH)-1:0] rows [0:N-1];
    reg [$clog2(N+1)-1:0] idx;
    integer i;

    assign row_out   = (idx < N) ? rows[idx] : 0;
    assign row_valid = (idx < N);

    always @(posedge clk) begin
        if (rst) begin
            idx <= N;
            shift_done <= 0;
        end else if (load) begin
            for (i = 0; i < N; i = i + 1)
                rows[i] <= pe_c[(i * N * ACCUM_WIDTH) +: (N * ACCUM_WIDTH)];
            shift_done <= 0;
            idx <= 0;
        end else if (idx < N) begin
            if (idx == N-1)
                shift_done <= 1;
            idx <= idx + 1;
        end else begin
            shift_done <= 0;
        end
    end

endmodule
