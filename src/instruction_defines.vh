// Instruction format: 32-bit fixed size
// [31:28] = opcode (4 bits)
// [27:0]  = operands (opcode-dependent)

`ifndef INSTRUCTION_DEFINES_VH
`define INSTRUCTION_DEFINES_VH

`define OPCODE_WIDTH 4
`define INST_WIDTH   32

// Opcodes
`define OP_MATMUL   4'h0
`define OP_LOAD     4'h1
`define OP_STORE    4'h2
`define OP_LOOP     4'h3
`define OP_JUMP     4'h4
`define OP_BARRIER  4'hE
`define OP_NOP      4'hF

// Field positions for MATMUL: [31:28]=op, [27:20]=wt_tile, [19:12]=act_tile, [11:4]=out_tile, [3:0]=rsvd
`define MATMUL_WT_SHIFT   20
`define MATMUL_ACT_SHIFT  12
`define MATMUL_OUT_SHIFT  4
`define MATMUL_TILE_WIDTH 8

// Field positions for LOAD/STORE: [31:28]=op, [27:16]=dram_addr, [15:8]=buf_tile, [7:4]=rsvd, [3:0]=size
`define LST_DRAM_SHIFT   16
`define LST_TILE_SHIFT   8
`define LST_SIZE_SHIFT   0
`define LST_DRAM_WIDTH   12
`define LST_TILE_WIDTH   8
`define LST_SIZE_WIDTH   4

// Field positions for LOOP: [31:28]=op, [27:16]=count, [15:8]=target, [7:0]=stride
`define LOOP_CNT_SHIFT   16
`define LOOP_TGT_SHIFT   8
`define LOOP_STR_SHIFT   0
`define LOOP_CNT_WIDTH   12
`define LOOP_TGT_WIDTH   8
`define LOOP_STR_WIDTH   8

// Field positions for JUMP: [31:28]=op, [27:16]=target, [11:0]=rsvd
`define JUMP_TGT_SHIFT   16
`define JUMP_TGT_WIDTH   12

`endif
