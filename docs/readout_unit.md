# readout_unit — Result Capture

## Overview

The readout unit receives one row of the C matrix per cycle from the `readout_shifter`. It collects all N rows into an internal buffer, then outputs the full N×N result matrix in parallel once all rows have arrived.

## Input → Output Transformation

| Input | What it does | Output | What it represents |
|-------|-------------|--------|--------------------|
| `shift_valid` | Each pulse indicates a valid row on `row_in` | `result` | Captured C matrix — all N×N accumulator values in parallel |
| `row_in` | One row (N elements) captured each cycle | `valid` | High (and held) while `result` holds valid data |

On each `shift_valid` posedge:
```
rows[row_idx] <= row_in
row_idx <= row_idx + 1
```

When `row_idx == N-1` (last row):
```
result <= assemble(rows[0..N-2], row_in)
valid  <= 1
row_idx <= 0
```

## Ports

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `clk` | input | 1 | Clock |
| `rst` | input | 1 | Synchronous reset |
| `shift_valid` | input | 1 | Row strobe from shifter — active for N cycles |
| `row_in` | input | `N × ACCUM_WIDTH` | One row of C from shifter |
| `valid` | output | 1 | High while full parallel result is valid |
| `result` | output | `N × N × ACCUM_WIDTH` | Captured parallel result (full C matrix) |

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `N` | 4 | Matrix dimension |
| `ACCUM_WIDTH` | 40 | Bit width of each PE accumulator |

## Timing

```
clk          ─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─
shift_valid  _______─────────_______
                          ^ row input pulses
row_in       XXXX[ row0 ][ row1 ][ row2 ]XXXX
valid        ___________________________───
result       XXXXXXXXXXXXXXXXXXXXXXXXXXX[ C ]XX
                                       └── assembled at this edge
```

## Output Stationarity

Once assembled, `result` holds until the next readout operation. Since `pe_c` is captured by the shipper before the readout unit starts collecting rows, the array outputs can be released while the shift-out is in progress.

## Usage

```verilog
readout_unit #(
    .N(4),
    .ACCUM_WIDTH(40)
) rdout (
    .clk(clk), .rst(rst),
    .shift_valid(shift_row_valid),
    .row_in(shift_row),
    .valid(result_valid),
    .result(result)
);
```
