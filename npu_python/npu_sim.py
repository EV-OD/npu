import numpy as np
from verilog_backend import verilog_matmul

OP_MATMUL = 0x0
OP_LOAD   = 0x1
OP_STORE  = 0x2
OP_LOOP   = 0x3
OP_JUMP   = 0x4
OP_BARRIER = 0xE
OP_NOP    = 0xF

OPCODES = {
    0x0: 'MATMUL', 0x1: 'LOAD', 0x2: 'STORE', 0x3: 'LOOP',
    0x4: 'JUMP', 0xE: 'BARRIER', 0xF: 'NOP',
}


def encode(opcode, **kw):
    w = opcode << 28
    if opcode == OP_MATMUL:
        w |= (kw.get('wt', 0) & 0xFF) << 20
        w |= (kw.get('act', 0) & 0xFF) << 12
        w |= (kw.get('out', 0) & 0xFF) << 4
    elif opcode in (OP_LOAD, OP_STORE):
        w |= (kw.get('dram_addr', 0) & 0xFFF) << 16
        w |= (kw.get('buf_tile', 0) & 0xFF) << 8
        w |= (kw.get('size', 0) & 0xF)
    elif opcode == OP_LOOP:
        w |= (kw.get('count', 0) & 0xFFF) << 16
        w |= (kw.get('target', 0) & 0xFF) << 8
        w |= (kw.get('stride', 0) & 0xFF)
    elif opcode == OP_JUMP:
        w |= (kw.get('target', 0) & 0xFFF) << 16
    return w


def decode(word):
    op = (word >> 28) & 0xF
    info = {'opcode': op, 'name': OPCODES.get(op, 'UNKNOWN')}
    if op == OP_MATMUL:
        info['wt_tile'] = (word >> 20) & 0xFF
        info['act_tile'] = (word >> 12) & 0xFF
        info['out_tile'] = (word >> 4) & 0xFF
    elif op in (OP_LOAD, OP_STORE):
        info['dram_addr'] = (word >> 16) & 0xFFF
        info['buf_tile'] = (word >> 8) & 0xFF
        info['size'] = word & 0xF
    elif op == OP_LOOP:
        info['count'] = (word >> 16) & 0xFFF
        info['target'] = (word >> 8) & 0xFF
        info['stride'] = word & 0xFF
    elif op == OP_JUMP:
        info['target'] = (word >> 16) & 0xFFF
    return info


Q_FACTOR = 256


class NPUSimulator:
    def __init__(self, n=4, num_tiles=64):
        self.N = n
        self.num_tiles = num_tiles
        self.tiles = {}
        self.dram = {}

        self.ibram = [0] * 128
        self.pc = 0
        self.in_loop = False
        self.loop_remaining = 0
        self.loop_body_target = 0

        self.stats = {'matmul': 0, 'cycles': 0, 'macs': 0}
        self.q_factor = Q_FACTOR

    def load_tile(self, tile_num, matrix):
        assert matrix.shape == (self.N, self.N), f'Tile must be {self.N}x{self.N}'
        self.tiles[tile_num] = matrix.astype(np.float64)

    def get_tile(self, tile_num):
        if tile_num not in self.tiles:
            self.tiles[tile_num] = np.zeros((self.N, self.N), dtype=np.float64)
        return self.tiles[tile_num]

    def load_ibram(self, addr, word):
        self.ibram[addr] = word

    def load_program(self, program):
        for addr, word in enumerate(program):
            self.ibram[addr] = word

    def matmul(self, wt_tile, act_tile, out_tile, trace=False):
        A = self.get_tile(wt_tile)
        B = self.get_tile(act_tile)
        C_out = self.get_tile(out_tile)

        if trace:
            print(f'\n  ╔══ MATMUL wt={wt_tile} × act={act_tile} → out={out_tile} ═══')
            print(f'  ║  Weight tile {wt_tile} (A):')
            for row in A:
                print(f'  ║    [{"  ".join(f"{v:6.1f}" for v in row)}]')
            print(f'  ║  Activation tile {act_tile} (B):')
            for row in B:
                print(f'  ║    [{"  ".join(f"{v:6.1f}" for v in row)}]')

        q = self.q_factor
        Aq = np.clip(np.round(A * q), -32768, 32767).astype(np.int32)
        Bq = np.clip(np.round(B * q), -32768, 32767).astype(np.int32)
        C_partial = verilog_matmul(Aq, Bq).astype(np.float64) / (q * q)

        self.tiles[out_tile] = C_out + C_partial
        self.stats['matmul'] += 1
        macs = self.N * self.N * self.N
        self.stats['macs'] += macs
        expected_cycles = 7 * self.N + 3
        self.stats['cycles'] += expected_cycles

        if trace:
            print(f'  ║  [Verilog RTL simulation]')
            print(f'  ║  Accumulated into tile {out_tile}:')
            result = self.tiles[out_tile]
            for row in result:
                print(f'  ║    [{"  ".join(f"{v:6.1f}" for v in row)}]')
            print(f'  ║  MACs: {macs}, Cycles: {expected_cycles}')
            print(f'  ╚═══════════════════════════════════════\n')

    def load_op(self, dram_addr, buf_tile, size):
        addr = dram_addr * self.N * self.N
        if addr in self.dram:
            self.tiles[buf_tile] = self.dram[addr].copy()
        self.stats['cycles'] += 12

    def store_op(self, dram_addr, buf_tile, size):
        addr = dram_addr * self.N * self.N
        if buf_tile in self.tiles:
            self.dram[addr] = self.tiles[buf_tile].copy()
        self.stats['cycles'] += 12

    def step(self):
        return decode(self.ibram[self.pc])

    def run(self, trace=False):
        self.pc = 0
        self.in_loop = False
        self.loop_remaining = 0
        limit = 10000
        steps = 0

        while steps < limit:
            word = self.ibram[self.pc]
            if word == 0:
                break
            info = decode(word)
            op = info['opcode']

            if trace:
                name = info['name']
                args = {k: v for k, v in info.items() if k not in ('opcode', 'name')}
                print(f'  [{self.pc:3d}] {name:8s} {args}')

            if op == OP_MATMUL:
                self.matmul(info['wt_tile'], info['act_tile'],
                            info['out_tile'], trace=trace)
                self.pc += 1
            elif op == OP_LOAD:
                self.load_op(info['dram_addr'], info['buf_tile'], info['size'])
                self.pc += 1
            elif op == OP_STORE:
                self.store_op(info['dram_addr'], info['buf_tile'], info['size'])
                self.pc += 1
            elif op == OP_LOOP:
                if not self.in_loop and info['count'] > 0:
                    self.loop_remaining = info['count'] - 1
                    self.loop_body_target = info['target']
                    self.in_loop = True
                    self.pc = info['target']
                elif self.in_loop and self.loop_remaining > 0:
                    self.loop_remaining -= 1
                    self.pc = self.loop_body_target
                else:
                    if self.in_loop:
                        self.in_loop = False
                    self.pc += 1
            elif op == OP_JUMP:
                self.pc = info['target']
            elif op == OP_BARRIER:
                self.pc += 1
            elif op == OP_NOP:
                self.pc += 1
            else:
                self.pc += 1

            steps += 1

        return self.stats
