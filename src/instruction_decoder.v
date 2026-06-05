`include "instruction_defines.vh"

module instruction_decoder #(
    parameter DATA_WIDTH = `INST_WIDTH
)(
    input  wire [DATA_WIDTH-1:0]    instruction,
    output reg  [3:0]               opcode,
    // MATMUL fields
    output reg  [7:0]               matmul_wt_tile,
    output reg  [7:0]               matmul_act_tile,
    output reg  [7:0]               matmul_out_tile,
    // LOAD/STORE fields
    output reg  [11:0]              ls_dram_addr,
    output reg  [7:0]               ls_buf_tile,
    output reg  [3:0]               ls_size,
    // LOOP fields
    output reg  [11:0]              loop_count,
    output reg  [7:0]               loop_target,
    output reg  [7:0]               loop_stride,
    // JUMP field
    output reg  [11:0]              jump_target
);

    always @(*) begin
        opcode         = instruction[31:28];
        matmul_wt_tile = instruction[27:20];
        matmul_act_tile= instruction[19:12];
        matmul_out_tile= instruction[11:4];
        ls_dram_addr   = instruction[27:16];
        ls_buf_tile    = instruction[15:8];
        ls_size        = instruction[3:0];
        loop_count     = instruction[27:16];
        loop_target    = instruction[15:8];
        loop_stride    = instruction[7:0];
        jump_target    = instruction[27:16];
    end

endmodule
