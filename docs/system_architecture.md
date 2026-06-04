# NPU Core — System Architecture

## Overview

The NPU core (`system.v`) is a parameterizable systolic-array-based matrix multiplier with runtime-configurable tile size and ping-pong double-buffered input/output memories. It computes `C = A × B` where tiles are sub-regions of N×N matrices, with configurable data widths and accumulator widths.

All intermediate and output values are **stationary** — they hold their state in registers until explicitly cleared or overwritten. The result matrix C is available row-by-row from the output buffer once `done` is asserted.

## Input → Output Transformation

| External Input | Internal path | External Output | Final result |
|----------------|---------------|-----------------|--------------|
| `act_din` (element → activation buffer) | → feed buffer (COL_MAJOR) → skew_a → systolic array in_left | `out_dout` (one row of C at `out_raddr`, N elements, async read) | `C[i][j]` = Σ_k A[i][k] × B[k][j] |
| `wgt_din` (element → weight buffer) | → feed buffer (row major) → skew_b → systolic array in_top | `done` | Operation complete |
| `start` | → execution_sequencer → FSM control | | |
| `matrix_size[31:0]` | tile dimension (1..N), latched at start | | |
| `act_base[31:0]` | activation column offset, latched for feed | | |
| `wgt_base[31:0]` | weight row offset, latched for feed | | |
| `out_base[31:0]` | output row offset, latched at readout_trig | | |

## Block Diagram

```
                  ┌───────────────────────────────────────────────────────┐
                  │                 system                                │
                  │                                                       │
  act_we ─────────┤  ┌─────────────────────────────┐                     │
  act_waddr ──────┤  │   feed_buffer act_buf       │                     │
  act_din ────────┤  │   (COL_MAJOR=1, 2×N×N deep) │                     │
                  │  └──────────┬──────────────────┘                     │
  wgt_we ─────────┤  ┌──────────▼──────────────────┐                     │
  wgt_waddr ──────┤  │   feed_buffer wgt_buf       │                     │
  wgt_din ────────┤  │   (COL_MAJOR=0, 2×N×N deep) │                     │
                  │  └──────────┬──────────────────┘                     │
                  │             │                                         │
                  │    act_feed_idx = data_idx + act_base                 │
                  │    wgt_feed_idx = data_idx + wgt_base                 │
                  │             │                                         │
                  │  ┌──────────▼──────────────────┐                     │
                  │  │   negedge register          │                     │
                  │  │   (data_feed_active gate)   │                     │
                  │  └──────────┬──────────────────┘                     │
                  │             │                                         │
  start ──────────┤  ┌──────────▼──────────┬──────────┐                  │
                  │  │   skew_a           │ skew_b   │                  │
                  │  │   (delay 2×i)      │ (delay 2×j)│                │
                  │  └──────────┬──────────┴────┬─────┘                  │
                  │             │               │                         │
                  │  ┌──────────▼───────────────▼──────┐                  │
                  │  │   systolic_array_nxn_ctrl       │                  │
                  │  │   (N×N PE_ctrl)                 │                  │
                  │  └──────────┬──────────────────────┘                  │
                  │             │ pe_c (N² × ACCUM)                      │
                  │  ┌──────────▼──────────────────────┐                  │
                  │  │   readout_shifter               │                  │
                  │  │   (parallel load, row shift)    │                  │
                  │  └──────────┬──────────────────────┘                  │
                  │             │ shift_row (N × ACCUM)                   │
                  │  ┌──────────▼──────────┐  ┌───────────────────┐      │
                  │  │   readout_unit      │  │  output_buffer    │      │
                  │  │   (internal, unused │  │  (2×N×N deep,     │      │
                  │  │    outputs)         │  │   row-level IO)   │      │
                  │  └─────────────────────┘  └────┬──────────────┘      │
                  │                                │                      │
  done ◄──────────┤                                │                      │
  out_raddr ──────┤                                │                      │
  out_dout ◄──────┘                                │                      │
                   └────────────────────────────────┘
```

## Data Flow

### 0. Buffer Preload (External)

Before starting a computation, the testbench/memory interface preloads the activation and weight buffers element-by-element:

- **Activation buffer** (`act_buf`, COL_MAJOR=1): stores `A[r][c]` at linear address `r × N + c`. The feed reads column `act_base + feed_idx` — each column `N` gives one N-element column of A.
- **Weight buffer** (`wgt_buf`, COL_MAJOR=0): stores `B[r][c]` at linear address `r × N + c`. The feed reads row `wgt_base + feed_idx` — each row gives one N-element row of B.

Both buffers are **2×N×N deep** to support ping-pong double-buffering. The Ping block occupies addresses `0..N×N-1`, the Pong block `N×N..2×N×N-1`. Bases `0..N-1` select Ping, bases `N..2N-1` select Pong.

### 1. Feed Generation

The `execution_sequencer` drives `data_valid` and `data_idx` to indicate which column/row pair to feed next. The feed control logic computes:

- `act_feed_idx = data_idx + act_base` — selects a column from the activation buffer
- `wgt_feed_idx = data_idx + wgt_base` — selects a row from the weight buffer

Feed `k` provides:
- `raw_a_col = A[:, k]` (column k of the tile, N elements)
- `raw_b_row = B[k, :]` (row k of the tile, N elements)

### 2. Skew Buffering

Two identical `skew_buffer` instances delay each element so that all `(A[i][k], B[k][j])` pairs arrive at `PE(i,j)` on the correct clock cycle:

- `skew_a`: row `i` is delayed by `i × 2` cycles
- `skew_b`: column `j` is delayed by `j × 2` cycles

### 3. Systolic Array Computation

The `systolic_array_nxn_ctrl` instantitates an N×N grid of `PE_ctrl` tiles. Each PE accumulates the dot product:

```
PE(i,j) accumulates: Σ_k A[i][k] × B[k][j]
```

### 4. Drain

After all M feeds, the sequencer enters DRAIN, keeping `acc_en=1` while the last data propagates through the pipeline.

### 5. Readout Shift

When the pipeline is fully drained, `readout_trig` pulses for 1 cycle, causing the `readout_shifter` to parallel-capture all N×N accumulator values from the array into N internal row registers. The sequencer then enters the SHIFT state, which lasts M cycles. During each SHIFT cycle, the shifter outputs one row (N elements).

### 6. Output Buffer Write

Each SHIFT cycle writes one row into the `output_buffer` at address `out_waddr` (starting from `out_base`, incremented each cycle). The output buffer is **2×N×N deep**:

- Ping block: rows 0..N-1 (`out_base = 0`)
- Pong block: rows N..2N-1 (`out_base = N`)

After the last SHIFT cycle, the sequencer asserts `done`. The result is read asynchronously via `out_raddr` / `out_dout`.

## Component Hierarchy

```
system
├── execution_sequencer              (FSM controller)
├── feed_buffer    #act_buf          (activation memory, COL_MAJOR, 2×N×N)
├── feed_buffer    #wgt_buf          (weight memory, row major, 2×N×N)
├── skew_buffer    #skew_a           (A-column skew)
├── skew_buffer    #skew_b           (B-row skew)
├── systolic_array_nxn_ctrl          (controlled array)
│   └── PE_ctrl × N×N               (processing elements)
├── readout_shifter                  (parallel load, row-by-row shift)
├── readout_unit                     (row collection, internal only)
└── output_buffer                    (result memory, 2×N×N)
```

## Pipeline Stages

| Stage | Cycles | Description |
|-------|--------|-------------|
| CLEAR | 1 | Reset all accumulators to 0 |
| LOAD | `2M` | Feed M column-row pairs (every 2 cycles) |
| DRAIN | `4M` (auto) | Wait for pipeline to drain |
| RDOUT | 1 | Load shifter with all PE accumulator values |
| SHIFT | `M` | Stream rows from shifter → output buffer |
| DONE | until `!start` | Hold done flag |

(M = runtime `matrix_size`, 1 ≤ M ≤ N)

## Latency

Total cycles from `start` to `done`:

```
L_total = 1 + 2M + 4M + 1 + M + 1 = 7M + 3
```

For M=4: 31 cycles. For M=8: 59 cycles.

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `N` | 4 | Physical matrix dimension (array size) |
| `DATA_WIDTH` | 16 | Element bit width |
| `ACCUM_WIDTH` | 40 | Accumulator bit width |

## Runtime Configuration (inputs, latched at `start`)

| Port | Width | Description |
|------|-------|-------------|
| `matrix_size` | 32 | Tile dimension M (1..N) |
| `act_base` | 32 | Activation column offset for sub-tile / ping-pong |
| `wgt_base` | 32 | Weight row offset for sub-tile / ping-pong |
| `out_base` | 32 | Output row offset for sub-tile / ping-pong |

## Buffer Interface

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `act_we` | input | 1 | Activation buffer write enable |
| `act_waddr` | input | `$clog2(2·N·N)` | Element write address |
| `act_din` | input | `DATA_WIDTH` | Element write data |
| `wgt_we` | input | 1 | Weight buffer write enable |
| `wgt_waddr` | input | `$clog2(2·N·N)` | Element write address |
| `wgt_din` | input | `DATA_WIDTH` | Element write data |
| `out_raddr` | input | `$clog2(2·N)` | Row read address (async) |
| `out_dout` | output | `N × ACCUM_WIDTH` | Row read data (async) |

## Interface Protocol

1. Preload activation/weight buffers via `act_we`/`wgt_we` (Ping or Pong block)
2. Set `matrix_size`, `act_base`, `wgt_base`, `out_base`
3. Assert `start` for at least one posedge
4. Sequencer auto-runs through CLEAR → LOAD → DRAIN → RDOUT → SHIFT → DONE
5. Wait for `done` posedge
6. Read result rows via `out_raddr` / `out_dout` (async, no clock needed between reads)
7. To restart with new data: preload the other buffer block, flip bases, pulse `start`

## Ping-Pong Double Buffering

Each feed/output buffer is 2×N×N deep to support overlap of computation and preload:

1. **Preload Ping block** (addresses `0..N·N-1` for elements, bases `0..N-1` for rows/columns)
2. **Start compute** with bases pointing to Ping block
3. **While computing**, preload Pong block (addresses `N·N..2·N·N-1`, bases `N..2N-1`)
4. **Wait for done**, read Ping result from output (`out_base=0`, `out_raddr=0..M-1`)
5. **Flip**: set bases to Pong, start next compute
6. **While computing**, preload Ping block with next tile's data

## Verification

The testbench (`tb_system.v`) runs per N:

1. **Full deterministic** (values derived from indices, verified against reference)
2. **Full random** (seed 42)
3. **Full random** (seed 99)
4. **Sub-tile M=2** (deterministic, tile fits within N×N)
5. **Sub-tile M=2** (random)
6. **Sub-tile M=2 with non-zero base offsets** (act_base=1, wgt_base=1, out_base=1)
7. **Ping-pong double buffer**: preload Ping → compute → preload Pong while computing → verify Ping → flip bases → compute Pong → verify Pong

All N from 2 to 4 pass with the default configuration.

## Memory Map (buffer addressing)

Each buffer is 2×N×N elements deep:

| Block | Address range | Base value |
|-------|--------------|------------|
| Ping (A/B) | `0 .. N·N-1` | 0 |
| Pong (A/B) | `N·N .. 2·N·N-1` | N |

Base values are interpreted per buffer:
- **Activation feed** (`act_base`): selects column `act_base + data_idx` — Ping for bases 0..N-1, Pong for bases N..2N-1
- **Weight feed** (`wgt_base`): selects row `wgt_base + data_idx`
- **Output write** (`out_base`): starts output row address at `out_base`, increments per shift

## Output Stationarity

| Module | Output | Stationary? | Why |
|--------|--------|-------------|-----|
| `PE_ctrl` | `out_c` | Yes | Register holds value until next clock edge; frozen when `acc_en=0` |
| `systolic_array_nxn_ctrl` | `out_c` | Yes | All PE `out_c` registers hold in parallel |
| `readout_shifter` | `row_out` | Yes | Internal row registers hold until overwritten by next `load` |
| `readout_unit` | `result` | Yes | Assembled from shifter rows, held until next readout |
| `execution_sequencer` | `done` | Yes | Held until `start` deasserted |
| `feed_buffer` | `dout` | Async | Combinational read from mem (changes with raddr) |
| `output_buffer` | `dout` | Async | Combinational read from mem (changes with raddr) |
