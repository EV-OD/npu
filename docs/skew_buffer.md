# skew_buffer — Input Data Skew Buffer

## Overview

The skew buffer delays each row/column of the input data by `i × DELAY_PER_STEP` cycles before presenting it to the systolic array. This aligns the data so that element `(i, k)` of A and `(k, j)` of B arrive at `PE(i, j)` in the correct clock cycle, implementing the systolic schedule required by Cannon's algorithm.

Without skewing, all elements of a feed column/row would enter the array simultaneously, and the matrix multiplication would not produce correct results.

## Input → Output Transformation

| Input | What it does | Output | What it represents |
|-------|-------------|--------|--------------------|
| `din[i]` | Element `i` of the input vector passes through a shift register of length `i × DELAY_PER_STEP`; each register delays by 1 clock cycle | `dout[i]` | `din[i]` delayed by `i × DELAY_PER_STEP - 1` cycles |

For row 0: pass-through (zero delay). For row i>0: the effective delay is `i × DELAY_PER_STEP - 1` cycles.

The transformation applied is:

```
dout[i] at time t = din[i] at time t - (i × DELAY_PER_STEP - 1)
```

## Ports

| Port   | Direction | Width                 | Description                             |
|--------|-----------|-----------------------|-----------------------------------------|
| `clk`  | input     | 1                     | Clock                                   |
| `rst`  | input     | 1                     | Synchronous reset (zeros all registers) |
| `din`  | input     | `N × DATA_WIDTH`      | Flattened input vector (one column/row) |
| `dout` | output    | `N × DATA_WIDTH`      | Flattened skewed output vector          |

## Parameters

| Parameter        | Default | Description                                       |
|------------------|---------|---------------------------------------------------|
| `N`              | 4       | Number of elements per input vector                |
| `DATA_WIDTH`     | 16      | Bit width of each element                          |
| `DELAY_PER_STEP` | 2       | Delay increment per row-index (cycles per element) |

## Internal Architecture

```
           din[N-1]    din[N-2]    ...    din[1]     din[0]
              │           │                    │         │
         ┌────▼────┐ ┌────▼────┐          ┌────▼────┐   │
         │Delay    │ │Delay    │          │Delay    │   │
         │(N-1)×2  │ │(N-2)×2  │          │  1×2    │   │
         │shifts   │ │shifts   │    ...   │shifts   │   │
         └────┬────┘ └────┬────┘          └────┬────┘   │
              │           │                    │        │
           dout[N-1]   dout[N-2]           dout[1]  dout[0] (no delay)
```

For row index `i`:

- **`i == 0`**: pass-through (zero delay). `dout = din`.
- **`i > 0`**: shift register of length `CURRENT_DELAY = i × DELAY_PER_STEP`. Data shifts right by one position each clock. Output is the last register: `dout = shift_reg[CURRENT_DELAY-1]`.

## Effective Delay

The shift register has `CURRENT_DELAY` registers (indices 0 to CURRENT_DELAY-1). Data enters at `shift_reg[0]` and appears at `shift_reg[CURRENT_DELAY-1]` after `CURRENT_DELAY` clocks. However, because the output is a continuous wire assignment, the **effective delay** from posedge of entry to posedge of availability at `dout` is:

```
effective_delay = CURRENT_DELAY - 1 = i × DELAY_PER_STEP - 1
```

For `DELAY_PER_STEP = 2`:

| Row i | Registers | Effective delay |
|-------|-----------|-----------------|
| 0     | 0 (wire)  | 0               |
| 1     | 2         | 1               |
| 2     | 4         | 3               |
| 3     | 6         | 5               |
| 4     | 8         | 7               |
| ...   | ...       | ...             |

## Why Two Skew Buffers?

The NPU uses **two** skew buffers:

- **`skew_a`**: skews `raw_a_col` (A[:,k]) — one column of A per feed
- **`skew_b`**: skews `raw_b_row` (B[k,:]) — one row of B per feed

Both use `DELAY_PER_STEP = 2`. The double skew ensures that when the skewed A column flows rightward through the array and the skewed B row flows downward, each PE receives its matching `(A[i][k], B[k][j])` pair at the same clock cycle.

## Reset Behavior

On `rst`, all shift registers are zeroed. After reset deassertion, `CURRENT_DELAY` clock cycles of zeros appear at `dout` before the first valid feed data propagates through the longest delay chain.

## Hardware Cost

Total flip-flops = `N × (N-1) × DELAY_PER_STEP / 2` (sum of an arithmetic series). For N=8, `DELAY_PER_STEP=2`: 56 flip-flops per skew buffer.
