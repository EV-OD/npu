module readout_unit #(
    parameter N = 4,
    parameter ACCUM_WIDTH = 40
)(
    input  wire                                clk,
    input  wire                                rst,
    input  wire                                trigger,

    // PE accumulator values from systolic array
    input  wire [(N * N * ACCUM_WIDTH)-1:0]    pe_c,

    // Result interface
    output reg                                 valid,
    output reg  [(N * N * ACCUM_WIDTH)-1:0]    result
);

    always @(posedge clk) begin
        if (rst) begin
            valid  <= 0;
            result <= 0;
        end else if (trigger) begin
            result <= pe_c;
            valid  <= 1;
        end else if (valid) begin
            // Hold result until next trigger or reset
        end
    end

endmodule
