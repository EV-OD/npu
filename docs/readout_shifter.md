# readout_shifter — Row-by-Row Shift Register

## Overview

The readout shifter sits between the systolic array and the readout unit. It parallel-loads all N×N accumulator values from the array when `load` pulses, then shifts them out one row per cycle over N cycles. This reduces the wide `pe_c` bus (N² × ACCUM_WIDTH) to a narrow `row_out` bus (N × ACCUM_WIDTH) for the readout unit.

## Input → Output Transformation

| Input | What it does | Output | What it represents |
|-------|-------------|--------|--------------------|
| `pe_c` | Parallel-captured into internal row registers on `load` posedge | `row_out` | One row of the C matrix per cycle (N elements) |
| `load` | Rising edge initiates capture and starts shift-out sequence | `row_valid` | High while `row_out` holds valid data |
| | | `shift_done` | Pulses high for 1 cycle after the last row is output |

## Ports

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `clk` | input | 1 | Clock |
| `rst` | input | 1 | Synchronous reset |
| `load` | input | 1 | Capture strobe — parallel-loads all N rows from `pe_c` |
| `pe_c` | input | `N × N × ACCUM_WIDTH` | Flattened accumulator values from systolic array |
| `row_out` | output | `N × ACCUM_WIDTH` | Current shift output row (combinational) |
| `row_valid` | output | 1 | High when `row_out` is valid (combinational) |
| `shift_done` | output | 1 | Pulses high for 1 cycle after all N rows shifted out |

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `N` | 4 | Matrix dimension |
| `ACCUM_WIDTH` | 40 | Bit width of each PE accumulator |

## Timing

```
clk       ─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─
load      _______───___________________
                          ^ load at this edge
row_out   ZZZZZZZZ[ row0 ][ row1 ][ row2 ]ZZZZZZ
row_valid ___________────────────______
shift_done _______________________───__
                          ^ N=3 → 3 rows output
```

After `load`:
- **Same posedge**: `pe_c` is captured into N internal row registers
- **Next posedge**: `row_out = row[0]`, `row_valid = 1`
- Each subsequent posedge: next row is output
- After N cycles: `shift_done` pulses, `row_valid` goes low

## Usage

```verilog
readout_shifter #(
    .N(4),
    .ACCUM_WIDTH(40)
) shift (
    .clk(clk), .rst(rst),
    .load(readout_trig),
    .pe_c(pe_c),
    .row_out(shift_row),
    .row_valid(shift_row_valid),
    .shift_done()
);
```
