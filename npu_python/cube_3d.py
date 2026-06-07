import numpy as np
import math
import time
import os
import sys
from npu_sim import NPUSimulator, encode, OP_MATMUL, OP_LOAD, OP_STORE, OP_NOP

CUBE_VERTS = np.array([
    [-1, -1, -1, 1], [ 1, -1, -1, 1], [ 1,  1, -1, 1], [-1,  1, -1, 1],
    [-1, -1,  1, 1], [ 1, -1,  1, 1], [ 1,  1,  1, 1], [-1,  1,  1, 1],
], dtype=np.float64).T

EDGES = [
    (0,1),(1,2),(2,3),(3,0),(4,5),(5,6),(6,7),(7,4),
    (0,4),(1,5),(2,6),(3,7),
]

TILE_ROT = 0
TILE_VERTS_A = 1
TILE_VERTS_B = 2
TILE_OUT_A = 3
TILE_OUT_B = 4
TILE_PROJ = 5

def rotation_matrix_x(angle):
    c, s = math.cos(angle), math.sin(angle)
    return np.array([
        [1, 0,  0, 0],
        [0, c, -s, 0],
        [0, s,  c, 0],
        [0, 0,  0, 1],
    ], dtype=np.float64)

def rotation_matrix_y(angle):
    c, s = math.cos(angle), math.sin(angle)
    return np.array([
        [ c, 0, s, 0],
        [ 0, 1, 0, 0],
        [-s, 0, c, 0],
        [ 0, 0, 0, 1],
    ], dtype=np.float64)

def perspective_projection(fov=90, aspect=1.0, near=0.1, far=10.0):
    f = 1.0 / math.tan(math.radians(fov) / 2)
    return np.array([
        [f/aspect, 0, 0, 0],
        [0, f, 0, 0],
        [0, 0, (far+near)/(near-far), 2*far*near/(near-far)],
        [0, 0, -1, 0],
    ], dtype=np.float64)


class NPUCubeRenderer:
    def __init__(self, n=4, width=60, height=30, use_verilog=False):
        self.npu = NPUSimulator(n=n, use_verilog=use_verilog, q_factor=256)
        self.width = width
        self.height = height
        self.angle = 0

        self.npu.load_tile(TILE_VERTS_A, CUBE_VERTS[:, 0:4])
        self.npu.load_tile(TILE_VERTS_B, CUBE_VERTS[:, 4:8])
        proj = perspective_projection(fov=90, aspect=width/height*0.5)
        self.npu.load_tile(TILE_PROJ, proj)

        program = [
            encode(OP_MATMUL, wt=TILE_ROT, act=TILE_VERTS_A, out=TILE_OUT_A),
            encode(OP_MATMUL, wt=TILE_ROT, act=TILE_VERTS_B, out=TILE_OUT_B),
            encode(OP_NOP),
        ]
        self.npu.load_program(program)

    def update_angle(self, angle):
        self.angle = angle
        rx = rotation_matrix_x(angle * 0.7)
        ry = rotation_matrix_y(angle * 0.5)
        rot = ry @ rx
        self.npu.load_tile(TILE_ROT, rot)

    def get_vertices_2d(self):
        self.npu.tiles[TILE_OUT_A] = np.zeros((4, 4), dtype=np.float64)
        self.npu.tiles[TILE_OUT_B] = np.zeros((4, 4), dtype=np.float64)

        self.npu.run(trace=False)

        out_a = self.npu.tiles[TILE_OUT_A]
        out_b = self.npu.tiles[TILE_OUT_B]

        verts_homo = np.hstack([out_a, out_b])

        verts_2d = []
        for i in range(8):
            x, y, z, w = verts_homo[:, i]
            if abs(w) < 1e-10:
                w = 1e-10
            sx = int(x / w * self.width * 0.4 + self.width // 2)
            sy = int(-y / w * self.height * 0.4 + self.height // 2)
            verts_2d.append((sx, sy))
        return verts_2d

    def render_frame(self):
        self.update_angle(self.angle)
        verts_2d = self.get_vertices_2d()

        screen = [[' '] * self.width for _ in range(self.height)]
        for v in verts_2d:
            x, y = v
            if 0 <= x < self.width and 0 <= y < self.height:
                screen[y][x] = 'O'

        for e in EDGES:
            x1, y1 = verts_2d[e[0]]
            x2, y2 = verts_2d[e[1]]
            self._draw_line(screen, x1, y1, x2, y2)

        return screen

    def _draw_line(self, screen, x0, y0, x1, y1):
        dx, dy = abs(x1 - x0), abs(y1 - y0)
        sx = 1 if x0 < x1 else -1
        sy = 1 if y0 < y1 else -1
        err = dx - dy
        while True:
            if 0 <= x0 < self.width and 0 <= y0 < self.height:
                if screen[y0][x0] == ' ':
                    screen[y0][x0] = '.'
            if x0 == x1 and y0 == y1:
                break
            e2 = 2 * err
            if e2 > -dy:
                err -= dy
                x0 += sx
            if e2 < dx:
                err += dx
                y0 += sy

    def animate(self, duration=10, fps=10):
        n_frames = duration * fps
        for frame in range(n_frames):
            self.angle = (frame / fps) * 0.5

            screen = self.render_frame()
            os.system('clear 2>/dev/null || cls 2>/dev/null || true')

            title = f'NPU-Accelerated 3D Cube  |  Frame {frame}  |  MATMULs: {self.npu.stats["matmul"]}'
            print('\033[36m' + title + '\033[0m')
            print('─' * self.width)
            for row in screen:
                print(''.join(row))

            info = f'Angle: {self.angle:.2f} rad  |  N={self.npu.N}x{self.npu.N} systolic array'
            print('─' * self.width)
            print('\033[33m' + info + '\033[0m')
            print(
                '\033[90m'
                'Instructions executed: MATMUL x wt_tile=0, act_tile=1/2, out_tile=3/4  |  '
                'Ctrl+C to exit'
                '\033[0m'
            )

            time.sleep(1.0 / fps)

    def render_static(self, angle=0.8):
        self.angle = angle
        screen = self.render_frame()
        for row in screen:
            print(''.join(row))
        print(f'\nNPU stats: {self.npu.stats}')
