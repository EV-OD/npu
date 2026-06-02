module processing_element (
    input clk,
    input rst,
    input [7:0] weight,
    input [7:0] activation,
    output reg [15:0] accumulator
);

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            accumulator <= 16'd0;
        end else begin
            accumulator <= accumulator + (weight * activation);
        end
    end

endmodule