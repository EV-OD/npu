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

    integer i, j, fd, seq, expected_seq;
    reg [8*40:1] hexname;
    reg signed [DATA_WIDTH-1:0] A [0:N-1][0:N-1];
    reg signed [DATA_WIDTH-1:0] B [0:N-1][0:N-1];

    initial begin
        clk = 0; rst = 1;
        start = 0; a_we = 0; b_we = 0;
        repeat (2) @(posedge clk);
        rst = 0;
        @(posedge clk);

        expected_seq = 0;

        while (1) begin
            // Wait for go.signal with matching sequence number
            fd = 0;
            while (fd == 0) begin
            fd = $fopen("go.signal", "r");
            if (fd) begin
                seq = -1;
                if ($fscanf(fd, "%d", seq) != 1)
                    seq = -1;
                $fclose(fd);
                if (seq != expected_seq) begin
                    fd = 0;
                    #1000;
                end
            end else begin
                    #1000;
                end
            end

            $swrite(hexname, "tb_A_%0d.hex", expected_seq);
            $readmemh(hexname, A);
            $swrite(hexname, "tb_B_%0d.hex", expected_seq);
            $readmemh(hexname, B);

            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin
                    @(negedge clk);
                    a_we <= 1; a_waddr <= i + j * N; a_din <= A[i][j];
                end

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

            @(posedge done);
            @(posedge clk);

            $display("RESULT_MATRIX %0d", expected_seq);
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1)
                    $display("C[%0d][%0d] = %0d", i, j,
                        $signed(result_data[((i * N + j) * ACCUM_WIDTH) +: ACCUM_WIDTH]));
            $display("END_RESULT %0d", expected_seq);
            $fflush();

            expected_seq = expected_seq + 1;
        end
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
        self._seq = 0
        self._proc = None
        self._buf = ''
        self._ensure_compiled()
        self._start_vvp()

    def _start_vvp(self):
        self._proc = subprocess.Popen(
            ['vvp', str(_VVP_PATH)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            cwd=str(_HEX_DIR), text=True, bufsize=1
        )

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

    def _read_until(self, marker):
        while marker not in self._buf:
            if self._proc.stdout.closed:
                raise RuntimeError('vvp stdout closed')
            line = self._proc.stdout.readline()
            if not line:
                raise RuntimeError('vvp stdout stream ended')
            self._buf += line
        idx = self._buf.find(marker)
        result = self._buf[:idx + len(marker)]
        self._buf = self._buf[idx + len(marker):]
        return result

    def matmul(self, A, B):
        N = A.shape[0]
        seq = self._seq
        self._write_hex(f'tb_A_{seq}.hex', A.flatten())
        self._write_hex(f'tb_B_{seq}.hex', B.flatten())

        go_path = _HEX_DIR / 'go.signal'
        go_path.write_text(f'{seq}\n')

        end_marker = f'END_RESULT {seq}'
        all_output = self._read_until(end_marker)

        C = np.zeros((N, N), dtype=np.float64)
        in_result = False
        for line in all_output.splitlines():
            line = line.strip()
            if line.startswith('RESULT_MATRIX'):
                in_result = True
                continue
            if line.startswith('END_RESULT'):
                break
            if in_result:
                m = re.match(r'C\[(\d+)\]\[(\d+)\]\s*=\s*(-?\d+)', line)
                if m:
                    i, j, val = int(m.group(1)), int(m.group(2)), int(m.group(3))
                    if 0 <= i < N and 0 <= j < N:
                        C[i, j] = float(val)

        self._seq += 1
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

    def close(self):
        if self._proc:
            try:
                go_path = _HEX_DIR / 'go.signal'
                go_path.write_text(f'-1\n')
                self._proc.wait(timeout=5)
            except Exception:
                self._proc.kill()
            self._proc = None


_session = None


def verilog_matmul(A, B):
    global _session
    if _session is None:
        _session = _VerilogSession()
    return _session.matmul(A, B)
