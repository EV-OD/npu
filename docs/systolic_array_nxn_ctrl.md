# systolic_array_nxn_ctrl — Controlled N×N Systolic Array

## Overview

Identical topology to `systolic_array_nxn` but instantiates `PE_ctrl` instead of `PE`. Two additional control signals (`acc_clr`, `acc_en`) are distributed to every PE in the array, allowing the external sequencer to:

1. **Clear all accumulators** before starting a new matrix multiply
2. **Enable accumulation** during the load and drain phases
3. **Freeze accumulators** for readout

## Input → Output Transformation

| Input | What it does | Output | What it represents |
|-------|-------------|--------|--------------------|
| `in_left[i]` | Routes to `PE_ctrl(i,0).in_x` as column `i` of A | — | One column of A (flattened) |
| `in_top[j]` | Routes to `PE_ctrl(0,j).in_y` as row `j` of B | — | One row of B (flattened) |
| `acc_clr` | Distributed to all PEs; synchronously zeros all accumulators | — | Pre-operation clear |
| `acc_en` | Distributed to all PEs; gates accumulation in lockstep | — | Enables/disables multiply-add |
| — | Each `PE_ctrl(i,j)` conditionally accumulates `Σ_k A[i][k] × B[k][j]` | `out_c[(i×N+j)]` | `C[i][j]` — one element of the result matrix |

After one CLEAR + N feeds + DRAIN sequence with the sequencer:
`out_c[(i×N+j)]` = `C[i][j]` = `Σ_k A[i][k] × B[k][j]`.

## Ports

| Port      | Direction | Width                        | Description                            |
|-----------|-----------|------------------------------|----------------------------------------|
| `clk`     | input     | 1                            | Clock                                  |
| `rst`     | input     | 1                            | Synchronous reset                      |
| `acc_clr` | input     | 1                            | Clear all PE accumulators (synchronous)|
| `acc_en`  | input     | 1                            | Enable all PE accumulators             |
| `in_left` | input     | `N × DATA_WIDTH`             | Flattened column inputs (A[:,k])       |
| `in_top`  | input     | `N × DATA_WIDTH`             | Flattened row inputs (B[k,:])          |
| `out_c`   | output    | `N × N × ACCUM_WIDTH`        | Flattened C matrix results             |

## Parameters

| Parameter     | Default | Description                          |
|---------------|---------|--------------------------------------|
| `N`           | 4       | Matrix dimension (N×N PEs)           |
| `DATA_WIDTH`  | 16      | Bit width of `x`/`y` operands        |
| `ACCUM_WIDTH` | 40      | Bit width of the accumulator/output  |

## Control Signal Timing

A typical matrix multiply sequence:

1. **CLEAR** (1 cycle): `acc_clr=1`, `acc_en=0` — all accumulators reset to 0
2. **LOAD** (2N cycles): `acc_clr=0`, `acc_en=1` — data feeds every 2 cycles, PEs accumulate
3. **DRAIN** (4N cycles): `acc_clr=0`, `acc_en=1` — no new data, PEs continue accumulating as last data propagates
4. **RDOUT** (1 cycle): `acc_clr=0`, `acc_en=0` — accumulators frozen; readout unit captures results
5. **DONE** (×): `acc_clr=0`, `acc_en=0` — operation complete, array idle

## Output Stationarity

When `acc_en=0` (RDOUT state), all PE accumulators freeze simultaneously. The full `out_c` bus holds the completed C matrix **indefinitely** in parallel. A subsequent `acc_clr` or new operation is required to change the values.

This means no serial shift-out or sequential readout is needed — the results are already available on `out_c` as a stable, parallel bus.

## When to Use

| Use case                              | Module                     |
|---------------------------------------|----------------------------|
| Simple one-shot multiply + reset      | `systolic_array_nxn`       |
| Sequenced multi-tile operations       | `systolic_array_nxn_ctrl`  |
| Any design with `execution_sequencer` | `systolic_array_nxn_ctrl`  |

## Keynotes

- `acc_clr` is **synchronous** and takes priority over `acc_en`. All PEs clear in lockstep.
- `acc_en` is AND-ed with the accumulator clock enable inside each `PE_ctrl`.
- The data path (`out_x`, `out_y`) always runs — control signals only gate accumulation.
- `psum_in` is tied to 0 for all PEs (accumulation is fully internal).
