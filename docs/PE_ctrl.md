# PE_ctrl — Controlled Processing Element

## Overview

`PE_ctrl` extends the basic `PE` with two control signals: `acc_clr` (synchronous clear) and `acc_en` (accumulator enable). Data forwarding (`out_x`, `out_y`) always runs; only the accumulator is gated. This allows the external sequencer to precisely control when accumulation starts, stops, and resets.

## Input → Output Transformation

| Input | What it does | Output | What it represents |
|-------|-------------|--------|--------------------|
| `in_x` | Sampled into `x_reg` each cycle; driven to `out_x` one cycle later | `out_x` | `in_x` delayed by 1 cycle (forwarded to right neighbor) |
| `in_y` | Sampled into `y_reg` each cycle; driven to `out_y` one cycle later | `out_y` | `in_y` delayed by 1 cycle (forwarded to bottom neighbor) |
| `in_x × in_y` | Multiplied result stored in `product_reg`; then **conditionally** added to `accumulator` based on `acc_en` and `acc_clr` | `out_c` | `accumulator + psum_in` — the gated dot-product sum for `C[i][j]` |
| `acc_clr` | When high, synchronously zeros `accumulator` (takes priority over `acc_en`) | — | Clears the running sum |
| `acc_en` | When high and `acc_clr=0`, enables accumulation; when low, accumulator freezes | — | Gates the add operation |
| `psum_in` | Added combinatorially to `accumulator` for `out_c` | — | Unused in this design (tied to 0) |

Over successive feeds (k = 0, 1, ..., N-1) with `acc_en=1`:

```
out_c = Σ_k in_x(k) × in_y(k)
```

## Ports

| Port      | Direction | Width              | Description                                      |
|-----------|-----------|--------------------|--------------------------------------------------|
| `clk`     | input     | 1                  | Clock                                             |
| `rst`     | input     | 1                  | Synchronous reset                                 |
| `acc_clr` | input     | 1                  | Clear accumulator to 0 (synchronous, takes priority over `acc_en`) |
| `acc_en`  | input     | 1                  | Enable accumulation                               |
| `in_x`    | input     | `DATA_WIDTH`       | Input activation                                  |
| `in_y`    | input     | `DATA_WIDTH`       | Input weight                                      |
| `psum_in` | input     | `ACCUM_WIDTH`      | Partial sum (unused, tied 0)                      |
| `out_x`   | output    | `DATA_WIDTH`       | Registered `in_x` forwarded right                 |
| `out_y`   | output    | `DATA_WIDTH`       | Registered `in_y` forwarded down                  |
| `out_c`   | output    | `ACCUM_WIDTH`      | Accumulator + `psum_in`                           |

## Parameters

| Parameter     | Default | Description                     |
|---------------|---------|---------------------------------|
| `DATA_WIDTH`  | 16      | Bit width of `x`/`y` operands   |
| `ACCUM_WIDTH` | 40      | Bit width of the accumulator    |

## Acc Logic

```verilog
if (acc_clr)
    accumulator <= 0;
else if (acc_en)
    accumulator <= accumulator + product_reg;
// else: accumulator holds
```

Priority: `acc_clr` > `acc_en` > hold.

## Pipeline Timing

Same as `PE` for data forwarding. Accumulator update is identical to `PE` when `acc_en=1`; when `acc_en=0`, the accumulator freezes and `out_c` reflects the frozen value.

| Cycle | `acc_en=1`                              | `acc_en=0`                       |
|-------|------------------------------------------|----------------------------------|
| T     | `x_reg <= in_x`, `y_reg <= in_y`         | (same)                           |
| T+1   | `product_reg <= x_reg × y_reg`           | (same)                           |
| T+2   | `accumulator <= accumulator + product_reg` | accumulator unchanged          |
| T+3   | `out_c` shows updated accumulator        | `out_c` shows unchanged value    |

## Output Stationarity

When `acc_en=0`, the accumulator freezes and `out_c` holds its value **indefinitely** until the next `acc_clr` or `acc_en=1` cycle. This makes `PE_ctrl` suitable for sequenced operations where results must be read out while the array is idle.

## Key Difference from PE

| Feature              | `PE`                  | `PE_ctrl`            |
|----------------------|-----------------------|----------------------|
| `acc_clr`            | No                    | Yes                  |
| `acc_en`             | Always 1              | Controllable         |
| Accumulator behavior | Free-running add      | Gated add            |
| Output stationarity  | Changes every cycle   | Frozen when `acc_en=0` |

## Usage

`PE_ctrl` is the building block of `systolic_array_nxn_ctrl` and is required when:

- **Multiple matrix tiles** need to be processed sequentially (clear between tiles)
- **Pipeline drain** requires accumulation to continue after data stops (acc_en stays high)
- **Readout** requires freezing the accumulator (acc_en low) while capturing results
