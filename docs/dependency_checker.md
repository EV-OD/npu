# Dependency Checker

## Overview

The dependency checker (`dependency_checker.v`) manages a **64-entry tile lock table** to prevent structural hazards on systolic array tiles. Before an instruction is dispatched, it atomically checks whether all required tiles are free and locks them if so. After execution completes, the tiles are released (unlocked). This ensures sequential ordering at tile granularity.

The implementation uses a **packed `reg` array** (`locked_tiles[0:NUM_TILES-1]`) with helper functions (`is_locked`, `all_free`, `first_conflict`) and tasks (`lock_tile`, `release_tile`).

## Parameters

| Parameter   | Default | Description               |
|-------------|---------|---------------------------|
| `NUM_TILES` | 64      | Number of tiles (max 256) |

## Ports

| Port                | Width | Direction | Description                                |
|---------------------|-------|-----------|--------------------------------------------|
| `clk`               | 1     | I         | Clock                                      |
| `rst`               | 1     | I         | Synchronous reset                          |
| `check_lock_en`     | 1     | I         | Assert to initiate check-and-lock          |
| `chk_tile_a`        | 8     | I         | Primary tile to check                      |
| `chk_tile_b`        | 8     | I         | Secondary tile (optional)                  |
| `chk_tile_c`        | 8     | I         | Tertiary tile (optional)                   |
| `chk_num_tiles`     | 2     | I         | Number of tiles to check (1, 2, or 3)      |
| `check_lock_grant`  | 1     | O         | All tiles were free and are now locked     |
| `conflict_tile`     | 8     | O         | First conflicting tile (0 if none/granted) |
| `release_en`        | 1     | I         | Assert to release tiles                    |
| `release_tile_a`    | 8     | I         | Primary tile to release                    |
| `release_tile_b`    | 8     | I         | Secondary tile to release                  |
| `release_tile_c`    | 8     | I         | Tertiary tile to release                   |
| `release_num_tiles` | 2     | I         | Number of tiles to release (1, 2, or 3)    |
| `lock_status`       | 64    | O         | Combinatorial readout: `lock_status[i] = locked_tiles[i]` |

## Internal State

| Register         | Width | Description                              |
|------------------|-------|------------------------------------------|
| `locked_tiles`   | 64 × 1 | Packed array: `locked_tiles[t] = 1` if locked |

Implemented as `reg locked_tiles [0:NUM_TILES-1]` (unpacked array).

## Behavioral Logic

### Check-and-Lock

At every posedge (non-reset):

```verilog
check_lock_grant <= 0;  // default
conflict_tile    <= 0;  // default

if (check_lock_en) begin
    if (all_free(chk_tile_a, chk_tile_b, chk_tile_c, chk_num_tiles)) begin
        check_lock_grant <= 1;
        lock_tile(chk_tile_a);
        if (chk_num_tiles >= 2) lock_tile(chk_tile_b);
        if (chk_num_tiles >= 3) lock_tile(chk_tile_c);
    end else begin
        conflict_tile <= first_conflict(chk_tile_a, chk_tile_b, chk_tile_c, chk_num_tiles);
    end
end
```

The lock task immediately updates `locked_tiles` (blocking assignment inside the always block):
```verilog
task lock_tile(input [7:0] t);
    if (t < NUM_TILES)
        locked_tiles[t] = 1;  // blocking, immediate effect
endtask
```

Similarly for release:
```verilog
if (release_en) begin
    release_tile(release_tile_a);
    if (release_num_tiles >= 2) release_tile(release_tile_b);
    if (release_num_tiles >= 3) release_tile(release_tile_c);
end
```

### Helper Functions

```verilog
function is_locked(input [7:0] t);
    is_locked = (t < NUM_TILES) && locked_tiles[t];
endfunction

function all_free(input [7:0] a, b, c, input [1:0] n);
    all_free = 1;
    if (n >= 1 && is_locked(a)) all_free = 0;
    if (n >= 2 && is_locked(b)) all_free = 0;
    if (n >= 3 && is_locked(c)) all_free = 0;
endfunction

function [7:0] first_conflict(input [7:0] a, b, c, input [1:0] n);
    first_conflict = 0;
    if (n >= 1 && is_locked(a))      first_conflict = a;
    else if (n >= 2 && is_locked(b)) first_conflict = b;
    else if (n >= 3 && is_locked(c)) first_conflict = c;
endfunction
```

### Lock Status Readout

Combinatorial readout of the entire lock table:
```verilog
always @(*) begin
    for (i = 0; i < NUM_TILES; i = i + 1)
        lock_status[i] = locked_tiles[i];
end
```

## Timing

### Grant Latency

The dispatch unit stays in CHECK for a minimum of **3 cycles**:

```
Cycle:      T       T+1     T+2     T+3     T+4
state:   DECODE_W CHECK   CHECK   CHECK   DISPATCH
                |       |       |       |
dep_check_en    |   <=1/   <=1/   <=1/   | (re-asserted each CHECK cycle)
                |       |       |       |
check_lock_en   |   ___/````___/````___/|
(dep's view)    |       |       |       |
                |       |       |       |
check_lock_grant|       |   <=1 | (NBA) |
(internal NBA)  |       |       |       |
                |       |       |       |
dep_grant       |       0       0       1
(dispatch view) |       |       |       |
nxt:            CHECK   CHECK   CHECK   DISPATCH
```

1. Cycle T: dispatch exits DECODE_W, `state <= CHECK` (NBA).
2. Cycle T+1: main block reads state=CHECK, asserts `dep_check_en <= 1` (NBA for T+1). dep_checker reads `check_lock_en=0` (old value), no action.
3. Cycle T+2: `dep_check_en=1` (committed from T+1's NBA). Main block re-asserts `dep_check_en <= 1`. dep_checker processes: all_free → `check_lock_grant <= 1` (NBA for T+2), `locked_tiles[t] = 1` (immediate).
4. Cycle T+3: `check_lock_grant=1` (committed). nxt reads `dep_grant=1`, transitions to DISPATCH. `state <= DISPATCH` (NBA).

**Total: 3 CHECK cycles from state entry to state exit.**

### Conflict Stall

If tiles are locked on cycle T+2, the dispatch stays in CHECK and re-asserts `dep_check_en`. It re-evaluates `dep_grant` each cycle. When the conflicting instruction releases its tiles, the grant is issued on the next cycle.

### Release Latency

```
Cycle:      R       R+1     R+2
state:   RELEASE  FETCH   FETCH
                |       |       |
release_en      |   <=1/       |
locked_tiles    |   =0  |(imm) |
```

The release takes effect immediately within the same cycle (blocking task). A subsequent check in the *same* cycle would see the tile free (`all_free` would return true). However, since the dispatch pipeline is sequential (RELEASE → FETCH), the next check is at least 1 cycle later.

## Reset

On `rst=1` (synchronous), all tiles are unlocked:
```verilog
for (i = 0; i < NUM_TILES; i = i + 1)
    locked_tiles[i] <= 0;
check_lock_grant <= 0;
conflict_tile <= 0;
```

## Integration

Instantiated in `system.v` as `u_dep`. Connected to:
- `u_dispatch` — check/release enables and tile numbers
- Top-level output `lock_status` for debug/testbench readout
