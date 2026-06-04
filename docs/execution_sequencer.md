# execution_sequencer — Matrix Multiply FSM Controller

## Overview

The execution sequencer is the central FSM that orchestrates a complete matrix multiply operation. It generates:

- **Data feed timing**: `data_valid` and `data_idx` pulses for the external testbench/data source
- **Array control**: `acc_clr` and `acc_en` for the systolic array
- **Readout trigger**: a one-cycle `readout_trig` pulse
- **Status**: `busy` and `done` flags

## Input → Output Transformation

| Input | What it does | Output | What it represents |
|-------|-------------|--------|--------------------|
| `start` | Rising edge initiates the FSM sequence from IDLE | — | Start a new matrix multiply |
| — | FSM counts load cycles; `data_valid` pulses every 2 cycles during LOAD | `data_valid` | Strobe for the external source to drive the next A-column / B-row |
| — | FSM tracks the current feed index via `load_cycle / 2` | `data_idx` | Index k of the current feed (0 to N-1) |
| — | Asserted for 1 cycle in CLEAR state | `acc_clr` | Clear all PE accumulators |
| — | Asserted in LOAD and DRAIN states; deasserted elsewhere | `acc_en` | Enable PE accumulation gates |
| — | Asserted for 1 cycle in RDOUT state | `readout_trig` | Capture PE results into readout unit |
| — | Asserted from CLEAR through RDOUT | `busy` | Operation in progress |
| — | Asserted in DONE_S state | `done` | Operation complete, results ready |

## Ports

| Port           | Direction | Width    | Description                                      |
|----------------|-----------|----------|--------------------------------------------------|
| `clk`          | input     | 1        | Clock                                            |
| `rst`          | input     | 1        | Synchronous reset (returns to IDLE)              |
| `start`        | input     | 1        | Start a new matrix multiply (level-sensitive)     |
| `data_valid`   | output    | 1        | Pulse high (1 cycle) indicating a data feed cycle|
| `data_idx`     | output    | [31:0]   | Index of the feed (0 to N-1)                     |
| `acc_clr`      | output    | 1        | Clear all PE accumulators (1 cycle pulse)        |
| `acc_en`       | output    | 1        | Enable PE accumulation                           |
| `readout_trig` | output    | 1        | Pulse high to capture PE results                 |
| `busy`         | output    | 1        | High while operation in progress                 |
| `done`         | output    | 1        | High when operation complete                     |

## Parameters

| Parameter      | Default | Description                                        |
|----------------|---------|----------------------------------------------------|
| `N`            | 4       | Matrix dimension                                   |
| `DRAIN_CYCLES` | 0       | `0` = auto (`4×N`); otherwise fixed drain duration |

## State Machine

```
        ┌──────────────────────────────────────────────────┐
        │                                                  │
        ▼                                                  │
   ┌────────┐   start   ┌────────┐        ┌────────┐      │
   │  IDLE  ├──────────►│ CLEAR  ├───────►│  LOAD  │      │
   └───┬────┘           └────────┘        └───┬────┘      │
       │                                      │           │
       │                              load_cycle == 2N    │
       │                                      │           │
       │                               ┌──────▼──────┐    │
       │                               │    DRAIN    │    │
       │                               └──────┬──────┘    │
       │                              drain_cnt ==        │
       │                              DRAIN_LIMIT         │
       │                                      │           │
       │                               ┌──────▼──────┐    │
       │                               │   RDOUT     │    │
       │                               └──────┬──────┘    │
       │                                      │           │
       │                               ┌──────▼──────┐    │
       │                               │   DONE_S    │    │
       │                               └──────┬──────┘    │
       │                           !start      │          │
       └───────────────────────────────────────┘          │
                                                          │
```

### State Descriptions

| State    | Duration              | `data_valid` | `acc_clr` | `acc_en` | `readout_trig` | `busy` | `done` |
|----------|-----------------------|--------------|-----------|----------|----------------|--------|--------|
| IDLE     | Until `start`         | 0            | 0         | 0        | 0              | 0      | 0      |
| CLEAR    | 1 cycle               | 0            | **1**     | 0        | 0              | 1      | 0      |
| LOAD     | `2N` cycles           | pulse[0..N-1]| 0         | **1**    | 0              | 1      | 0      |
| DRAIN    | `DRAIN_LIMIT` cycles  | 0            | 0         | **1**    | 0              | 1      | 0      |
| RDOUT    | 1 cycle               | 0            | 0         | 0        | **1**          | 1      | 0      |
| DONE_S   | Until `!start`        | 0            | 0         | 0        | 0              | 0      | **1**  |

## Data Feed Pattern

During LOAD, `data_valid` pulses every **2 cycles** on even `load_cycle` values (0, 2, 4, ..., 2N-2). Each pulse corresponds to one column-row pair:

- `data_idx = load_cycle / 2` → values 0, 1, ..., N-1
- `data_valid = (load_cycle % 2 == 0) && (load_cycle < 2*N)`

This gives the external data source (`data_feed_active`) one full clock cycle (from posedge to negedge) to drive the raw data onto the array inputs before the skew buffer captures it on the next posedge.

## DRAIN Duration

The DRAIN state allows the last data fed into the array to propagate through the full pipeline (skew buffers + array propagation + PE pipeline) before results are captured.

```
DRAIN_LIMIT = (DRAIN_CYCLES == 0) ? (4 × N) : DRAIN_CYCLES
```

- **Auto mode** (`DRAIN_CYCLES=0`): `4×N` cycles — sufficient for all N up to at least 8
- **Manual mode**: override for specific timing requirements

## Clear-To-Done Latency

Total cycles from `start` to `done`:

```
1 (CLEAR) + 2N (LOAD) + DRAIN_LIMIT (DRAIN) + 1 (RDOUT) + 1 (DONE_S)
= 3 + 2N + DRAIN_LIMIT
```

## Output Timing Diagram (Conceptual)

```
clk      ─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─
start    ─'_____________________________
state     IDL CLR LD LD LD LD ··· DR DR ··· DR RD DN DN
data_val  ___───___───___───___··················
acc_clr   _______───________________________________
acc_en    _______________───···───··········_______
rd_trig   ________________________________───______
busy      ________________________________───_______
done      __________________________________________──
```

## Usage

```verilog
execution_sequencer #(
    .N(4),
    .DRAIN_CYCLES(0)   // auto → 4*N = 16 drain cycles
) seq (
    .clk(clk), .rst(rst), .start(start),
    .data_valid(data_valid), .data_idx(data_idx),
    .acc_clr(acc_clr), .acc_en(acc_en),
    .readout_trig(readout_trig),
    .busy(busy), .done(done)
);
```
