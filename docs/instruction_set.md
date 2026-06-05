# Instruction Set Architecture

## Overview

All instructions are 32-bit fixed-width. The upper 4 bits `[31:28]` encode the opcode; the remaining 28 bits are opcode-dependent operands.

| Bits     | Field       | Description          |
|----------|-------------|----------------------|
| [31:28]  | `opcode`    | 4-bit operation code |
| [27:0]   | `operands`  | Opcode-dependent     |

## Opcode Map

| Mnemonic | Opcode | Encoding | Description                    |
|----------|--------|----------|--------------------------------|
| `MATMUL` | 0x0    | `4'h0`   | Matrix multiply (3 operands)   |
| `LOAD`   | 0x1    | `4'h1`   | Load tile from DRAM            |
| `STORE`  | 0x2    | `4'h2`   | Store tile to DRAM             |
| `LOOP`   | 0x3    | `4'h3`   | Loop (count, target)           |
| `JUMP`   | 0x4    | `4'h4`   | Unconditional jump             |
| `BARRIER`| 0xE    | `4'hE`   | Barrier (fence)                |
| `NOP`    | 0xF    | `4'hF`   | No operation                   |

Opcodes 0x5–0xD are reserved (undefined behavior).

## MATMUL — Matrix Multiply

Format: `MATMUL(wt_tile, act_tile, out_tile)`

| Bits     | Field       | Width | Description                    |
|----------|-------------|-------|--------------------------------|
| [31:28]  | `opcode`    | 4     | `0x0`                          |
| [27:20]  | `wt_tile`   | 8     | Weight tile number             |
| [19:12]  | `act_tile`  | 8     | Activation tile number         |
| [11:4]   | `out_tile`  | 8     | Output tile number             |
| [3:0]    | `reserved`  | 4     | Must be 0                      |

The dispatch unit drives three tile numbers to the execution unit via `sys_wgt_base`, `sys_act_base`, `sys_out_base`. The dependency checker locks all three tiles atomically before dispatch, and releases them after execution completes.

**Encoding macro (Verilog):** `{`OP_MATMUL, 8'd(wt), 8'd(act), 8'd(out), 4'd0}`

**Example:** `MATMUL(wt=1, act=2, out=3)` = `32'h0010_2030`

## LOAD — Load Tile from DRAM

Format: `LOAD(dram_addr, buf_tile, size)`

| Bits     | Field       | Width | Description                    |
|----------|-------------|-------|--------------------------------|
| [31:28]  | `opcode`    | 4     | `0x1`                          |
| [27:16]  | `dram_addr` | 12    | DRAM source address            |
| [15:8]   | `buf_tile`  | 8     | Destination buffer tile number |
| [7:4]    | `reserved`  | 4     | Must be 0                      |
| [3:0]    | `size`      | 4     | Transfer size (elements)       |

`sys_start` is **not** asserted for LOAD — the dispatch unit transitions directly to `WAIT_EXEC`. The dependency checker locks the single buffer tile before execution, and releases it after completion.

**Encoding macro (Verilog):** `{`OP_LOAD, 12'd(dram_addr), 8'd(tile), 4'h0, 4'd(size)}`

**Example:** `LOAD(0x100, tile=10, size=1)` = `32'h1100_0A01`

## STORE — Store Tile to DRAM

Format: `STORE(dram_addr, buf_tile, size)`

| Bits     | Field       | Width | Description                    |
|----------|-------------|-------|--------------------------------|
| [31:28]  | `opcode`    | 4     | `0x2`                          |
| [27:16]  | `dram_addr` | 12    | DRAM destination address       |
| [15:8]   | `buf_tile`  | 8     | Source buffer tile number      |
| [7:4]    | `reserved`  | 4     | Must be 0                      |
| [3:0]    | `size`      | 4     | Transfer size (elements)       |

Identical dispatch behavior to LOAD: no `sys_start`, single-tile dependency check and release.

**Encoding macro (Verilog):** `{`OP_STORE, 12'd(dram_addr), 8'd(tile), 4'h0, 4'd(size)}`

**Example:** `STORE(0x200, tile=10, size=1)` = `32'h2200_0A01`

## LOOP — Counted Loop

Format: `LOOP(count, target, stride)`

| Bits     | Field       | Width | Description                    |
|----------|-------------|-------|--------------------------------|
| [31:28]  | `opcode`    | 4     | `0x3`                          |
| [27:16]  | `count`     | 12    | Iteration count (0 = fall through) |
| [15:8]   | `target`    | 8     | Target address (0–255, truncated to slot depth) |
| [7:0]    | `stride`    | 8     | Stride (reserved, not used)    |

### Behavior

- **First encounter** (`in_loop=0`): initializes `loop_remaining = count - 1`, sets `in_loop=1`, jumps to `target`.
- **Subsequent encounters** (`in_loop=1`, `loop_remaining > 0`): decrements `loop_remaining`, jumps to `target`.
- **Fall-through** (`loop_remaining == 0`): clears `in_loop`, executes next sequential instruction.

The target address is truncated to `$clog2(SLOT_DEPTH)` bits (e.g., 6 bits for SLOT_DEPTH=64).

The stride field is decoded but not used by the current dispatch unit.

**Encoding macro (Verilog):** `{`OP_LOOP, 12'd(count), 8'd(target), 8'd(stride)}`

**Example:** `LOOP(count=3, target=7, stride=0)` = `32'h3003_0700`

### Timing Note

The `loop_remaining` check in the next-state logic uses the pre-decrement value. At the DISPATCH posedge:
1. The combinatorial nxt evaluates `loop_remaining` (the register value before NBA update)
2. The sequential block schedules `loop_remaining <= loop_remaining - 1` (NBA)

So when `loop_remaining == 1`, the nxt sees `> 0` and transitions to `LOOP_JUMP`. The decrement to 0 is applied after the posedge, meaning one more body execution occurs before the next LOOP encounter sees `remaining == 0`.

## JUMP — Unconditional Jump

Format: `JUMP(target)`

| Bits     | Field       | Width | Description                    |
|----------|-------------|-------|--------------------------------|
| [31:28]  | `opcode`    | 4     | `0x4`                          |
| [27:16]  | `target`    | 12    | Jump target address            |
| [15:0]   | `reserved`  | 16    | Must be 0                      |

The target address is truncated to `$clog2(SLOT_DEPTH)` bits. The PC is set to `target` at the `LOOP_JUMP` state (same physical state used by LOOP). Instructions at addresses between the JUMP and the target are skipped.

**Encoding macro (Verilog):** `{`OP_JUMP, 12'd(target), 16'h0}`

**Example:** `JUMP(target=12)` = `32'h400C_0000`

## BARRIER — Fence

Format: `BARRIER`

| Bits     | Field       | Width | Description                    |
|----------|-------------|-------|--------------------------------|
| [31:28]  | `opcode`    | 4     | `0xE`                          |
| [27:0]   | `reserved`  | 28    | Must be 0                      |

BARRIER bypasses the dependency checker (no wait for `dep_grant`) and bypasses WAIT_EXEC entirely. The dispatch transitions directly: `DECODE_W → CHECK → DISPATCH → FETCH`. It is intended as a sequential fence for future out-of-order implementations.

**Encoding macro (Verilog):** `{`OP_BARRIER, 28'h0}`

## NOP — No Operation

Format: `NOP`

| Bits     | Field       | Width | Description                    |
|----------|-------------|-------|--------------------------------|
| [31:28]  | `opcode`    | 4     | `0xF`                          |
| [27:0]   | `reserved`  | 28    | Must be 0                      |

Identical pipeline behavior to BARRIER: no dep check, no execution wait. Passes through the pipeline in 4 cycles (FETCH→DECODE_W→CHECK→DISPATCH→FETCH).

**Encoding macro (Verilog):** `{`OP_NOP, 28'h0}`

## Instruction Encoding Quick Reference

| Instruction  | Hex Pattern                      | Example                    |
|--------------|----------------------------------|----------------------------|
| MATMUL       | `0M_ww_aa_oo`                    | `0010_2030` = MATMUL(1,2,3) |
| LOAD         | `1D_DD_DT_T0_0S`                 | `1100_0A01` = LOAD(0x100,10,1) |
| STORE        | `2D_DD_DT_T0_0S`                 | `2200_0A01` = STORE(0x200,10,1) |
| LOOP         | `3C_CC_CT_T0_00`                 | `3003_0700` = LOOP(3,7,0)   |
| JUMP         | `4J_JJ_J0_00_00`                 | `400C_0000` = JUMP(12)      |
| BARRIER      | `E000_0000`                      | `E000_0000`                 |
| NOP          | `F000_0000`                      | `F000_0000`                 |

Where `M=opcode`, `ww=wt_tile`, `aa=act_tile`, `oo=out_tile`, `D=DRAM address`, `T=tile`, `S=size`, `C=count`, `J=jump_target`.
