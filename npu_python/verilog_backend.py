import subprocess
import re
import numpy as np
from pathlib import Path

SRC_DIR = Path(__file__).resolve().parent.parent / 'src'

TB_CONTENT = '''`timescale 1ns / 1ps

module tb_cosim;

    parameter N = 4;
    parameter DATA_WIDTH = 16;
    parameter ACCUM_WIDTH = 40;

    reg clk, rst;
    reg start;
    wire busy, done;
    wire result_valid;
    wire [(N*N*ACCUM_WIDTH)-1:0] result_data;

    reg a_we, b_we;
    reg [$clog2(2*N*N)-1:0] a_waddr, b_waddr;
    reg signed [DATA_WIDTH-1:0] a_din, b_din;

    npu_exec_unit #(
        .N(N), .DATA_WIDTH(DATA_WIDTH), .ACCUM_WIDTH(ACCUM_WIDTH)
    ) u_exec (
        .clk(clk), .rst(rst),
        .start(start), .matrix_size(N),
        .busy(busy), .done(done),
        .a_we(a_we), .a_waddr(a_waddr), .a_din(a_din),
        .b_we(b_we), .b_waddr(b_waddr), .b_din(b_din),
        .result_valid(result_valid), .result_data(result_data)
    );

    always #5 clk = ~clk;

    integer i, j;
    reg signed [DATA_WIDTH-1:0] A [0:N-1][0:N-1];
    reg signed [DATA_WIDTH-1:0] B [0:N-1][0:N-1];

    initial begin
        clk = 0; rst = 1;
        start = 0; a_we = 0; b_we = 0;

        $readmemh("tb_A.hex", A);
        $readmemh("tb_B.hex", B);

        repeat (2) @(posedge clk);
        rst = 0;
        @(posedge clk);

        // Preload A (stored column-major: addr = col + row*N)
        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1) begin
                @(negedge clk);
                a_we <= 1; a_waddr <= i + j * N; a_din <= A[i][j];
            end

        // Preload B (stored row-major: addr = row*N + col)
        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1) begin
                @(negedge clk);
                b_we <= 1; b_waddr <= i * N + j; b_din <= B[i][j];
            end

        @(negedge clk);
        a_we <= 0; b_we <= 0;

        @(posedge clk);
        start <= 1;
        @(posedge clk);
        start <= 0;

        wait(done);
        @(posedge clk);

        $display("RESULT_MATRIX");
        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1)
                $display("C[%0d][%0d] = %0d", i, j,
                    $signed(result_data[((i * N + j) * ACCUM_WIDTH) +: ACCUM_WIDTH]));
        $display("END_RESULT");
        $finish;
    end

endmodule
'''

SRC_FILES = [
    'npu_exec_unit.v',
    'execution_sequencer.v',
    'feed_buffer.v',
    'skew_buffer.v',
    'systolic_array_nxn_ctrl.v',
    'PE_ctrl.v',
    'readout_shifter.v',
    'readout_unit.v',
    'output_buffer.v',
]

_VVP_PATH = Path('/tmp/tb_cosim.vvp')
_HEX_DIR = Path('/tmp')


class _VerilogSession:
    def __init__(self):
        self._ensure_compiled()

    def _ensure_compiled(self):
        tb_file = _HEX_DIR / 'tb_cosim.v'
        need_rebuild = not _VVP_PATH.exists()

        if not need_rebuild and _VVP_PATH.exists():
            vvp_mtime = _VVP_PATH.stat().st_mtime
            tb_mtime = tb_file.stat().st_mtime if tb_file.exists() else 0
            if tb_mtime > vvp_mtime:
                need_rebuild = True
            for f in SRC_FILES:
                src_path = SRC_DIR / f
                if src_path.exists() and src_path.stat().st_mtime > vvp_mtime:
                    need_rebuild = True
                    break

        if need_rebuild:
            tb_file.write_text(TB_CONTENT)
            src_paths = [str(SRC_DIR / f) for f in SRC_FILES]
            comp = subprocess.run(
                ['iverilog', '-g2012', '-I', str(SRC_DIR),
                 '-o', str(_VVP_PATH), str(tb_file)] + src_paths,
                capture_output=True, text=True, timeout=30
            )
            if comp.returncode != 0:
                raise RuntimeError(f'iverilog failed:\n{comp.stderr}')

    def matmul(self, A, B):
        N = A.shape[0]
        self._write_hex('tb_A.hex', A.flatten())
        self._write_hex('tb_B.hex', B.flatten())

        sim = subprocess.run(
            ['vvp', str(_VVP_PATH)],
            capture_output=True, text=True, timeout=30,
            cwd=str(_HEX_DIR)
        )

        C = np.zeros((N, N), dtype=np.float64)
        in_result = False
        for line in sim.stdout.splitlines():
            line = line.strip()
            if line == 'RESULT_MATRIX':
                in_result = True
                continue
            if line == 'END_RESULT':
                break
            if in_result:
                m = re.match(r'C\[(\d+)\]\[(\d+)\]\s*=\s*(-?\d+)', line)
                if m:
                    i, j, val = int(m.group(1)), int(m.group(2)), int(m.group(3))
                    if 0 <= i < N and 0 <= j < N:
                        C[i, j] = float(val)
        return C

    def _write_hex(self, name, data):
        path = _HEX_DIR / name
        lines = []
        for val in data:
            iv = int(round(val))
            iv = max(-32768, min(32767, iv))
            u = iv & 0xFFFF
            lines.append(f'{u:04x}')
        path.write_text('\n'.join(lines) + '\n')


_session = None


def verilog_matmul(A, B):
    global _session
    if _session is None:
        _session = _VerilogSession()
    return _session.matmul(A, B)
