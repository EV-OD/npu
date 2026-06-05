# NPU Core — System Architecture

## Overview

The NPU core consists of two major subsystems:

1. **Instruction Pipeline** (`system.v`): Fetches, decodes, and dispatches 32-bit instructions. Manages tile-level dependencies and controls instruction sequencing (linear, loop, jump). Exposes a standard execution-unit handshake (`sys_start`/`sys_done`).

2. **Systolic Datapath** (`execution_sequencer.v` + `systolic_array_nxn_ctrl.v` + ...): Implements the matrix multiply engine: N×N processing elements, feed buffers, skew buffers, readout shifter, and output buffer.

The instruction pipeline is the top-level orchestrator. The systolic datapath receives tile numbers and a `sys_start` pulse, executes the matrix multiply, and asserts `sys_done` when complete.

## System Block Diagram (`system.v`)

```
                    ┌──────────────────────────────────────────────────┐
                    │                   system                         │
                    │                                                  │
  dma_* ────────────┤  ┌──────────────┐                               │
                    │  │    ibram     │  (double-buffered, 2×64×32)    │
                    │  └──────┬───────┘                               │
                    │         │ pc_addr, inst_dout                     │
                    │         │                                         │
                    │  ┌──────▼───────┐                               │
                    │  │ dispatch_unit│  (8-state FSM)                 │
                    │  └──┬──┬──┬──┬──┘                               │
                    │     │  │  │  │                                    │
                    │     │  │  │  └─── dep_check_en / dep_release_en   │
                    │     │  │  │         ┌───────────────────────┐     │
                    │     │  │  └─────────┤ dependency_checker   │     │
                    │     │  │            │ (64-entry lock table) │     │
                    │     │  │            └───────────────────────┘     │
                    │     │  │                                          │
                    │     │  └──────── sys_start/sys_wgt_base/...       │
                    │     │          (to execution unit)                │
                    │     │                                             │
                    │     └────────────── sys_done (from exec unit)     │
                    │                                                   │
  state_debug ──────┤  (FSM state, opcode, lock_status debug outputs)  │
  lock_status ──────┤                                                   │
                    └──────────────────────────────────────────────────┘
```

## Instruction Pipeline (current `system.v`)

### Parameters

| Parameter    | Default | Description                              |
|--------------|---------|------------------------------------------|
| `N`          | 4       | Matrix dimension (passed through to exec)|
| `SLOT_DEPTH` | 64      | Instructions per IBRAM slot              |
| `NUM_TILES`  | 64      | Number of tiles for dependency checker   |

### Ports

| Port             | Width | Direction | Description                                |
|------------------|-------|-----------|--------------------------------------------|
| `clk`            | 1     | I         | Clock                                      |
| `rst`            | 1     | I         | Synchronous reset                          |
| `dma_en`         | 1     | I         | DMA write enable                          |
| `dma_we`         | 1     | I         | DMA write strobe                          |
| `dma_addr`       | A*    | I         | DMA write address                         |
| `dma_din`        | 32    | I         | DMA write data (instruction word)         |
| `sys_busy`       | 1     | I         | Execution unit busy (status only, unused) |
| `sys_done`       | 1     | I         | Execution unit done (triggers RELEASE)    |
| `sys_start`      | 1     | O         | Pulse: start execution (MATMUL only)       |
| `sys_matrix_size`| 32    | O         | Matrix dimension (constant `N`)           |
| `sys_act_base`   | 32    | O         | Activation tile number                    |
| `sys_wgt_base`   | 32    | O         | Weight tile number                        |
| `sys_out_base`   | 32    | O         | Output tile number                        |
| `active_slot`    | 1     | O         | IBRAM active slot (0 or 1)               |
| `ibram_ready`    | 1     | O         | IBRAM active slot is full                |
| `busy`           | 1     | O         | Pipeline is actively processing           |
| `state_debug`    | 4     | O         | FSM state for debug                       |
| `opcode_debug`   | 4     | O         | Current opcode for debug                  |
| `lock_status`    | 64    | O         | Tile lock table readout                   |

\* A = `$clog2(2*SLOT_DEPTH)` (default: 8 bits for 128 total instruction addresses).

### Submodules

| Instance       | Module               | Description                              |
|----------------|----------------------|------------------------------------------|
| `u_ibram`      | `ibram`              | Double-buffered instruction RAM          |
| `u_dep`        | `dependency_checker` | 64-entry tile lock table                 |
| `u_dispatch`   | `dispatch_unit`      | 8-state pipeline FSM                     |

The instruction decoder is **not a separate module** — field extraction happens inline in `dispatch_unit.v` during the DECODE_W state.

### Pipeline States

| State       | Description                                        |
|-------------|----------------------------------------------------|
| `IDLE`      | Waiting for IBRAM ready                            |
| `FETCH`     | Assert PC to IBRAM, increment PC                   |
| `DECODE_W`  | Sample instruction word, register all fields        |
| `CHECK`     | Assert dep_check_en for MATMUL/LOAD/STORE          |
| `DISPATCH`  | Assert sys_start (MATMUL) or init loop/branch       |
| `WAIT_EXEC` | Poll sys_done, stall until done                     |
| `RELEASE`   | Assert dep_release_en, release tiles                |
| `LOOP_JUMP` | Set PC to loop/jump target                         |

See `docs/dispatch_unit.md` for complete FSM details.

### Instruction Flow (Cycle Counts)

| Opcode     | FETCH | D_W | CHECK | DISPATCH | WAIT_EXEC | RELEASE | LJ  | Total |
|------------|-------|-----|-------|----------|-----------|---------|-----|-------|
| MATMUL     | 1     | 1   | 3†     | 1        | 7         | 1       | 0   | 14    |
| LOAD/STORE | 1     | 1   | 3†     | 1        | 5         | 1       | 0   | 12    |
| BARRIER/NOP| 1     | 1   | 1     | 1        | 0         | 0       | 0   | 4     |
| LOOP       | 1     | 1   | 1     | 1        | 0         | 0       | 1   | 5     |
| JUMP       | 1     | 1   | 1     | 1        | 0         | 0       | 1   | 5     |

† CHECK takes 3 cycles: (1) assert dep_check_en, (2) dep checker processes, (3) read dep_grant. If conflict, CHECK stalls indefinitely.

### Memory Map (DMA)

Instructions are loaded via the DMA interface (`dma_en`, `dma_we`, `dma_addr`, `dma_din`). Address mapping:

| Address range              | IBRAM region      |
|----------------------------|-------------------|
| `0 .. SLOT_DEPTH-1`        | Slot 0            |
| `SLOT_DEPTH .. 2*SLOT_DEPTH-1` | Slot 1        |

The DMA interface writes at posedge when both `dma_en` and `dma_we` are asserted.

---

## Systolic Datapath (existing submodules)

The systolic array subsystem computes `C = A × B` for N×N tiles. It is driven by the execution unit handshake from the instruction pipeline.

### Component Hierarchy

```
execution unit (generic handshake interface)
├── execution_sequencer              (FSM: CLEAR→LOAD→DRAIN→RDOUT→SHIFT→DONE)
├── feed_buffer    #act_buf          (activation memory, COL_MAJOR, 2×N×N)
├── feed_buffer    #wgt_buf          (weight memory, row major, 2×N×N)
├── skew_buffer    #skew_a           (A-column skew, delay 2×i)
├── skew_buffer    #skew_b           (B-row skew, delay 2×j)
├── systolic_array_nxn_ctrl          (controlled array)
│   └── PE_ctrl × N×N               (processing elements)
├── readout_shifter                  (parallel load, row-by-row shift)
├── readout_unit                     (row collection, internal only)
└── output_buffer                    (result memory, 2×N×N)
```

### Data Flow

The execution sequencer drives the computation:

| Stage   | Cycles    | Description                                |
|---------|-----------|--------------------------------------------|
| CLEAR   | 1         | Reset all accumulators to 0                |
| LOAD    | `2M`      | Feed M column-row pairs (every 2 cycles)   |
| DRAIN   | `4M`      | Wait for pipeline to drain                 |
| RDOUT   | 1         | Load shifter with all PE accumulator values|
| SHIFT   | `M`       | Stream rows from shifter → output buffer   |
| DONE    | until `!start` | Hold done flag                        |

(M = runtime `matrix_size`, 1 ≤ M ≤ N)

**Total latency**: `L_total = 1 + 2M + 4M + 1 + M + 1 = 7M + 3` cycles from `start` to `done`.

### Feed Buffers (Ping-Pong)

Each feed/output buffer is `2×N×N` deep:

| Block     | Address range      | Base value |
|-----------|--------------------|------------|
| Ping (A/B)| `0 .. N·N-1`       | 0          |
| Pong (A/B)| `N·N .. 2·N·N-1`  | N          |

### Processing Element

Each `PE_ctrl` in the N×N array computes: `C[i][j] += A[i][k] × B[k][j]` for k=0..M-1.

Intermediate values are **stationary** — held in registers until the next computation or reset.

### Readout

After DRAIN completes:
1. `readout_trig` pulses — all N×N accumulator values parallel-capture into the shifter
2. SHIFT state outputs one row (N elements) per cycle
3. Each row is written to the output buffer

### Verification (Systolic Datapath Only)

The `tb_system.v` legacy tests verify all N from 2 to 4 with:
- Full deterministic and random fills
- Sub-tile M=2 with offsets
- Ping-pong double-buffer preload overlap

---

## Integration: Instruction Pipeline → Execution Unit

The instruction pipeline and the systolic datapath are designed to connect through a standard handshake:

### Interface Signals

| Signal              | Width | Direction (pipeline) | Description          |
|---------------------|-------|-----------------------|----------------------|
| `sys_start`         | 1     | O                     | Pulse: start compute |
| `sys_matrix_size`   | 32    | O                     | Tile dimension (N)   |
| `sys_wgt_base`      | 32    | O                     | Weight tile number   |
| `sys_act_base`      | 32    | O                     | Activation tile number|
| `sys_out_base`      | 32    | O                     | Output tile number   |
| `sys_busy`          | 1     | I                     | Exec unit busy       |
| `sys_done`          | 1     | I                     | Exec unit complete   |

### Protocol

1. **MATMUL opcode**: Pipeline asserts `sys_start=1` for 1 cycle with tile numbers on `sys_*_base`.
2. Execution unit captures tile numbers at posedge of `sys_start`, begins computation.
3. Execution unit asserts `sys_busy=1` during computation (informational — not used by pipeline FSM).
4. Execution unit asserts `sys_done=1` when computation is complete and results are available.
5. Pipeline transitions WAIT_EXEC → RELEASE, freeing tile locks.

### LOAD/STORE

For LOAD/STORE, the pipeline does **not** assert `sys_start`. An external proxy module monitors the WAIT_EXEC state and drives `sys_done` after a fixed latency (e.g., via a counter or DMA completion signal). The pipeline only releases the single tile lock after `sys_done` is received.

---

## Verification

### Instruction Pipeline Tests

| Testbench              | Checks | Description                               |
|------------------------|--------|-------------------------------------------|
| `tb_dependency`        | 51     | Lock/unlock, conflict, edge cases         |
| `tb_dispatch`          | 79     | All 8 FSM states, opcode paths, loop/jump |
| `tb_instruction_pipeline` | 17  | End-to-end pipeline with all opcodes      |
| `tb_system`            | 106    | Full system (7 opcodes × 2+, groups A–F)  |
| **Total**              | **253** | All passing                                |

### Test Scenarios (`tb_system`)

| Group | Scenario                               | Opcodes                |
|-------|----------------------------------------|------------------------|
| A     | Two independent MATMULs on tile 1,2    | MATMUL, MATMUL         |
| B     | LOAD → STORE → MATMUL chain on tile 10 | LOAD, STORE, MATMUL    |
| C     | BARRIER + NOP pipeline passthrough     | BARRIER, NOP           |
| D     | LOOP count=3 over MATMUL body          | LOOP, MATMUL           |
| E     | JUMP to addr 12 (skip addrs 10–11)     | JUMP, MATMUL           |
| F     | Post-jump chain                        | MATMUL, LOAD, STORE, BARRIER |

## Parameters Summary

| Parameter    | Scope                 | Default | Description                      |
|--------------|-----------------------|---------|----------------------------------|
| `N`          | Pipeline + Systolic   | 4       | Physical matrix dimension        |
| `SLOT_DEPTH` | Pipeline only         | 64      | Instructions per IBRAM slot      |
| `NUM_TILES`  | Pipeline only         | 64      | Dependency checker table depth   |
| `DATA_WIDTH` | Systolic only         | 16      | Element bit width                |
| `ACCUM_WIDTH`| Systolic only         | 40      | Accumulator bit width            |
