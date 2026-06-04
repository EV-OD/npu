# readout_unit — Result Capture and Serial Shift-Out

## Overview

The readout unit captures the systolic array's `N×N` accumulator values in parallel when `trigger` pulses, and optionally shifts them out serially one word per clock. It provides two output modes:

- **Parallel mode** (`shift_mode=0`): holds the full `N×N×ACCUM_WIDTH` result on `result` with `valid=1`
- **Serial mode** (`shift_mode=1`): after parallel capture, shifts out one `ACCUM_WIDTH` word per cycle on `shift_out` with `shift_valid` strobe; asserts `shift_done` when complete

## Ports

| Port           | Direction | Width                       | Description                                    |
|----------------|-----------|-----------------------------|------------------------------------------------|
| `clk`          | input     | 1                           | Clock                                          |
| `rst`          | input     | 1                           | Synchronous reset                              |
| `trigger`      | input     | 1                           | Capture strobe (rising edge)                   |
| `shift_mode`   | input     | 1                           | `0` = parallel hold, `1` = serial shift-out    |
| `pe_c`         | input     | `N × N × ACCUM_WIDTH`       | Flattened PE accumulator values                |
| `valid`        | output    | 1                           | High while parallel result is valid            |
| `result`       | output    | `N × N × ACCUM_WIDTH`       | Captured parallel result                       |
| `shift_valid`  | output    | 1                           | Strobe for each word during serial shift-out   |
| `shift_out`    | output    | `ACCUM_WIDTH`               | Serial output word                             |
| `shift_done`   | output    | 1                           | Asserted after last word is shifted            |

## Parameters

| Parameter     | Default | Description                        |
|---------------|---------|------------------------------------|
| `N`           | 4       | Matrix dimension                   |
| `ACCUM_WIDTH` | 40      | Bit width of each PE accumulator   |

## Mode Selection

### Parallel Mode (`shift_mode=0`)

1. On `trigger` posedge: `result <= pe_c`, `valid <= 1`
2. `result` and `valid` hold until next `trigger` or `rst`
3. `shift_valid`, `shift_out`, `shift_done` remain 0

### Serial Mode (`shift_mode=1`)

1. On `trigger` posedge: same parallel capture; additionally starts shifting
2. First word (`pe_c[0 +: ACCUM_WIDTH]`) appears immediately on `shift_out` with `shift_valid=1`
3. Each following posedge: next word (in index order 0, 1, ..., N×N-2, N×N-1) is output with `shift_valid=1`
4. After the last word: `shift_done <= 1`, `shift_valid <= 0`, `shifting` deasserted

## Serial Output Order

Words are shifted out in **row-major** order: `PE(0,0)`, `PE(0,1)`, ..., `PE(0,N-1)`, `PE(1,0)`, ...

Index mapping: `word[k] = result[k × ACCUM_WIDTH +: ACCUM_WIDTH]` for `k = 0, 1, ..., N×N-1`.

## Timing Diagram (Serial Mode)

```
clk      ─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─
trigger  ___───___________________________
shift_val ______───┬───┬───┬───···───┬____
shift_out    X  w0│ w1│ w2│ w3│     │wN²-1│
                   └───┴───┴───┴───···───┘
shift_done________________________________───
valid     _________───···────────────────────
```

## Latency

- **Parallel capture**: 1 cycle (result ready on posedge after trigger)
- **Serial shift-out**: `N×N` cycles for all words; total `N×N + 1` cycles from trigger to `shift_done`

## Re-triggering

If `trigger` is asserted while a serial shift-out is in progress (`shifting=1`):

1. The current shift-out is **aborted**
2. New capture: `result <= pe_c`
3. New shift-out begins from word 0

This allows back-to-back matrix multiplications without waiting for the serial shift to complete.

## Usage

```verilog
readout_unit #(
    .N(4),
    .ACCUM_WIDTH(40)
) rdout (
    .clk(clk), .rst(rst),
    .trigger(readout_trig), .shift_mode(1'b0),
    .pe_c(pe_c),
    .valid(result_valid), .result(result),
    .shift_valid(), .shift_out(), .shift_done()
);
```
