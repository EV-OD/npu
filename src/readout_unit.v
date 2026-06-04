module readout_unit #(
    parameter N = 4,
    parameter ACCUM_WIDTH = 40
)(
    input  wire                               clk,
    input  wire                               rst,
    input  wire                               shift_valid,
    input  wire [(N * ACCUM_WIDTH)-1:0]       row_in,
    output reg                                valid,
    output reg  [(N * N * ACCUM_WIDTH)-1:0]   result
);

    reg [$clog2(N+1)-1:0] row_idx;
    reg [(N*ACCUM_WIDTH)-1:0] rows [0:N-1];
    integer i;

    always @(posedge clk) begin
        if (rst) begin
            valid <= 0;
            row_idx <= 0;
            result <= 0;
        end else if (shift_valid) begin
            rows[row_idx] <= row_in;
            if (row_idx == N-1) begin
                valid <= 1;
                row_idx <= 0;
                for (i = 0; i < N; i = i + 1)
                    if (i == N-1)
                        result[(i * N * ACCUM_WIDTH) +: (N * ACCUM_WIDTH)] <= row_in;
                    else
                        result[(i * N * ACCUM_WIDTH) +: (N * ACCUM_WIDTH)] <= rows[i];
            end else begin
                if (row_idx == 0) valid <= 0;
                row_idx <= row_idx + 1;
            end
        end
    end

endmodule
