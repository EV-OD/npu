import pygame
import numpy as np
import math
import sys
from npu_sim import NPUSimulator, encode, OP_MATMUL, OP_NOP

CUBE_VERTS = np.array([
    [-1, -1, -1, 1], [ 1, -1, -1, 1], [ 1,  1, -1, 1], [-1,  1, -1, 1],
    [-1, -1,  1, 1], [ 1, -1,  1, 1], [ 1,  1,  1, 1], [-1,  1,  1, 1],
], dtype=np.float64).T

EDGES = [
    (0,1),(1,2),(2,3),(3,0),(4,5),(5,6),(6,7),(7,4),
    (0,4),(1,5),(2,6),(3,7),
]

FACES = [
    (0,1,2,3), (4,5,6,7), (0,1,5,4),
    (2,3,7,6), (0,3,7,4), (1,2,6,5),
]

TILE_ROT = 0
TILE_VERTS_A = 1
TILE_VERTS_B = 2
TILE_OUT_A = 3
TILE_OUT_B = 4

FACE_COLORS = [
    (255, 60, 60),   (60, 60, 255),
    (60, 255, 60),   (60, 255, 255),
    (255, 60, 255),  (255, 255, 60),
]


def rotation_matrix_x(angle):
    c, s = math.cos(angle), math.sin(angle)
    return np.array([
        [1, 0,  0, 0], [0, c, -s, 0],
        [0, s,  c, 0], [0, 0,  0, 1],
    ], dtype=np.float64)


def rotation_matrix_y(angle):
    c, s = math.cos(angle), math.sin(angle)
    return np.array([
        [ c, 0, s, 0], [ 0, 1, 0, 0],
        [-s, 0, c, 0], [ 0, 0, 0, 1],
    ], dtype=np.float64)


class NPUCubeGUI:
    def __init__(self, width=1000, height=750, use_verilog=False):
        pygame.init()
        self.width = width
        self.height = height
        self.screen = pygame.display.set_mode((width, height))
        pygame.display.set_caption('NPU-Accelerated 3D Cube  —  Systolic Array Matrix Multiply')
        self.clock = pygame.time.Clock()

        self.alpha_surf = pygame.Surface((width, height), pygame.SRCALPHA)
        self.hud_bg = pygame.Surface((280, height))
        self.hud_bg.set_alpha(200)
        self.hud_bg.fill((0, 0, 0))

        self.npu = NPUSimulator(n=4, use_verilog=use_verilog, q_factor=256)
        self.show_debug = True
        self.font_small = pygame.font.Font(None, 20)
        self.font_large = pygame.font.Font(None, 28)

        self.angle_x = 0
        self.angle_y = 0
        self.auto_rotate = True
        self.rot_speed = 0.02

        self.npu.load_tile(TILE_VERTS_A, CUBE_VERTS[:, 0:4])
        self.npu.load_tile(TILE_VERTS_B, CUBE_VERTS[:, 4:8])

        self.program = [
            encode(OP_MATMUL, wt=TILE_ROT, act=TILE_VERTS_A, out=TILE_OUT_A),
            encode(OP_MATMUL, wt=TILE_ROT, act=TILE_VERTS_B, out=TILE_OUT_B),
            encode(OP_NOP),
        ]
        self.npu.load_program(self.program)

    def update_rotation(self):
        rx = rotation_matrix_x(self.angle_x)
        ry = rotation_matrix_y(self.angle_y)
        self.npu.load_tile(TILE_ROT, ry @ rx)

    def get_transformed_verts(self):
        self.npu.tiles[TILE_OUT_A] = np.zeros((4, 4), dtype=np.float64)
        self.npu.tiles[TILE_OUT_B] = np.zeros((4, 4), dtype=np.float64)
        self.npu.run(trace=False)
        return np.hstack([self.npu.tiles[TILE_OUT_A], self.npu.tiles[TILE_OUT_B]])

    def project(self, verts_homo, center, scale):
        pts = []
        for i in range(8):
            x, y, z, w = verts_homo[:, i]
            if abs(w) < 1e-10:
                w = 1e-10
            sx = int(x / w * scale + center[0])
            sy = int(-y / w * scale + center[1])
            pts.append((sx, sy, z / w))
        return pts

    def is_front_face(self, pts, face):
        ax, ay = pts[face[1]][0] - pts[face[0]][0], pts[face[1]][1] - pts[face[0]][1]
        bx, by = pts[face[3]][0] - pts[face[0]][0], pts[face[3]][1] - pts[face[0]][1]
        return ax * by - ay * bx < 0

    def draw_cube(self, pts):
        self.alpha_surf.fill((0, 0, 0, 0))

        visible = []
        for i, face in enumerate(FACES):
            if self.is_front_face(pts, face):
                z = sum(pts[v][2] for v in face) / 4
                visible.append((z, i, face))

        visible.sort(key=lambda x: x[0], reverse=True)

        for z, i, face in visible:
            poly = [(pts[v][0], pts[v][1]) for v in face]
            col = FACE_COLORS[i]
            pygame.draw.polygon(self.alpha_surf, (*col, 60), poly)
            pygame.draw.polygon(self.alpha_surf, (*col, 160), poly, 2)

        self.screen.blit(self.alpha_surf, (0, 0))
        self.alpha_surf.fill((0, 0, 0, 0))

        for edge in EDGES:
            for w, a in [(4, 40), (2, 90), (1, 200)]:
                pygame.draw.line(self.alpha_surf, (180, 220, 255, a),
                                 (pts[edge[0]][0], pts[edge[0]][1]),
                                 (pts[edge[1]][0], pts[edge[1]][1]), w)

        self.screen.blit(self.alpha_surf, (0, 0))

        for pt in pts:
            pygame.draw.circle(self.screen, (255, 255, 255),
                               (int(pt[0]), int(pt[1])), 4)
            pygame.draw.circle(self.screen, (140, 180, 220),
                               (int(pt[0]), int(pt[1])), 2)

    def draw_hud(self):
        self.screen.blit(self.hud_bg, (0, 0))

        lines = [
            ('NPU SIMULATOR', self.font_large, (100, 200, 255)),
            ('', None, None),
            (f'Array:  {self.npu.N}x{self.npu.N} systolic', self.font_small, (200, 200, 200)),
            (f'Tile:   {self.npu.N}x{self.npu.N} matrices', self.font_small, (200, 200, 200)),
            (f'Tiles:  {len(self.npu.tiles)} loaded', self.font_small, (200, 200, 200)),
            ('', None, None),
            ('INSTRUCTIONS', self.font_large, (100, 200, 255)),
            ('', None, None),
            ('  MATMUL  wt=0, act=1 -> out=3', self.font_small, (200, 200, 200)),
            ('  MATMUL  wt=0, act=2 -> out=4', self.font_small, (200, 200, 200)),
            ('', None, None),
            ('NPU STATS', self.font_large, (100, 200, 255)),
            ('', None, None),
            (f'MATMULs: {self.npu.stats["matmul"]}', self.font_small, (200, 200, 200)),
            (f'Cycles:  {self.npu.stats["cycles"]}', self.font_small, (200, 200, 200)),
            (f'FPS:     {int(self.clock.get_fps())}', self.font_small, (200, 200, 200)),
            ('', None, None),
            ('TILE 0 (Rotation)', self.font_large, (100, 200, 255)),
        ]

        y = 20
        for text, font, color in lines:
            if text == '':
                y += 8
                continue
            s = font.render(text, True, color)
            self.screen.blit(s, (15, y))
            y += font.get_height() + 2

        rot = self.npu.tiles.get(TILE_ROT)
        if rot is not None:
            for r in range(4):
                row_text = '  '.join(f'{rot[r, c]:6.2f}' for c in range(4))
                s = self.font_small.render(row_text, True, (180, 180, 180))
                self.screen.blit(s, (15, y))
                y += 18

        y += 8
        controls = [
            ('CONTROLS', self.font_large, (100, 200, 255)),
            ('', None, None),
            ('Space:  toggle auto-rotate', self.font_small, (200, 200, 200)),
            ('R:      reset rotation', self.font_small, (200, 200, 200)),
            ('D:      toggle debug', self.font_small, (200, 200, 200)),
            ('Esc:    quit', self.font_small, (200, 200, 200)),
        ]
        for text, font, color in controls:
            if text == '':
                y += 8
                continue
            s = font.render(text, True, color)
            self.screen.blit(s, (15, y))
            y += font.get_height() + 2

    def handle_events(self):
        for event in pygame.event.get():
            if event.type == pygame.QUIT:
                return False
            if event.type == pygame.KEYDOWN:
                if event.key in (pygame.K_ESCAPE, pygame.K_q):
                    return False
                if event.key == pygame.K_SPACE:
                    self.auto_rotate = not self.auto_rotate
                if event.key == pygame.K_r:
                    self.angle_x = 0
                    self.angle_y = 0
                if event.key == pygame.K_d:
                    self.show_debug = not self.show_debug

        keys = pygame.key.get_pressed()
        if not self.auto_rotate:
            self.angle_y += (keys[pygame.K_RIGHT] - keys[pygame.K_LEFT]) * 0.03
            self.angle_x += (keys[pygame.K_DOWN] - keys[pygame.K_UP]) * 0.03

        return True

    def run(self):
        running = True
        center = (self.width // 2 + 100, self.height // 2)
        scale = min(self.width, self.height) * 0.35

        while running:
            running = self.handle_events()

            if self.auto_rotate:
                self.angle_y += self.rot_speed
                self.angle_x += self.rot_speed * 0.3

            self.update_rotation()
            verts_homo = self.get_transformed_verts()
            pts = self.project(verts_homo, center, scale)

            self.screen.fill((10, 10, 20))

            for x in range(0, self.width, 30):
                for y in range(0, self.height, 30):
                    b = 15 + int(10 * math.sin(x * 0.01 + y * 0.01 + self.angle_y))
                    self.screen.set_at((x, y), (b, b, b + 10))

            self.draw_cube(pts)

            if self.show_debug:
                self.draw_hud()

            pygame.display.flip()
            self.clock.tick(60)

        pygame.quit()


def main(use_verilog=False):
    gui = NPUCubeGUI(width=1000, height=750, use_verilog=use_verilog)
    gui.run()


if __name__ == '__main__':
    main()
