# execution_sequencer — Matrix Multiply FSM Controller

## Overview

The execution sequencer is the central FSM that orchestrates a complete matrix multiply operation. It generates:

- **Data feed timing**: `data_valid` and `data_idx` pulses for the feed controls
- **Array control**: `acc_clr` and `acc_en` for the systolic array
- **Readout trigger**: a one-cycle `readout_trig` pulse to load the shifter
- **Shift control**: the SHIFT state lasts M cycles (runtime `matrix_size`) while rows stream out
- **Status**: `busy` and `done` flags

## Input → Output Transformation

| Input | What it does | Output | What it represents |
|-------|-------------|--------|--------------------|
| `start` | Rising edge initiates the FSM sequence from IDLE (or restarts from DONE_S) | — | Start a new matrix multiply |
| `matrix_size` | Latched at `start`, used as runtime tile dimension M | — | Overrides parameter N for LOAD/DRAIN/SHIFT duration |
| — | FSM counts load cycles; `data_valid` pulses every 2 cycles during LOAD | `data_valid` | Strobe for the feed control to latch the next A-column / B-row |
| — | FSM tracks the current feed index via `load_cycle / 2` | `data_idx` | Index k of the current feed (0 to M-1) |
| — | Asserted for 1 cycle in CLEAR state | `acc_clr` | Clear all PE accumulators |
| — | Asserted in LOAD and DRAIN states; deasserted elsewhere | `acc_en` | Enable PE accumulation gates |
| — | Asserted for 1 cycle in RDOUT state | `readout_trig` | Load shifter with PE results |
| — | Asserted from CLEAR through SHIFT | `busy` | Operation in progress |
| — | Asserted in DONE_S state | `done` | Operation complete, results ready |

## Ports

| Port | Direction | Width | Description |
|------|-----------|-------|-------------|
| `clk` | input | 1 | Clock |
| `rst` | input | 1 | Synchronous reset (returns to IDLE) |
| `start` | input | 1 | Start a new matrix multiply (level-sensitive) |
| `matrix_size` | input | [31:0] | Runtime tile dimension M (1..N); latched at `start` |
| `data_valid` | output | 1 | Pulse high (1 cycle) indicating a data feed cycle |
| `data_idx` | output | [31:0] | Index of the feed (0 to M-1) |
| `acc_clr` | output | 1 | Clear all PE accumulators (1 cycle pulse) |
| `acc_en` | output | 1 | Enable PE accumulation |
| `readout_trig` | output | 1 | Pulse high to load shifter from PE array |
| `busy` | output | 1 | High while operation in progress |
| `done` | output | 1 | High when operation complete |

## Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `N` | 4 | Physical array dimension (max tile size) |
| `DRAIN_CYCLES` | 0 | `0` = auto (`4×M`); otherwise fixed drain duration |

## State Machine

```
        ┌─────────────────────────────────────────────────────────────┐
        │                                                             │
        ▼                                                             │
   ┌────────┐   start   ┌────────┐        ┌────────┐                 │
   │  IDLE  ├──────────►│ CLEAR  ├───────►│  LOAD  │                 │
   └───┬────┘           └────────┘        └───┬────┘                 │
       │                                      │                      │
       │                              load_cycle == 2M               │
       │                                      │                      │
       │                               ┌──────▼──────┐               │
       │                               │    DRAIN    │               │
       │                               └──────┬──────┘               │
       │                              drain_cnt ==                   │
       │                              DRAIN_LIMIT                    │
       │                                      │                      │
       │                               ┌──────▼──────┐               │
       │                               │   RDOUT     │               │
       │                               └──────┬──────┘               │
       │                                      │                      │
       │                               ┌──────▼──────┐               │
       │                               │   SHIFT     │               │
       │                               └──────┬──────┘               │
       │                            shift_cnt == M-1               │
       │                                      │                      │
       │                               ┌──────▼──────┐               │
       │                               │   DONE_S    │               │
       │                               └──────┬──────┘               │
       │                           start       │                     │
       │                           ┌───────────┘                     │
       │                           ▼                                 │
       │                       ┌────────┐                            │
       │                       │ CLEAR  │ (restart)                  │
       │                       └────────┘                            │
       └─────────────────────────────────────────────────────────────┘
```

(M = runtime `matrix_size`, latched at `start`)

### State Descriptions

| State | Duration | `data_valid` | `acc_clr` | `acc_en` | `readout_trig` | `busy` | `done` |
|-------|----------|--------------|-----------|----------|----------------|--------|--------|
| IDLE | Until `start` | 0 | 0 | 0 | 0 | 0 | 0 |
| CLEAR | 1 cycle | 0 | **1** | 0 | 0 | 1 | 0 |
| LOAD | `2M` cycles | pulse[0..M-1] | 0 | **1** | 0 | 1 | 0 |
| DRAIN | `DRAIN_LIMIT` cycles | 0 | 0 | **1** | 0 | 1 | 0 |
| RDOUT | 1 cycle | 0 | 0 | 0 | **1** | 1 | 0 |
| SHIFT | `M` cycles | 0 | 0 | 0 | 0 | 1 | 0 |
| DONE_S | Until `start` | 0 | 0 | 0 | 0 | 0 | **1** |

### Restart from DONE_S

When `start` is asserted in DONE_S, the sequencer transitions directly to CLEAR (not IDLE), allowing a subsequent matrix multiply without deasserting `start` first. This is critical for ping-pong operation: after verifying Ping results, the testbench flips the base pointers and pulses `start` again while the sequencer is still in DONE_S.

## Data Feed Pattern

During LOAD, `data_valid` pulses every **2 cycles** on even `load_cycle` values (0, 2, 4, ..., 2M-2). Each pulse corresponds to one column-row pair:

- `data_idx = load_cycle / 2` → values 0, 1, ..., M-1
- `data_valid = (load_cycle % 2 == 0) && (load_cycle < 2*M)`

This gives the feed control one full clock cycle (from posedge to negedge) to drive the raw data from the buffers onto the array inputs before the skew buffer captures it on the next posedge.

## Runtime M vs Parameter N

The sequencer uses **runtime `matrix_size`** (M) for all state durations, not the Verilog parameter N. This allows the same hardware to process sub-tiles (M < N) without re-synthesis. M is latched into an internal `M` register at the posedge where `start` is asserted.

| Duration | Formula | Notes |
|----------|---------|-------|
| LOAD | `2M` cycles | data_valid on even cycles |
| DRAIN (auto) | `4M` cycles | pipeline drain |
| SHIFT | `M` cycles | one row per cycle |

## DRAIN Duration

The DRAIN state allows the last data fed into the array to propagate through the full pipeline.

```
DRAIN_LIMIT = (DRAIN_CYCLES == 0) ? (4 × M) : DRAIN_CYCLES
```

- **Auto mode** (`DRAIN_CYCLES=0`): `4×M` cycles — sufficient for all M up to at least 8
- **Manual mode**: override for specific timing requirements

## SHIFT Duration

The SHIFT state lasts exactly M cycles, matching the number of rows in the C tile. Each cycle, the readout shifter outputs one row. The output buffer captures one row per SHIFT cycle.

## Clear-To-Done Latency

Total cycles from `start` to `done`:

```
1 (CLEAR) + 2M (LOAD) + DRAIN_LIMIT (DRAIN) + 1 (RDOUT) + M (SHIFT) + 1 (DONE_S)
= 3 + 2M + DRAIN_LIMIT + M
= 3 + 3M + DRAIN_LIMIT
```

With auto mode (`DRAIN_LIMIT = 4M`):

```
L_total = 3 + 3M + 4M = 7M + 3
```

For M=4: 31 cycles. For M=8: 59 cycles.

## Output Timing Diagram (Conceptual)

```
clk      ─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─┬─
start    ─'_____________________________
state     IDL CLR LD LD LD LD ··· DR DR ··· DR RD SH SH SH DN
data_val  ___───___───___───___··················
acc_clr   _______───________________________________
acc_en    _______________───···───··········_______
rd_trig   ________________________________───______
busy      ________________________________───────────
done      ______________________________________________──
```

## Usage

```verilog
execution_sequencer #(
    .N(4),
    .DRAIN_CYCLES(0)   // auto → 4*M = 16 drain cycles for M=4
) seq (
    .clk(clk), .rst(rst), .start(start),
    .matrix_size(matrix_size),
    .data_valid(data_valid), .data_idx(data_idx),
    .acc_clr(acc_clr), .acc_en(acc_en),
    .readout_trig(readout_trig),
    .busy(busy), .done(done)
);
```
