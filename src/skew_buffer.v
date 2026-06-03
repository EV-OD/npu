module skew_buffer #(
    parameter N = 4,
    parameter DATA_WIDTH = 16,
    parameter DELAY_PER_STEP = 2 // Calculates cycles needed per row to skew data
)(
    input  wire                         clk,
    input  wire                         rst,
    input  wire [(N * DATA_WIDTH)-1:0]  din,
    output wire [(N * DATA_WIDTH)-1:0]  dout
);

    genvar i;
    generate
        for (i = 0; i < N; i = i + 1) begin : skew_logic
            if (i == 0) begin : delay_0
                // Row 0 has NO skew, passes straight through
                assign dout[(i * DATA_WIDTH) +: DATA_WIDTH] = din[(i * DATA_WIDTH) +: DATA_WIDTH];
            end else begin : delay_i
                // Row i must be delayed by i * DELAY_PER_STEP cycles
                localparam CURRENT_DELAY = i * DELAY_PER_STEP;
                
                reg [DATA_WIDTH-1:0] shift_reg [0:CURRENT_DELAY-1];
                integer k;
                
                always @(posedge clk) begin
                    if (rst) begin
                        for (k = 0; k < CURRENT_DELAY; k = k + 1) begin
                            shift_reg[k] <= {DATA_WIDTH{1'b0}};
                        end
                    end else begin
                        shift_reg[0] <= din[(i * DATA_WIDTH) +: DATA_WIDTH];
                        for (k = 1; k < CURRENT_DELAY; k = k + 1) begin
                            shift_reg[k] <= shift_reg[k-1];
                        end
                    end
                end
                
                assign dout[(i * DATA_WIDTH) +: DATA_WIDTH] = shift_reg[CURRENT_DELAY-1];
            end
        end
    endgenerate

endmodule
