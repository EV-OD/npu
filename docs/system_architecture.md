# NPU Core — System Architecture

## Overview

The NPU core is a parameterizable systolic-array-based matrix multiplier designed for tiled matrix multiplication. It computes `C = A × B` where all matrices are N×N, with configurable data widths and accumulator widths.

All intermediate and output values are **stationary** — they hold their state in registers until explicitly cleared or overwritten. The result matrix C is available in parallel on `result` once `done` is asserted.

## Input → Output Transformation

| External Input | Internal path | External Output | Final result |
|----------------|---------------|-----------------|--------------|
| `raw_a_col` (one column of A per feed, N elements, flattened) | → skew_a → systolic array in_left | `result` (N×N × ACCUM_WIDTH, flattened) | `C[i][j]` = Σ_k A[i][k] × B[k][j] |
| `raw_b_row` (one row of B per feed, N elements, flattened) | → skew_b → systolic array in_top | `result_valid` | High while `result` holds valid C matrix |
| `start` | → execution_sequencer → FSM control | `done` | Operation complete |
| | | `seq_data_valid`, `seq_data_idx` | Feed handshake for external data source |

## Block Diagram

```
                  ┌──────────────────────────────────────────────────┐
                  │              npu_core                            │
                  │                                                  │
  start ─────────►│  ┌──────────────────────────────────────┐       │
                  │  │   execution_sequencer               │       │
  seq_data_valid ◄──┤  - state machine                    │       │
  seq_data_idx   ◄──┤  - data_valid/data_idx generation   │       │
                  │  │  - acc_clr, acc_en, readout_trig    │       │
                  │  │  - busy, done                      │       │
                  │  └──┬───────────┬──────────┬──────────┘       │
                  │     │           │          │                  │
                  │  acc_clr    acc_en   readout_trig            │
                  │     │           │          │                  │
 raw_a_col ───────►│  ┌──▼───────┐ ┌─▼──────────▼──────┐          │
                  │  │skew_a    │ │  systolic_array   │          │
 raw_b_row ───────►│  │skew_b    │ │  _nxn_ctrl       │          │
                  │  └────┬─────┘ │  (N×N PE_ctrl)   │          │
                  │       │       │                   │          │
                  │       └──────►│ in_left/in_top    │          │
                  │               │                   │          │
                  │               └───────┬───────────┘          │
                  │                       │ pe_c (N² × ACCUM)   │
                  │               ┌───────▼───────────┐          │
                  │               │ readout_shifter   │          │
                  │               │ (parallel load,   │          │
                  │               │  row-by-row shift)│          │
                  │               └───────┬───────────┘          │
                  │               row_out │ (N × ACCUM)          │
                  │               ┌───────▼───────────┐          │
                  │               │   readout_unit    │          │
  result_valid ◄──┤               │                   │          │
  result      ◄──┤               └───────────────────┘          │
                  │                                                  │
  done ◄──────────┤                                                  │
                  └──────────────────────────────────────────────────┘
```

## Data Flow

### 1. Feed Generation

The `execution_sequencer` drives `data_valid` and `data_idx` to indicate which column/row pair to feed next. External logic (testbench or memory interface) uses these signals to drive `raw_a_col` and `raw_b_row` with one column of A and one row of B each cycle.

Feed `k` provides:
- `raw_a_col` = `A[:, k]` (column k of A, N elements)
- `raw_b_row` = `B[k, :]` (row k of B, N elements)

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

After all N feeds, the sequencer enters DRAIN, keeping `acc_en=1` while the last data propagates through the pipeline.

### 5. Readout Shift

When the pipeline is fully drained, `readout_trig` pulses for 1 cycle, causing the `readout_shifter` to parallel-capture all N×N accumulator values from the array into N internal row registers. The sequencer then enters the SHIFT state, which lasts N cycles. During each SHIFT cycle, the shifter outputs one row (N elements) to the `readout_unit`.

### 6. Result Assembly

The `readout_unit` collects one row per cycle over N cycles. On the last row, it assembles the full N×N result matrix and asserts `valid`. The sequencer transitions to DONE_S, asserting `done`.

## Component Hierarchy

```
npu_core
├── execution_sequencer        (FSM controller)
├── skew_buffer  #skew_a       (A-column skew)
├── skew_buffer  #skew_b       (B-row skew)
├── systolic_array_nxn_ctrl    (controlled array)
│   └── PE_ctrl × N×N         (processing elements)
├── readout_shifter            (parallel load, row-by-row shift)
└── readout_unit               (row collection + result assembly)
```

## Pipeline Stages

| Stage | Cycles | Description |
|-------|--------|-------------|
| CLEAR | 1 | Reset all accumulators to 0 |
| LOAD | `2N` | Feed N column-row pairs (every 2 cycles) |
| DRAIN | `4N` (auto) | Wait for pipeline to drain |
| RDOUT | 1 | Load shifter with all PE accumulator values |
| SHIFT | `N` | Stream rows from shifter → readout unit |
| DONE | until `!start` | Hold done flag |

## Latency

Total cycles from `start` to `done`:

```
L_total = 1 + 2N + 4N + 1 + N + 1 = 7N + 3
```

For N=4: 31 cycles. For N=8: 59 cycles.

## Parameters (all tied together)

The `npu_core` module exposes the same parameters as its sub-modules:

| Parameter | Default | Sub-modules affected |
|-----------|---------|---------------------|
| `N` | 4 | All |
| `DATA_WIDTH` | 16 | `PE_ctrl`, `skew_buffer` |
| `ACCUM_WIDTH` | 40 | `PE_ctrl`, `readout_shifter`, `readout_unit` |

## Interface Protocol

1. Assert `start` for at least one posedge
2. On each `data_valid` posedge, read `data_idx` and provide `raw_a_col` / `raw_b_row` at the following negedge
3. Wait for `done` on posedge; `result` and `result_valid` are available
4. Deassert `start` to return sequencer to IDLE for the next operation

## Verification

The testbench (`tb_system.v`) runs three tests per N:

1. **Deterministic matrix** (values derived from indices, verified against reference computation)
2. **Random matrix** (seed 42, random values, all elements compared)
3. **Random matrix** (seed 99, independent random values)

All N from 2 to 8 pass with the default configuration.

## Output Stationarity

All results in this system are **stationary**:

| Module | Output | Stationary? | Why |
|--------|--------|-------------|-----|
| `PE_ctrl` | `out_c` | Yes | Register holds value until next clock edge; frozen when `acc_en=0` |
| `systolic_array_nxn_ctrl` | `out_c` | Yes | All PE `out_c` registers hold in parallel |
| `readout_shifter` | `row_out` | Yes | Internal row registers hold until overwritten by next `load` |
| `readout_unit` | `result` | Yes | Assembled from shifter rows, held until next readout |
| `execution_sequencer` | `done` | Yes | Held until `start` deasserted |
