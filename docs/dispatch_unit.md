# Dispatch Unit

## Overview

The dispatch unit (`dispatch_unit.v`) is an 8-state FSM that controls the entire instruction pipeline: fetches instructions from the IBRAM, decodes them inline (registering all fields at the DECODE_W posedge), checks tile dependencies, dispatches to the execution unit, waits for execution to complete (`sys_done`), and releases tile locks. It also handles loop counting and jump branching internally with no separate decoder module.

**Key architectural notes:**
- No separate instruction decoder — field extraction is inline in the DECODE_W sequential block.
- The WAIT_EXEC state polls `sys_done` (not `sys_busy` or `exec_active`).
- LOOP and JUMP transitions are handled at DISPATCH time via nxt logic, not at FETCH/LOOP_JUMP time.
- RELEASE transitions directly to FETCH (LOOP re-evaluation happens via the DISPATCH nxt logic when the LOOP instruction is encountered again).

## Parameters

| Parameter    | Default | Description                              |
|--------------|---------|------------------------------------------|
| `N`          | 4       | Matrix dimension (passed to sys_* outputs) |
| `SLOT_DEPTH` | 64      | Words per IBRAM slot                     |

## Ports

| Port                  | Width | Direction | Description                                  |
|-----------------------|-------|-----------|----------------------------------------------|
| `clk`                 | 1     | I         | Clock                                        |
| `rst`                 | 1     | I         | Synchronous reset                            |
| `pc_addr_in`          | A*    | I         | Unused (tied to 0)                           |
| `pc_addr`             | A*    | O         | PC address to IBRAM                          |
| `inst_dout`           | 32    | I         | Instruction word from IBRAM                  |
| `pc_en`               | 1     | O         | IBRAM read enable (1 when state==FETCH)      |
| `dep_check_en`        | 1     | O         | Pulse: check tile availability               |
| `dep_tile_a/b/c`      | 8     | O         | Tile numbers to check                        |
| `dep_num_tiles`       | 2     | O         | Number of tiles for check (1 or 3)           |
| `dep_grant`           | 1     | I         | All checked tiles are unlocked & now locked  |
| `dep_conflict`        | 8     | I         | Conflict bitmask (unused by dispatch)        |
| `dep_release_en`      | 1     | O         | Pulse: release tiles                         |
| `dep_release_a/b/c`   | 8     | O         | Tile numbers to release                      |
| `dep_release_num`     | 2     | O         | Number of tiles to release                   |
| `sys_start`           | 1     | O         | Pulse: start execution unit (MATMUL only)    |
| `sys_matrix_size`     | 32    | O         | Matrix dimension (constant `N`)              |
| `sys_act_base`        | 32    | O         | Activation tile to execution unit            |
| `sys_wgt_base`        | 32    | O         | Weight tile to execution unit                |
| `sys_out_base`        | 32    | O         | Output tile to execution unit                |
| `sys_busy`            | 1     | I         | Execution unit busy status (unused by FSM)   |
| `sys_done`            | 1     | I         | Execution unit done (triggers WAIT→RELEASE)  |
| `pc_loop_jump`        | 1     | O         | Pulse: IBRAM should jump                     |
| `pc_loop_target`      | A*    | O         | Jump target address (truncated to slot)      |
| `swap_req`            | 1     | O         | IBRAM slot swap request                      |
| `ibram_ready`         | 1     | I         | IBRAM active slot is full                    |
| `busy`                | 1     | O         | Pipeline active (not IDLE)                   |
| `state_debug`         | 4     | O         | Current FSM state for debug                  |
| `opcode_debug`        | 4     | O         | Current opcode for debug                     |
| `loop_remaining_debug`| 12    | O         | Loop remaining count (for debug)             |

\* A = `$clog2(SLOT_DEPTH)` (default: 6 bits for SLOT_DEPTH=64).

## FSM States

| State       | Encoding | Description                                        |
|-------------|----------|----------------------------------------------------|
| `IDLE`      | 0        | Reset or waiting for IBRAM ready                   |
| `FETCH`     | 1        | Assert pc_en, set pc_addr (comb.)                  |
| `DECODE_W`  | 2        | Sample instruction word, decode fields             |
| `CHECK`     | 3        | Assert dep_check_en for MATMUL/LOAD/STORE          |
| `DISPATCH`  | 4        | Assert sys_start (MATMUL) or init loop/branch      |
| `WAIT_EXEC` | 5        | Poll sys_done, stall until execution completes     |
| `RELEASE`   | 6        | Assert dep_release_en, release tiles               |
| `LOOP_JUMP` | 7        | Set IBRAM PC to loop/jump target                   |

## State Transition Table (combinatorial nxt)

| Current State | Condition                              | Next State   |
|---------------|----------------------------------------|--------------|
| IDLE          | `ibram_ready`                          | FETCH        |
| IDLE          | `!ibram_ready`                         | IDLE         |
| FETCH         | always                                 | DECODE_W     |
| DECODE_W      | always                                 | CHECK        |
| CHECK         | opcode is NOP/BARRIER/LOOP/JUMP        | DISPATCH     |
| CHECK         | `dep_grant` (MATMUL/LOAD/STORE)       | DISPATCH     |
| CHECK         | `!dep_grant` (MATMUL/LOAD/STORE)      | CHECK (stall)|
| DISPATCH      | opcode is NOP/BARRIER                  | FETCH        |
| DISPATCH      | LOOP, `in_loop && remaining>0`         | LOOP_JUMP    |
| DISPATCH      | LOOP, `!in_loop && count>0`            | LOOP_JUMP    |
| DISPATCH      | LOOP, otherwise (fall through)         | FETCH        |
| DISPATCH      | JUMP                                   | LOOP_JUMP    |
| DISPATCH      | MATMUL/LOAD/STORE                     | WAIT_EXEC    |
| WAIT_EXEC     | `sys_done`                             | RELEASE      |
| WAIT_EXEC     | `!sys_done`                            | WAIT_EXEC    |
| RELEASE       | always                                 | FETCH        |
| LOOP_JUMP     | always                                 | FETCH        |

## Per-State Sequential Actions

### IDLE
- `busy <= 0`, `state_debug <= IDLE`
- PC remains at 0

### FETCH
- `busy <= 1`, `state_debug <= FETCH`
- PC increments: `pc <= pc + 1` (registered PC update)
- Combinatorial: `pc_en = 1`, `pc_addr = pc`
- Swap request: if `pc == SLOT_DEPTH-1`, `swap_req <= 1`

### DECODE_W
- `state_debug <= DECODE_W`
- Register all decoded fields from `inst_dout`:
  - `opcode <= inst_dout[31:28]`
  - `wt_tile/act_tile/out_tile <= inst_dout[27:4]`
  - `ls_dram_addr/ls_buf_tile/ls_size <= inst_dout[27:0]`
  - `loop_count_field/target_field/stride_field <= inst_dout[27:0]`
  - `jump_target_field <= inst_dout[27:16]`

### CHECK
- `state_debug <= CHECK`
- **MATMUL**: `dep_check_en <= 1`, `dep_tile_a/b/c = wt/act/out`, `dep_num_tiles <= 3`
- **LOAD/STORE**: `dep_check_en <= 1`, `dep_tile_a = ls_buf_tile`, `dep_num_tiles <= 1`
- **NOP/BARRIER/LOOP/JUMP**: no dep check asserted

### DISPATCH
- `state_debug <= DISPATCH`
- **MATMUL**: `sys_start <= 1`, `sys_wgt/act/out_base <= tile values`, `sys_matrix_size <= N`
- **LOAD/STORE**: no action (exec unit proxy handles its own signaling)
- **LOOP (first time, !in_loop, count>0)**: `loop_remaining <= count-1`, `loop_body_target <= loop_target_field`, `in_loop <= 1`, `pc_loop_target <= truncated target`
- **LOOP (subsequent, in_loop, remaining>0)**: `loop_remaining <= remaining-1`, `pc_loop_target <= loop_body_target`
- **LOOP (fall through)**: `in_loop <= 0`
- **JUMP**: `pc_loop_target <= jump_target_field[$clog2(SLOT_DEPTH)-1:0]`

### WAIT_EXEC
- `state_debug <= WAIT_EXEC`
- No registered actions; nxt polls `sys_done`
- Stays in WAIT_EXEC until `sys_done` is asserted

### RELEASE
- `state_debug <= RELEASE`
- If `num_tiles > 0`: `dep_release_en <= 1`
  - **MATMUL**: `dep_release_a/b/c = wt_tile/act_tile/out_tile`, `dep_release_num = 3`
  - **LOAD/STORE**: `dep_release_a = ls_buf_tile`, `b/c = 0`, `dep_release_num = 1`

### LOOP_JUMP
- `state_debug <= LOOP_JUMP`
- `pc_loop_jump <= 1` (pulse to IBRAM)

## Loop Counter Detail

The loop counter lives in the registered PC logic block:

```verilog
always @(posedge clk) begin
    if (rst) begin
        pc <= 0;
        loop_remaining <= 0;
        loop_body_target <= 0;
        in_loop <= 0;
    end else begin
        case (state)
            IDLE: begin
                pc <= 0;
                in_loop <= 0;
            end
            FETCH: begin
                pc <= pc + 1;
            end
            LOOP_JUMP: begin
                pc <= pc_loop_target;
            end
        endcase
    end
end
```

The loop init/decrement happens in the DISPATCH sequential actions, not in the PC register block.

### Example: `LOOP count=3`

| Encounter | `in_loop` | `loop_remaining` (before) | Action at DISPATCH                   | `pc_loop_target`         |
|-----------|-----------|---------------------------|--------------------------------------|--------------------------|
| 1st       | 0         | 0                         | `remaining = count-1 = 2`, `in=1`    | `loop_target`            |
| 2nd       | 1         | 2                         | `remaining = 2-1 = 1`                | `loop_body_target`       |
| 3rd       | 1         | 1                         | `remaining = 1-1 = 0`                | `loop_body_target`       |
| 4th       | 1         | 0                         | `in_loop = 0`                        | (fall through, PC+=1)    |

The nxt at DISPATCH checks `loop_remaining` vs 0 BEFORE the NBA decrement. When `remaining==0`, nxt selects `FETCH` and `in_loop <= 0`.

## WAIT_EXEC Handshake

The dispatch unit drives `sys_start` as a 1-cycle pulse at DISPATCH (MATMUL only). It then waits in WAIT_EXEC until the execution unit asserts `sys_done`. There is no timeout — the FSM stalls indefinitely.

For LOAD/STORE, `sys_start` is NOT asserted. The `sys_done` input must be driven externally (e.g., by mock logic that detects WAIT_EXEC entry and asserts `sys_done` after a fixed latency).

## Combinatorial Assignments

```verilog
assign pc_en   = (state == FETCH);
assign pc_addr = (state == FETCH) ? pc : {$clog2(SLOT_DEPTH){1'b0}};
```

`pc_en` is asserted only during FETCH. `pc_addr` equals `pc` during FETCH, else 0 (IBRAM ignores it when `pc_en=0`).

## Swap Logic

```verilog
if (pc == SLOT_DEPTH-1 && state == FETCH)
    swap_req <= 1;
```

When the PC reaches the last address of a slot during FETCH, a 1-cycle swap request is sent to the IBRAM.

## NBA Timing Notes

### dep_check_en pulse
- Asserted at CHECK posedge
- Cleared at next posedge (all non-pulse signals reset in the `else` block)
- Dependency checker needs 1 cycle to commit the lock

### dep_release_en pulse  
- Asserted at RELEASE posedge
- Cleared at next posedge
- Dependency checker sees unlock at the following posedge (2 cycles from RELEASE)

### sys_start pulse
- Asserted at DISPATCH posedge
- Cleared at next posedge

### pc_loop_jump pulse
- Asserted at LOOP_JUMP posedge
- Cleared at next posedge
- IBRAM loads new PC on the same posedge

## Register Map

| Register            | Width | Description                              |
|---------------------|-------|------------------------------------------|
| `state`             | 4     | Current FSM state                        |
| `nxt`               | 4     | Next state (combinatorial)               |
| `pc`                | A*    | Program counter                          |
| `opcode`            | 4     | Registered opcode                        |
| `wt_tile`           | 8     | Registered weight tile                   |
| `act_tile`          | 8     | Registered activation tile               |
| `out_tile`          | 8     | Registered output tile                   |
| `ls_dram_addr`      | 12    | Registered LOAD/STORE DRAM address       |
| `ls_buf_tile`       | 8     | Registered LOAD/STORE buffer tile        |
| `ls_size`           | 4     | Registered LOAD/STORE transfer size      |
| `loop_count_field`  | 12    | Registered LOOP count field              |
| `loop_target_field` | 8     | Registered LOOP target field             |
| `loop_stride_field` | 8     | Registered LOOP stride field             |
| `jump_target_field` | 12    | Registered JUMP target field             |
| `num_tiles`         | 2     | Number of tiles for current op           |
| `loop_remaining`    | 12    | LOOP iteration countdown                 |
| `loop_body_target`  | 8     | LOOP body target address (saved once)    |
| `in_loop`           | 1     | Inside a LOOP body                       |

\* A = `$clog2(SLOT_DEPTH)`.
