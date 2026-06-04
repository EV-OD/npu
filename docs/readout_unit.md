# readout_unit — Result Capture

## Overview

The readout unit captures the systolic array's N×N accumulator values in parallel when `trigger` pulses. Since the array outputs are **stationary** (PE registers hold results indefinitely once `acc_en` is deasserted), the parallel capture is the only readout mechanism needed.

## Input → Output Transformation

| Input | What it does | Output | What it represents |
|-------|-------------|--------|--------------------|
| `pe_c` | Sampled into `result` on `trigger` rising edge | `result` | Captured C matrix — all N×N accumulator values in parallel |
| `trigger` | Rising edge initiates capture | `valid` | High (and held) while `result` holds valid data |

On `trigger` posedge:
```
result <= pe_c
valid  <= 1
```

Both hold until the next `trigger` or `rst`.

## Ports

| Port      | Direction | Width                       | Description                             |
|-----------|-----------|-----------------------------|-----------------------------------------|
| `clk`     | input     | 1                           | Clock                                   |
| `rst`     | input     | 1                           | Synchronous reset                       |
| `trigger` | input     | 1                           | Capture strobe (rising edge)            |
| `pe_c`    | input     | `N × N × ACCUM_WIDTH`       | Flattened PE accumulator values         |
| `valid`   | output    | 1                           | High while parallel result is valid     |
| `result`  | output    | `N × N × ACCUM_WIDTH`       | Captured parallel result (C matrix)     |

## Parameters

| Parameter     | Default | Description                      |
|---------------|---------|----------------------------------|
| `N`           | 4       | Matrix dimension                 |
| `ACCUM_WIDTH` | 40      | Bit width of each PE accumulator |

## Timing

```
clk     ─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─
trigger ___───___________________
valid   _______───────────────────
result      XXXXXXXXXXXX[ C ]XXXXX
                        └── captured at this edge
```

The capture happens on the same posedge where `trigger` is high. Results are available on `result` and `valid` one delta cycle after the posedge.

## Output Stationarity

Since the systolic array's PE registers hold their accumulated values indefinitely once `acc_en` is deasserted (stationary output), the readout unit's parallel capture is a convenience layer — the results are already stable on the array's `pe_c` bus. The `result` register simply provides a latched copy that is insulated from future array operations.

## Usage

```verilog
readout_unit #(
    .N(4),
    .ACCUM_WIDTH(40)
) rdout (
    .clk(clk), .rst(rst),
    .trigger(readout_trig),
    .pe_c(pe_c),
    .valid(result_valid),
    .result(result)
);
```
