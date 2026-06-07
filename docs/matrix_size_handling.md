# Matrix Size Handling

The NPU implements a fixed **4×4** systolic array (`N=4`). This document
explains how it handles matrices smaller than 4×4 at runtime and how larger
matrices can be decomposed via tiling.

## Physical Array

The `systolic_array_nxn_ctrl` instantiates a 4×4 grid of `PE_ctrl`
cells. Each PE holds a `DATA_WIDTH`-bit (16-bit signed) multiplier and a
40-bit accumulator. The array computes one 4×4 product in:
```
cycles = 1 (CLEAR) + 2N (LOAD) + 4N (DRAIN) + 1 (RDOUT) + N (SHIFT)
       = 1 + 8 + 16 + 1 + 4 = 30 cycles  (for N=4)
```
At a 100 MHz clock this is 300 ns per matmul.

## Smaller Matrices (M < 4)

The `matrix_size` runtime parameter (`M`, 1..4) tells the execution
sequencer how many columns of A / rows of B to consume.  The sequencer
still uses the full 4×4 feed-buffer storage, but only drives `2M` LOAD
cycles and `4M` DRAIN cycles.  The valid result occupies the top-left
`M×M` submatrix of the 40-bit output word; the remaining entries are
don't-cares.

### Example: 2×2

```
A = [[1, 2],      B = [[5, 6],
     [3, 4]]           [7, 8]]

A padded to 4×4:          B padded to 4×4:
  ┌             ┐           ┌             ┐
  │ 1  2  0  0 │           │ 5  6  0  0 │
  │ 3  4  0  0 │           │ 7  8  0  0 │
  │ 0  0  0  0 │           │ 0  0  0  0 │
  │ 0  0  0  0 │           │ 0  0  0  0 │
  └             ┘           └             ┘

Sequencer with M=2:
  LOAD:  2M = 4 cycles → raddr = 0, 0, 1, 1  (only columns 0,1)
  DRAIN: 4M = 8 cycles

NPU output (4×4):            Result (2×2):
  ┌             ┐             ┌         ┐
  │19 22  ?  ? │             │19  22   │
  │43 50  ?  ? │      →      │43  50   │
  │ ?  ?  ?  ? │             └         ┘
  │ ?  ?  ?  ? │
  └             ┘
```

Python extracts `C[:M, :M]` from the 4×4 result.  The remaining 16
elements (`?`) are uninitialised and must be discarded.

### 1×1 Example

```
A = [[7]],  B = [[3]]
M = 1
LOAD cycles = 2 (raddr = 0, 0)
DRAIN cycles = 4
C[0,0] = 7 × 3 = 21
```

## Larger Matrices (M > 4)

Matrices larger than 4×4 are **not supported natively**.  They must be
decomposed into 4×4 tiles, computed on the NPU, and accumulated in
Python (using numpy for the add).  The NPU provides the tile-level
multiply-add; Python orchestrates the outer product.

### Tiling Formula

For `A [M×K]` and `B [K×N]`, decompose into 4×4 blocks:

```
A = ┌                   ┐      B = ┌                   ┐
    │ A00  A01  …  A0t  │          │ B00  B01  …  B0u  │
    │ A10  A11  …  A1t  │          │ B10  B11  …  B1u  │
    │  …    …    …   …  │          │  …    …    …   …  │
    │ As0  As1  …  Ast  │          │ Bt0  Bt1  …  Btu  │
    └                   ┘          └                   ┘

Cij = Σₖ Aik @ Bkj      (for k = 0..K/4)
```

Each `@` is an NPU 4×4 matmul.  Partial products are summed in
Python (64-bit float accumulators).

### 8×8 Example

```
A = 8×8,  B = 8×8
Tiles:  2 row-tiles × 2 col-tiles = 4 tiles per matrix

A00 = A[0:4, 0:4]    A01 = A[0:4, 4:8]
A10 = A[4:8, 0:4]    A11 = A[4:8, 4:8]

B00 = B[0:4, 0:4]    B01 = B[0:4, 4:8]
B10 = B[4:8, 0:4]    B11 = B[4:8, 4:8]

C00 = A00@B00 + A01@B10    (2 NPU calls + numpy add)
C01 = A00@B01 + A01@B11    (2 NPU calls)
C10 = A10@B00 + A11@B10    (2 NPU calls)
C11 = A10@B01 + A11@B11    (2 NPU calls)

Total: 8 NPU matmuls
```

Python pseudocode:
```python
def matmul_tiled(A, B, tile_n=4):
    M, K = A.shape
    K2, N = B.shape
    C = np.zeros((M, N))
    for i in range(0, M, tile_n):
        for j in range(0, N, tile_n):
            acc = np.zeros((tile_n, tile_n))
            for k in range(0, K, tile_n):
                a_tile = A[i:i+tile_n, k:k+tile_n]
                b_tile = B[k:k+tile_n, j:j+tile_n]
                acc += verilog_matmul(a_tile, b_tile)
            C[i:i+tile_n, j:j+tile_n] = acc
    return C
```

Each `verilog_matmul` call quantises the float tile to Q8.8 int16,
runs it through `vvp`, and dequantises back to float.  The outer loop
accumulates in float64 so precision is maintained across tiles.

### Cost

| Matrix size | NPU matmuls | Python overhead |
|-------------|-------------|-----------------|
| 4×4         | 1           | negligible      |
| 8×8         | 8           | ~0.1 ms         |
| 16×16       | 64          | ~0.5 ms         |
| 32×32       | 512         | ~5 ms           |

The Python tiling overhead is dominated by the NPU call latency (~7 ms
per matmul with streaming vvp), not by the numpy tile arithmetic.

## Summary

| Size   | Mechanism                        | Cycles              |
|--------|----------------------------------|---------------------|
| M < 4  | Runtime `matrix_size` param      | 1 + 2M + 4M + 1 + M |
| M = 4  | Direct hardware matmul           | 30                  |
| M > 4  | Python tiling + NPU tile matmuls | 30 × (M/4)³         |
