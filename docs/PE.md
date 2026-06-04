# PE — Basic Processing Element

## Overview

`PE` is the fundamental compute tile in the systolic array. It performs a signed multiply-accumulate (MAC) operation on every clock cycle: `accumulator += in_x * in_y`. It also forwards `in_x` and `in_y` to neighboring PEs with a one-cycle register delay, enabling data to ripple through the array.

## Input → Output Transformation

| Input | What it does | Output | What it represents |
|-------|-------------|--------|--------------------|
| `in_x` | Sampled into `x_reg` each cycle; `x_reg` is driven to `out_x` one cycle later | `out_x` | `in_x` delayed by 1 cycle (forwarded to right neighbor) |
| `in_y` | Sampled into `y_reg` each cycle; `y_reg` is driven to `out_y` one cycle later | `out_y` | `in_y` delayed by 1 cycle (forwarded to bottom neighbor) |
| `in_x × in_y` | Multiplied result stored in `product_reg`; then added to `accumulator` | `out_c` | `accumulator + psum_in` — the running dot-product sum for `C[i][j]` |
| `psum_in` | Added combinatorially to `accumulator` for `out_c` | — | Unused in this design (tied to 0) |

Over successive feeds (k = 0, 1, ..., N-1), the PE accumulates:

```
out_c = Σ_k in_x(k) × in_y(k)
```

## Ports

| Port      | Direction | Width              | Description                                      |
|-----------|-----------|--------------------|--------------------------------------------------|
| `clk`     | input     | 1                  | Clock, all logic sampled on rising edge          |
| `rst`     | input     | 1                  | Synchronous reset; zeros all registers            |
| `in_x`    | input     | `DATA_WIDTH`       | Input activation (flows left→right)              |
| `in_y`    | input     | `DATA_WIDTH`       | Input weight (flows top→bottom)                  |
| `psum_in` | input     | `ACCUM_WIDTH`      | Partial sum from west neighbor (unused, tied 0)  |
| `out_x`   | output    | `DATA_WIDTH`       | Registered `in_x` forwarded to right neighbor    |
| `out_y`   | output    | `DATA_WIDTH`       | Registered `in_y` forwarded to bottom neighbor   |
| `out_c`   | output    | `ACCUM_WIDTH`      | Accumulator + `psum_in` sent to top-level output |

## Parameters

| Parameter     | Default | Description                     |
|---------------|---------|---------------------------------|
| `DATA_WIDTH`  | 16      | Bit width of `x`/`y` operands   |
| `ACCUM_WIDTH` | 40      | Bit width of the accumulator    |

## Internal Architecture

```
         ┌───────────┐
in_x ───►│   x_reg   ├──► out_x
         └─────┬─────┘
               │
         ┌─────▼─────┐
         │    *      │
in_y ───►│   y_reg   ├───┬─► out_y
         └─────┬─────┘   │
               │         │
         ┌─────▼─────┐   │
         │ product   │   │
         │   reg     │   │
         └─────┬─────┘   │
               │         │
         ┌─────▼─────┐   │
psum_in──► accumulator├──▼───► out_c
         └───────────┘
```

All paths are **fully registered**:

1. A 16×16 signed multiplier
2. A 40-bit accumulator (saturating accumulation)
3. Pipeline registers for `x`, `y`, and product

## Pipeline Timing

| Cycle | Event                                      |
|-------|--------------------------------------------|
| T     | `in_x`, `in_y` sampled into `x_reg`, `y_reg` |
| T+1   | `product_reg <= x_reg × y_reg`             |
| T+2   | `accumulator <= accumulator + product_reg`; `out_c <= old_accumulator + psum_in` |
| T+3   | `out_c` reflects the updated accumulator   |

Data forwarding (`out_x`, `out_y`) is delayed by **exactly one cycle**: `out_x` at T+1 equals `in_x` at T. This creates a systolic pipeline where data moves one PE per clock.

## Output Stationarity

`out_c` is a **registered output** — it holds its value until the next clock edge updates it. Once accumulation stops (no more `in_x`/`in_y` changes), `out_c` remains stable. For the controlled variant (`PE_ctrl`), `acc_en=0` also freezes the accumulator, making `out_c` stationary indefinitely.

## DSP Usage

The `accumulator` register is annotated with `(* use_dsp = "yes" *)` to guide synthesis tools to infer a DSP block.

## Limitations

- **Always accumulating**: There is no `acc_clr` or `acc_en` — the accumulator runs freely. For controlled operation use `PE_ctrl`.
- **No overflow protection**: The accumulator width (40 bits) is chosen so that worst-case N=8 sum of 16×16 products (max 64 terms × ±2^15×2^15 = ±2^30 each → needs ~36 bits) does not overflow; 40 bits provides comfortable margin.
