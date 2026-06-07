# Python–Verilog Cosimulation Bridge

The NPU simulator runs MATMUL on *actual compiled RTL* — not a Python
emulation. The bridge compiles `src/*.v` with `iverilog`, drives the
simulation with real data via `vvp`, and parses the result.

## Architecture

```
 cube_gui.py / cube_3d.py
         │
         ▼
    NPUSimulator        ← Verilog-only backend
         │
         └─► verilog_backend.verilog_matmul()
                  │
                  ├── quantize A,B to int16
                  ├── write tb_A.hex, tb_B.hex
                  ├── iverilog → tb_cosim.vvp
                  ├── vvp → parse stdout
                  └── dequantize result → float64
```

## Data Flow

### 1. Quantization (Python)

The `NPUSimulator` uses `q_factor=256` (Q8.8 fixed-point). Float tiles are
scaled before RTL execution and dequantized afterward:

```python
Aq = np.clip(np.round(A * q_factor), -32768, 32767).astype(np.int32)
Bq = np.clip(np.round(B * q_factor), -32768, 32767).astype(np.int32)
Cq = verilog_matmul(Aq, Bq)            # integer MAC in RTL
C  = Cq / (q_factor * q_factor)         # restore scale
```

### 2. Hex File I/O

Quantized matrices are written as 16-bit hex files (row-major order, one
value per line):

```
tb_A.hex:         A[0][0]  A[0][1] … A[3][3]
tb_B.hex:         B[0][0]  B[0][1] … B[3][3]
```

### 3. Testbench (`tb_cosim.v`)

The generated testbench:
- Reads `$readmemh("tb_A.hex", A)` and `$readmemh("tb_B.hex", B)`
- Preloads the feed buffers via the `npu_exec_unit` ports:
  - A is stored **column-major**: `addr = row + col×N`
  - B is stored **row-major**: `addr = row×N + col`
- Asserts `start`, waits for `done`, then dumps the result matrix to
  stdout between `RESULT_MATRIX` / `END_RESULT` markers

### 4. Compilation & Execution

```python
comp = subprocess.run(['iverilog', '-g2012',
    '-I', str(SRC_DIR), '-o', vvp_path, tb_file] + src_paths)
sim  = subprocess.run(['vvp', str(vvp_path)], cwd=tmpdir)
```

Compilation is cached to `/tmp/tb_cosim.vvp`. The backend checks
timestamps and auto-rebuilds when any source file or the testbench
changes.

### 5. Result Parsing

The `RESULT_MATRIX` / `END_RESULT` block is parsed with a regex:

```
C[0][0] = 90
C[0][1] = 100
...
```

## RTL Execution Pipeline

All files are in `src/`:

```
npu_exec_unit.v              ← top wrapper
├── execution_sequencer.v    ← FSM: CLEAR→LOAD(8cyc)→DRAIN(16cyc)→RDOUT→SHIFT→DONE
├── feed_buffer.v ×2        ← dual-port SRAM (A col-major, B row-major)
├── skew_buffer.v ×2        ← shift-register, row i delayed by 2i cycles
├── systolic_array_nxn_ctrl.v ← 4×4 PE array
│   └── PE_ctrl.v ×16       ← MAC: x×y + accumulator, with acc_clr/acc_en
├── readout_shifter.v       ← parallel capture, serial shift-out of PE results
└── readout_unit.v          ← assembles full C matrix from shifted rows
```

### Feed Cycle (every-other-cycle bubble)

```
Cycle  even (k=0):  feed A[:,0], B[0,:]     data_valid=1
       odd:         bubble                   data_valid=0
       even (k=1):  feed A[:,1], B[1,:]     data_valid=1
       ...
```

### Pipeline Delays per PE

Each PE contributes 2-cycle delay per dimension:
- x propagates right: 2 cycles × column index
- y propagates down:  2 cycles × row index
- Skew buffers add 2 cycles × row/column index

Total: `2i + 2j + 1` cycles from feed to product in PE(i,j).

## Verification (Sabotage Test)

To confirm the bridge executes *actual RTL* and not a Python proxy:

```bash
# Baseline — correct multiplication
$ python3 -c "from verilog_backend import verilog_matmul; print(verilog_matmul(...))"
[[10. 12. ...]]                # A × B

# Sabotage — change * to + in PE_ctrl.v
$ sed -i 's/x_reg \* y_reg/x_reg + y_reg/' src/PE_ctrl.v
$ python3 -c "..."             # force recompile
[[30. 34. ...]]                # completely different

# Restore
$ sed -i 's/x_reg + y_reg/x_reg * y_reg/' src/PE_ctrl.v
$ python3 -c "..."
[[10. 12. ...]]                # correct again
```

## File Map

| File | Role |
|------|------|
| `npu_python/verilog_backend.py` | Python bridge (hex I/O, compile, run, parse) |
| `npu_python/npu_sim.py` | `NPUSimulator` (Verilog-only backend) |
| `src/npu_exec_unit.v` | Full execution unit wrapper |
| `src/PE_ctrl.v` | Individual PE (multiply-accumulate) |
| `src/execution_sequencer.v` | FSM controlling LOAD/DRAIN/RDOUT |
| `src/feed_buffer.v` | Matrix data storage (dual-ported SRAM) |
| `src/skew_buffer.v` | Input skew delay per row |
| `src/systolic_array_nxn_ctrl.v` | 4×4 PE array with control |
| `src/readout_shifter.v` / `src/readout_unit.v` | Result capture chain |
