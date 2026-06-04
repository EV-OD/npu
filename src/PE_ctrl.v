module PE_ctrl #(
    parameter DATA_WIDTH = 16,
    parameter ACCUM_WIDTH = 40
)(
    input  wire                            clk,
    input  wire                            rst,
    input  wire                            acc_clr,
    input  wire                            acc_en,
    input  wire signed [DATA_WIDTH-1:0]    in_x,
    input  wire signed [DATA_WIDTH-1:0]    in_y,
    input  wire signed [ACCUM_WIDTH-1:0]   psum_in,
    output reg  signed [DATA_WIDTH-1:0]    out_x,
    output reg  signed [DATA_WIDTH-1:0]    out_y,
    output reg  signed [ACCUM_WIDTH-1:0]   out_c
);

    reg signed [ACCUM_WIDTH-1:0] accumulator;
    reg signed [DATA_WIDTH-1:0]  x_reg;
    reg signed [DATA_WIDTH-1:0]  y_reg;
    reg signed [(2*DATA_WIDTH)-1:0] product_reg;

    always @(posedge clk) begin
        if (rst) begin
            x_reg       <= 0;
            y_reg       <= 0;
            product_reg <= 0;
            accumulator <= 0;
            out_x       <= 0;
            out_y       <= 0;
            out_c       <= 0;
        end else begin
            x_reg <= in_x;
            y_reg <= in_y;
            product_reg <= x_reg * y_reg;

            if (acc_clr) begin
                accumulator <= 0;
            end else if (acc_en) begin
                accumulator <= accumulator + product_reg;
            end

            out_x <= x_reg;
            out_y <= y_reg;
            out_c <= accumulator + psum_in;
        end
    end

endmodule
