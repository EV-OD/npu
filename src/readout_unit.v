module readout_unit #(
    parameter N = 4,
    parameter ACCUM_WIDTH = 40
)(
    input  wire                                clk,
    input  wire                                rst,
    input  wire                                trigger,
    input  wire                                shift_mode,

    input  wire [(N * N * ACCUM_WIDTH)-1:0]    pe_c,

    output reg                                 valid,
    output reg  [(N * N * ACCUM_WIDTH)-1:0]    result,

    output reg                                 shift_valid,
    output reg  [ACCUM_WIDTH-1:0]              shift_out,
    output reg                                 shift_done
);

    reg [31:0] shift_idx;
    reg shifting;

    always @(posedge clk) begin
        if (rst) begin
            valid       <= 0;
            result      <= 0;
            shift_idx   <= 0;
            shifting    <= 0;
            shift_valid <= 0;
            shift_out   <= 0;
            shift_done  <= 0;
        end else if (trigger) begin
            result      <= pe_c;
            valid       <= 1;
            shift_idx   <= 0;
            shift_done  <= 0;
            shifting    <= shift_mode;
            if (shift_mode) begin
                shift_out   <= pe_c[(0 * ACCUM_WIDTH) +: ACCUM_WIDTH];
                shift_valid <= 1;
            end else begin
                shift_valid <= 0;
                shift_out   <= 0;
            end
        end else if (shifting) begin
            if (shift_idx == N * N - 1) begin
                shifting    <= 0;
                shift_valid <= 0;
                shift_done  <= 1;
            end else begin
                shift_idx   <= shift_idx + 1;
                shift_out   <= result[((shift_idx + 1) * ACCUM_WIDTH) +: ACCUM_WIDTH];
                shift_valid <= 1;
            end
        end else begin
            shift_valid <= 0;
        end
    end

endmodule
