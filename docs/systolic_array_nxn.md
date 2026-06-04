# systolic_array_nxn — Basic N×N Systolic Array

## Overview

A purely combinational-wired N×N grid of `PE` tiles. Inputs (`in_left`, `in_top`) are flattened N-element vectors where element i occupies bits `[i×DATA_WIDTH +: DATA_WIDTH]`. Outputs (`out_c`) are flattened N×N-element with element (i,j) at bit offset `(i×N + j) × ACCUM_WIDTH`.

This module is the **uncontrolled** variant — all PEs accumulate freely on every clock. For the controlled version see `systolic_array_nxn_ctrl`.

## Ports

| Port      | Direction | Width                        | Description                        |
|-----------|-----------|------------------------------|------------------------------------|
| `clk`     | input     | 1                            | Clock                              |
| `rst`     | input     | 1                            | Synchronous reset                  |
| `in_left` | input     | `N × DATA_WIDTH`             | Flattened column inputs (A[:,k])   |
| `in_top`  | input     | `N × DATA_WIDTH`             | Flattened row inputs (B[k,:])      |
| `out_c`   | output    | `N × N × ACCUM_WIDTH`        | Flattened C matrix results         |

## Parameters

| Parameter     | Default | Description                          |
|---------------|---------|--------------------------------------|
| `N`           | 4       | Matrix dimension (N×N PEs)           |
| `DATA_WIDTH`  | 16      | Bit width of `x`/`y` operands        |
| `ACCUM_WIDTH` | 40      | Bit width of the accumulator/output  |

## Internal Wiring

```
         in_top[0]  in_top[1]  in_top[2]  in_top[3]
             │          │          │          │
             ▼          ▼          ▼          ▼
in_left[0]──►(0,0)────►(0,1)────►(0,2)────►(0,3)──►(dangling)
             │          │          │          │
             ▼          ▼          ▼          ▼
in_left[1]──►(1,0)────►(1,1)────►(1,2)────►(1,3)──►(dangling)
             │          │          │          │
             ▼          ▼          ▼          ▼
in_left[2]──►(2,0)────►(2,1)────►(2,2)────►(2,3)──►(dangling)
             │          │          │          │
             ▼          ▼          ▼          ▼
in_left[3]──►(3,0)────►(3,1)────►(3,2)────►(3,3)──►(dangling)
                            │
                     x_wire[i][j+1] = PE(i,j).out_x
                     y_wire[i+1][j] = PE(i,j).out_y
```

- `x_wire[i][0:N]` — horizontal connections. `x_wire[i][0]` = `in_left[i]`, `x_wire[i][j+1]` = `PE(i,j).out_x`.
- `y_wire[0:N][j]` — vertical connections. `y_wire[0][j]` = `in_top[j]`, `y_wire[i+1][j]` = `PE(i,j).out_y`.

## Data Flow

The systolic array implements Cannon's algorithm variant for matrix multiplication:

```
C[i][j] = Σ_k A[i][k] × B[k][j]
```

1. **Column k of A** enters `in_left`: `A[:,k]` = flattened column
2. **Row k of B** enters `in_top`: `B[k,:]` = flattened row
3. Over successive feed cycles (k=0, 1, ..., N-1), each PE(i,j) accumulates `A[i][k] × B[k][j]`
4. After N feeds plus pipeline drain, PE(i,j).out_c holds the completed C[i][j]

## Pipeline Depth

Each PE adds 2 cycles of latency from `in_x`/`in_y` capture to `out_c` stabilization. For the bottom-right PE(N-1,N-1):

- Skew delay: `(N-1) × 2` cycles
- Array propagation: `N-1` cycles (one per PE along row and column)
- PE internal: 3 cycles (register → multiply → accumulate → out_c)

Total from last feed entering the array to valid `out_c` at PE(N-1,N-1): approximately `4N` cycles.

## Limitations

- No `acc_clr` or `acc_en` — all PEs accumulate continuously.
- A synchronous reset (`rst`) is the only way to clear accumulators.
- Use `systolic_array_nxn_ctrl` for designs requiring per-operation control.
