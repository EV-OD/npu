import pygame
import numpy as np
from npu_sim import NPUSimulator

# ── Tile constants ──────────────────────────────────────────────

TILE_INPUT = 0
TILE_W1    = 1
TILE_H1    = 2
TILE_W2    = 3
TILE_H2    = 4
TILE_W3    = 5
TILE_OUT   = 6

# ── Colors ──────────────────────────────────────────────────────

BG       = (12, 12, 24)
GRID_LN  = (25, 25, 45)
CLASS_0  = (255, 80, 80)
CLASS_1  = (80, 140, 255)
CLASS_0_BG = (50, 10, 10)
CLASS_1_BG = (10, 20, 50)
WHITE    = (220, 220, 220)


# ── Load trained model ──────────────────────────────────────────

def load_model(path='nn_model.npz'):
    data = np.load(path)
    return {
        'W1': data['W1'], 'b1': data['b1'],
        'W2': data['W2'], 'b2': data['b2'],
        'W3': data['W3'], 'b3': data['b3'],
        'mean': data['mean'], 'std': data['std'],
    }


# ── NPU forward pass ────────────────────────────────────────────

class NPUNN:
    def __init__(self, model_path='nn_model.npz'):
        m = load_model(model_path)
        self.W1 = m['W1']; self.b1 = m['b1']
        self.W2 = m['W2']; self.b2 = m['b2']
        self.W3 = m['W3']; self.b3 = m['b3']
        self.mean = m['mean']; self.std = m['std']

        self.npu = NPUSimulator(n=4)
        self.npu.load_tile(TILE_W1, self.W1)
        self.npu.load_tile(TILE_W2, self.W2)
        W3T = np.zeros((4, 4))
        W3T[:2, :] = self.W3.T
        self.npu.load_tile(TILE_W3, W3T)

    def forward(self, x, y):
        xn = (x - self.mean[0]) / self.std[0]
        yn = (y - self.mean[1]) / self.std[1]

        inp = np.zeros((4, 4))
        inp[0, 0] = xn
        inp[1, 0] = yn
        inp[2, 0] = 1.0
        self.npu.tiles[TILE_INPUT] = inp

        b1_mat = np.tile(self.b1.reshape(4, 1), (1, 4))
        self.npu.tiles[TILE_H1] = b1_mat
        self.npu.matmul(TILE_W1, TILE_INPUT, TILE_H1)
        h1 = np.maximum(0, self.npu.tiles[TILE_H1][:, 0])

        h1_mat = np.zeros((4, 4))
        h1_mat[:, 0] = h1
        b2_mat = np.tile(self.b2.reshape(4, 1), (1, 4))
        self.npu.tiles[TILE_H2] = b2_mat
        self.npu.tiles[TILE_INPUT] = h1_mat
        self.npu.matmul(TILE_W2, TILE_INPUT, TILE_H2)
        h2 = np.maximum(0, self.npu.tiles[TILE_H2][:, 0])

        h2_mat = np.zeros((4, 4))
        h2_mat[:, 0] = h2
        b3_mat = np.zeros((4, 4))
        b3_mat[:2, 0] = self.b3
        self.npu.tiles[TILE_OUT] = b3_mat
        self.npu.tiles[TILE_INPUT] = h2_mat
        self.npu.matmul(TILE_W3, TILE_INPUT, TILE_OUT)
        logits = self.npu.tiles[TILE_OUT][:2, 0]

        e = np.exp(logits - np.max(logits))
        probs = e / (np.sum(e) + 1e-15)
        return probs

    # Fast numpy forward pass for boundary visualization (no Verilog)
    def forward_np(self, x, y):
        xn = (x - self.mean[0]) / self.std[0]
        yn = (y - self.mean[1]) / self.std[1]
        xp = np.array([xn, yn, 1.0, 0.0])
        h1 = np.maximum(0, self.W1 @ xp + self.b1)
        h2 = np.maximum(0, self.W2 @ h1 + self.b2)
        logits = self.W3.T @ h2 + self.b3
        e = np.exp(logits - logits.max())
        return e / (e.sum() + 1e-15)


# ── GUI ─────────────────────────────────────────────────────────

class NPUNNGUI:
    def __init__(self, width=900, height=700):
        pygame.init()
        self.W = width
        self.H = height
        self.screen = pygame.display.set_mode((width, height))
        pygame.display.set_caption('NPU Neural Network — Click to Draw Points')
        self.clock = pygame.time.Clock()

        self.nn = NPUNN()

        self.margin = 60
        self.plot_w = self.W - self.margin * 2
        self.plot_h = self.H - self.margin * 2
        self.model_range = 3.5
        # Each point: (sx, sy, mx, my, true_class, pred_class, confidence)
        self.points = []

        self.curr_class = 0
        self.font = pygame.font.Font(None, 22)
        self.font_small = pygame.font.Font(None, 17)

        self.grid_step = 30
        self.boundary = None
        self.computing_boundary = False

    def screen_to_model(self, sx, sy):
        mx = (sx - self.margin) / self.plot_w * 2 * self.model_range - self.model_range
        my = -(sy - self.margin) / self.plot_h * 2 * self.model_range + self.model_range
        return mx, my

    def model_to_screen(self, mx, my):
        sx = int((mx + self.model_range) / (2 * self.model_range) * self.plot_w + self.margin)
        sy = int((-my + self.model_range) / (2 * self.model_range) * self.plot_h + self.margin)
        return sx, sy

    def classify_point(self, mx, my, true_cls):
        probs = self.nn.forward(mx, my)
        pred_cls = np.argmax(probs)
        return pred_cls, probs[pred_cls]

    def add_point(self, sx, sy, mx, my, true_cls):
        pred_cls, conf = self.classify_point(mx, my, true_cls)
        self.points.append((sx, sy, mx, my, true_cls, pred_cls, conf))

    def compute_boundary_async(self):
        if self.computing_boundary:
            return
        self.computing_boundary = True
        w = self.plot_w // self.grid_step + 1
        h = self.plot_h // self.grid_step + 1
        grid = np.zeros((h, w))

        for gy in range(h):
            for gx in range(w):
                sx = gx * self.grid_step + self.margin
                sy = gy * self.grid_step + self.margin
                mx, my = self.screen_to_model(sx, sy)
                grid[gy, gx] = self.nn.forward_np(mx, my)[1]

                # Process events every cell to keep GUI alive
                for ev in pygame.event.get():
                    if ev.type == pygame.QUIT:
                        self.computing_boundary = False
                        return
                    if ev.type == pygame.KEYDOWN and ev.key in (pygame.K_ESCAPE, pygame.K_q):
                        self.computing_boundary = False
                        return

            # Redraw progress every row
            self.boundary = grid.copy()
            self.draw_frame()
            caption = f'NPU NN — computing boundary… {gy+1}/{h}  (Esc to cancel)'
            pygame.display.set_caption(caption)
            pygame.display.flip()

        self.boundary = grid
        self.computing_boundary = False
        pygame.display.set_caption('NPU Neural Network — Click to Draw Points')

    def draw_boundary(self):
        if self.boundary is None:
            return
        h, w = self.boundary.shape
        surf = pygame.Surface((self.plot_w, self.plot_h))
        for gy in range(h - 1):
            for gx in range(w - 1):
                sx = gx * self.grid_step
                sy = gy * self.grid_step
                p = self.boundary[gy, gx]
                if p >= 0.5:
                    blend = (p - 0.5) * 2
                    c = tuple(int(CLASS_1_BG[i] * blend + CLASS_0_BG[i] * (1 - blend)) for i in range(3))
                else:
                    blend = (0.5 - p) * 2
                    c = tuple(int(CLASS_0_BG[i] * blend + CLASS_1_BG[i] * (1 - blend)) for i in range(3))
                surf.fill(c, (sx, sy, self.grid_step + 1, self.grid_step + 1))

        self.screen.blit(surf, (self.margin, self.margin))

    def draw_points(self):
        for sx, sy, mx, my, true_cls, pred_cls, conf in self.points:
            col = CLASS_0 if true_cls == 0 else CLASS_1
            correct = pred_cls == true_cls
            border = (100, 220, 100) if correct else (220, 100, 100)

            pygame.draw.circle(self.screen, border, (sx, sy), 10, 2)
            pygame.draw.circle(self.screen, col, (sx, sy), 7)
            inner_r = max(2, int(conf * 6))
            pygame.draw.circle(self.screen, WHITE, (sx, sy), inner_r)

    def draw_axes(self):
        rect = pygame.Rect(self.margin, self.margin, self.plot_w, self.plot_h)
        pygame.draw.rect(self.screen, GRID_LN, rect, 1)

        for val in range(-3, 4):
            if val == 0:
                continue
            sx, sy = self.model_to_screen(val, 0)
            if self.margin <= sx <= self.margin + self.plot_w:
                pygame.draw.line(self.screen, GRID_LN, (sx, self.margin),
                                 (sx, self.margin + self.plot_h), 1)
                label = self.font_small.render(str(val), True, (80, 80, 80))
                self.screen.blit(label, (sx - label.get_width() // 2, self.margin + self.plot_h + 4))
            sx, sy = self.model_to_screen(0, val)
            if self.margin <= sy <= self.margin + self.plot_h:
                pygame.draw.line(self.screen, GRID_LN, (self.margin, sy),
                                 (self.margin + self.plot_w, sy), 1)
                label = self.font_small.render(str(val), True, (80, 80, 80))
                self.screen.blit(label, (self.margin - label.get_width() - 6, sy - 6))

        ox, oy = self.model_to_screen(0, 0)
        pygame.draw.line(self.screen, (60, 60, 80), (ox - 6, oy), (ox + 6, oy), 1)
        pygame.draw.line(self.screen, (60, 60, 80), (ox, oy - 6), (ox, oy + 6), 1)

    def draw_hud(self):
        bar_rect = pygame.Rect(0, 0, self.W, 38)
        pygame.draw.rect(self.screen, (20, 20, 40), bar_rect)
        pygame.draw.line(self.screen, (40, 40, 60), (0, 38), (self.W, 38), 1)

        cls_col = CLASS_0 if self.curr_class == 0 else CLASS_1
        cls_name = 'RED (class 0)' if self.curr_class == 0 else 'BLUE (class 1)'
        color_swatch = pygame.Surface((14, 14))
        color_swatch.fill(cls_col)
        self.screen.blit(color_swatch, (16, 12))

        status = 'Computing boundary…' if self.computing_boundary else f'Points: {len(self.points)}'
        text = self.font.render(f'Next: {cls_name}  |  {status}  |  '
                                f'Space=toggle  C=clear  R=boundary  Esc=quit',
                                True, WHITE)
        self.screen.blit(text, (38, 11))

        if self.points and not self.computing_boundary:
            correct = sum(1 for p in self.points if p[4] == p[5])
            acc = correct / len(self.points)
            stats = self.font_small.render(
                f'NPU accuracy: {correct}/{len(self.points)} = {acc:.1%}  |  '
                f'MATMULs: {self.nn.npu.stats["matmul"]}',
                True, (140, 140, 160))
            self.screen.blit(stats, (self.margin, self.H - 24))

    def draw_frame(self):
        self.screen.fill(BG)
        self.draw_boundary()
        self.draw_axes()
        self.draw_points()
        self.draw_hud()

    def run(self):
        running = True

        while running:
            for event in pygame.event.get():
                if event.type == pygame.QUIT:
                    running = False

                if event.type == pygame.KEYDOWN:
                    if event.key in (pygame.K_ESCAPE, pygame.K_q):
                        if self.computing_boundary:
                            self.computing_boundary = False
                        else:
                            running = False
                    elif event.key == pygame.K_SPACE:
                        self.curr_class = 1 - self.curr_class
                    elif event.key == pygame.K_c:
                        self.points.clear()
                    elif event.key == pygame.K_r and not self.computing_boundary:
                        self.boundary = None
                        self.compute_boundary_async()

                if event.type == pygame.MOUSEBUTTONDOWN and event.button == 1:
                    sx, sy = event.pos
                    if (self.margin <= sx <= self.margin + self.plot_w and
                        self.margin <= sy <= self.margin + self.plot_h and
                        not self.computing_boundary):
                        mx, my = self.screen_to_model(sx, sy)
                        self.add_point(sx, sy, mx, my, self.curr_class)
                        self.curr_class = 1 - self.curr_class

            self.draw_frame()
            pygame.display.flip()
            self.clock.tick(60)

        pygame.quit()


def main():
    gui = NPUNNGUI()
    gui.run()


if __name__ == '__main__':
    main()
