# systolic_array_nxn_ctrl — Controlled N×N Systolic Array

## Overview

Identical topology to `systolic_array_nxn` but instantiates `PE_ctrl` instead of `PE`. Two additional control signals (`acc_clr`, `acc_en`) are distributed to every PE in the array, allowing the external sequencer to:

1. **Clear all accumulators** before starting a new matrix multiply
2. **Enable accumulation** during the load and drain phases
3. **Freeze accumulators** for readout

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
