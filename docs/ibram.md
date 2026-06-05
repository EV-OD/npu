# IBRAM — Instruction Buffer RAM

## Overview

The IBRAM (`ibram.v`) is a double-buffered instruction memory that holds up to 2 × SLOT_DEPTH 32-bit instructions. It provides a continuous instruction stream to the dispatch unit while the DMA fills the inactive slot. The instruction output is registered on the **negedge** of the clock so that it is stable when the dispatch unit samples it at the next posedge.

## Parameters

| Parameter    | Default | Description                              |
|--------------|---------|------------------------------------------|
| `DATA_WIDTH` | 32      | Instruction width (from `INST_WIDTH`)    |
| `SLOT_DEPTH` | 64      | Number of 32-bit instructions per slot   |

Total capacity: 2 × SLOT_DEPTH × DATA_WIDTH = 4,096 bits at default.

## Ports

| Port          | Width | Direction | Description                                  |
|---------------|-------|-----------|----------------------------------------------|
| `clk`         | 1     | I         | Clock                                        |
| `rst`         | 1     | I         | Synchronous reset                            |
| `dma_en`      | 1     | I         | DMA qualifier (must be 1 for writes)         |
| `dma_we`      | 1     | I         | DMA write strobe                             |
| `dma_addr`    | A*    | I         | DMA write address (absolute: 0..2×SLOT_DEPTH)|
| `dma_din`     | 32    | I         | DMA write data (instruction word)            |
| `pc_en`       | 1     | I         | PC read enable (from dispatch)               |
| `pc_addr`     | B**   | I         | PC address (slot-local: 0..SLOT_DEPTH-1)     |
| `pc_dout`     | 32    | O         | Instruction at `pc_addr` (negedge-registered)|
| `active_slot` | 1     | O         | Currently active slot (0=A, 1=B)             |
| `ready`       | 1     | O         | Inactive slot is fully loaded (back-buffer)  |
| `swap`        | 1     | I         | Swap active slot (from dispatch, 1 cycle)    |

\* A = `$clog2(2*SLOT_DEPTH)` (default: 8 bits for 128 total addresses).
\*\* B = `$clog2(SLOT_DEPTH)` (default: 6 bits for 64 slot-local addresses).

## Memory Organization

```
Address range          Slot
0 .. SLOT_DEPTH-1      A (active slot)
SLOT_DEPTH .. 2*SLOT_DEPTH-1  B (back slot)
```

The DMA address space is flat (0 to 2*SLOT_DEPTH-1). The PC address is **slot-local** — the slot selection is done by `active_slot`:

```verilog
if (active_slot == 0)
    pc_dout <= mem[pc_addr];             // Slot A
else
    pc_dout <= mem[SLOT_DEPTH + pc_addr]; // Slot B
```

## Internal Registers

| Register       | Width | Description                                |
|----------------|-------|--------------------------------------------|
| `mem`          | × 2*SLOT_DEPTH | Dual-ported SRAM (write-port, read-port) |
| `slot_a_full`  | 1     | Slot A fully loaded by DMA                 |
| `slot_b_full`  | 1     | Slot B fully loaded by DMA                 |
| `active_slot`  | 1     | Output register, toggled by swap           |

## DMA Write

Writes occur on posedge when both `dma_en` and `dma_we` are asserted:

```verilog
if (dma_en && dma_we)
    mem[dma_addr] <= dma_din;
```

`dma_last_a` is asserted when the last address of slot A is written:
```verilog
dma_last_a = (dma_addr[$clog2(SLOT_DEPTH)-1:0] == SLOT_DEPTH-1) && (dma_addr[$clog2(SLOT_DEPTH)] == 0);
```

Similarly for `dma_last_b` (bit `clog2(SLOT_DEPTH)` == 1). When the last word is written, the corresponding `slot_*_full` flag is asserted:

```verilog
if (dma_en && dma_we) begin
    if (dma_last_a) slot_a_full <= 1;
    if (dma_last_b) slot_b_full <= 1;
end
```

## Instruction Fetch (Negedge Read)

The instruction is read at negedge, not at posedge:

```verilog
always @(negedge clk) begin
    if (pc_en) begin
        if (active_slot == 0)
            pc_dout <= mem[pc_addr];
        else
            pc_dout <= mem[SLOT_DEPTH + pc_addr];
    end
end
```

This ensures `pc_dout` is stable when the dispatch unit samples it at the next posedge (DECODE_W state).

### Timing

```
Cycle:   0         1         2
     +--+---+---+---+---+---+---+
clk    |   |   |   |   |   |   |
     +--+---+---+---+---+---+---+
                    |
pc_en           ____/````
                    |
negedge          ^  (pc_dout updates here)
                    |
pc_dout         XXXX=======instr=======
                    |
posedge          ^  (dispatch samples pc_dout at DECODE_W)
```

## Slot Full Tracking and Swap

### Full Flag Management

The full flags are set when DMA writes the last address. They are cleared when `swap` toggles `active_slot` away from that slot (the slot is now the back-buffer being consumed).

```verilog
if (swap) begin
    active_slot <= ~active_slot;
    if (active_slot == 0) slot_a_full <= 0;  // Slot A is now active, clear B's full flag
    else                  slot_b_full <= 0;  // Slot B is now active, clear A's full flag
end
```

### Ready Signal

`ready` indicates that the **inactive** (back) slot is fully loaded:

```verilog
ready <= (active_slot == 0) ? slot_b_full : slot_a_full;
```

This tells the dispatch unit that it is safe to swap. After a swap, the now-active slot was previously the back-slot, so `ready` transitions to reflect the new back-slot's status.

### Swap Cycle

```
Cycle:   0         1         2
     +--+---+---+---+---+---+---+
clk    |   |   |   |   |   |   |
     +--+---+---+---+---+---+---+
                    |
swap            ____/````
                    |
active_slot     XXX===old===X===new===
    (slot A)       |  (slot B)
                    |
ready          (was slot_b_full)  (now slot_a_full)
```

## Reset

On `rst=1` (synchronous):
- `slot_a_full <= 0`, `slot_b_full <= 0`
- `active_slot <= 0`
- `ready <= 0`

## Integration

Connected in `system.v` to:
- `u_dispatch` — `pc_en`, `pc_addr` (from dispatch), `pc_dout` (to dispatch), `swap` (from dispatch)
- DMA/ctrl interface — `dma_en`, `dma_we`, `dma_addr`, `dma_din` (from testbench/external controller)
