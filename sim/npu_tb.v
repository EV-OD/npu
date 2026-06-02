`timescale 1ns/1ps

module npu_tb;
    reg clk;
    reg rst;
    reg [7:0] weight;
    reg [7:0] activation;
    wire [15:0] accumulator;

    // Instantiate the Processing Element
    processing_element uut (
        .clk(clk),
        .rst(rst),
        .weight(weight),
        .activation(activation),
        .accumulator(accumulator)
    );

    // Clock generation (50MHz)
    always #10 clk = ~clk;

    initial begin
        // Setup waveform dumping for WaveTrace/GTKWave
        $dumpfile("sim_output.vcd");
        $dumpvars(0, npu_tb);

        // Initialize signals
        clk = 0;
        rst = 1;
        weight = 0;
        activation = 0;

        #20 rst = 0; // Release reset

        // Cycle 1: 2 * 3 = 6
        weight = 8'd2; activation = 8'd3;
        #20;

        // Cycle 2: 6 + (4 * 5) = 26
        weight = 8'd4; activation = 8'd5;
        #20;

        $finish;
    end
endmodule