# Instruction Decoding

## Overview

Instruction decoding is performed **inline** inside `dispatch_unit.v` during the `DECODE_W` state (see `dispatch_unit.md` for FSM details). There is no separate decoder module — the dispatch unit registers the raw instruction fields from the IBRAM output bus on the DECODE_W cycle, then uses the decoded fields in subsequent states.

## Field Description

The 32-bit instruction word is partitioned as follows:

| Bits     | Field          | Width | Codename                 |
|----------|----------------|-------|--------------------------|
| [31:28]  | `opcode`       | 4     | `inst_dout[31:28]`       |
| [27:20]  | `wt_tile`      | 8     | MATMUL weight tile       |
| [19:12]  | `act_tile`     | 8     | MATMUL activation tile   |
| [11:4]   | `out_tile`     | 8     | MATMUL output tile       |
| [27:16]  | `dram_addr`    | 12    | LOAD/STORE DRAM address  |
| [15:8]   | `buf_tile`     | 8     | LOAD/STORE buffer tile   |
| [3:0]    | `size`         | 4     | LOAD/STORE transfer size |
| [27:16]  | `loop_count`   | 12    | LOOP iteration count     |
| [15:8]   | `loop_target`  | 8     | LOOP target address      |
| [7:0]    | `loop_stride`  | 8     | LOOP stride (reserved)   |
| [27:16]  | `jump_target`  | 12    | JUMP target address      |

## Inline Sampling (DECODE_W cycle)

In the `DECODE_W` sequential block (at posedge):

```verilog
opcode         <= inst_dout[31:28];
wt_tile        <= inst_dout[27:20];
act_tile       <= inst_dout[19:12];
out_tile       <= inst_dout[11:4];
ls_dram_addr   <= inst_dout[27:16];
ls_buf_tile    <= inst_dout[15:8];
ls_size        <= inst_dout[3:0];
loop_count_field <= inst_dout[27:16];
loop_target_field <= inst_dout[15:8];
loop_stride_field <= inst_dout[7:0];
jump_target_field <= inst_dout[27:16];
```

These registered values are then available to the CHECK, DISPATCH, WAIT_EXEC, and RELEASE states.

## Derived Signals

The `dispatch_unit` derives opcode-based decisions via `case (opcode)`:

| Opcode     | CHECK behavior          | DISPATCH behavior              | RELEASE behavior                    |
|------------|-------------------------|--------------------------------|-------------------------------------|
| MATMUL     | Lock 3 tiles            | Assert `sys_start`             | Release `{wt,act,out}_tile`         |
| LOAD/STORE | Lock 1 tile (`ls_buf`)  | No `sys_start` (exec proxy)    | Release `ls_buf_tile` only          |
| LOOP       | Skip dep check          | Init/decrement `loop_remaining` | (none — branch handled in DISPATCH) |
| JUMP       | Skip dep check          | Set `pc_loop_target`            | (none)                              |
| BARRIER/NOP| Skip dep check          | Immediate FETCH transition     | (none)                              |

## Integration

Not a standalone module. The decoding logic is embedded within `dispatch_unit.v`, lines 170–184. The `instruction_defines.vh` file provides the opcode constants and field shift macros used for decoding.

## Opcode Constants (`instruction_defines.vh`)

```verilog
`define OP_MATMUL  4'h0
`define OP_LOAD    4'h1
`define OP_STORE   4'h2
`define OP_LOOP    4'h3
`define OP_JUMP    4'h4
`define OP_BARRIER 4'hE
`define OP_NOP     4'hF
```
