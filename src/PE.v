module PE #(
    parameter DATA_WIDTH = 16,
    parameter ACCUM_WIDTH = 40 // 256 consecutive multiplications possible without overflow for 16-bit signed inputs
)(
    input  wire                     clk,
    input  wire                     rst,
    input  wire signed [DATA_WIDTH-1:0]  in_x, 
    input  wire signed [DATA_WIDTH-1:0]  in_y,  
    output reg  signed [DATA_WIDTH-1:0]  out_x,  // Registered activation to neighbor
    output reg  signed [DATA_WIDTH-1:0]  out_y,  // Registered weight to neighbor
    output reg  signed [ACCUM_WIDTH-1:0] out_c   // Internal Accumulator output
);

    // Force the synthesis tool to wrap this specific register inside a hardware DSP slice
    (* use_dsp = "yes" *) reg signed [ACCUM_WIDTH-1:0] accumulator;

    // Internal pipeline registers to match DSP physical layout
    reg signed [DATA_WIDTH-1:0] x_reg;
    reg signed [DATA_WIDTH-1:0] y_reg;
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
            // Pipeline Stage 1: Latch inputs into local registers
            x_reg <= in_x;
            y_reg <= in_y;

            // Pipeline Stage 2: Multiply latched values
            product_reg <= x_reg * y_reg;

            // Pipeline Stage 3: Accumulate the product in the DSP core
            accumulator <= accumulator + product_reg;

            // Delay outputs by one cycle to safely cross to the next PE boundary
            out_x <= x_reg;
            out_y <= y_reg;
            out_c <= accumulator;
        end
    end

endmodule