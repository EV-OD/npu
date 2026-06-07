#!/usr/bin/env python3
import sys
import signal
import os


def print_info(use_verilog=False):
    backend = 'Verilog RTL' if use_verilog else 'Python'
    print('\033[1;32m' + '=' * 60)
    print('  NPU-Accelerated 3D Cube Demo')
    print(f'  Backend: {backend} simulation')
    print('=' * 60 + '\033[0m\n')
    print('Architecture:')
    print('  • Systolic array: 4×4 PEs (16 MACs/cycle)')
    print('  • Tile size: 4×4 matrices')
    print('  • Instruction set: MATMUL, LOAD, STORE, LOOP, JUMP')
    print('  • Dataflow: Output-stationary (C += A × B)')
    print()
    print('Rendering Pipeline:')
    print('  1. Tile 0 = Rotation matrix (RX × RY)')
    print('  2. Tiles 1-2 = Cube vertices (4 per tile)')
    print('  3. MATMUL(0, 1 → 3): rot × vertices_A')
    print('  4. MATMUL(0, 2 → 4): rot × vertices_B')
    print('  5. Extract 2D coords from output tiles')
    print()


def run_terminal(use_verilog=False):
    signal.signal(signal.SIGINT, lambda s, f: sys.exit(0))
    print_info(use_verilog)
    from cube_3d import NPUCubeRenderer
    print('\033[33mStarting animation (10 sec, 10 FPS)...\033[0m')
    print('Press Ctrl+C to exit\n')
    renderer = NPUCubeRenderer(width=60, height=30, use_verilog=use_verilog)
    renderer.animate(duration=10, fps=10)
    print('\n\033[1;32mDemo complete!\033[0m')
    print(f'Total MATMUL operations: {renderer.npu.stats["matmul"]}')
    print(f'Simulated cycles: {renderer.npu.stats["cycles"]}')
    print(f'Each MATMUL = 7×N + 3 = {7*renderer.npu.N + 3} cycles on {renderer.npu.N}×{renderer.npu.N} array')


def run_gui(use_verilog=False):
    print_info(use_verilog)
    from cube_gui import NPUCubeGUI
    gui = NPUCubeGUI(width=1000, height=750, use_verilog=use_verilog)
    gui.run()


if __name__ == '__main__':
    mode = 'gui'
    use_verilog = False
    args = [a.lower() for a in sys.argv[1:]]
    for a in args:
        if a in ('terminal', 'tty', 'text'):
            mode = 'terminal'
        elif a in ('gui', '--gui', '-g'):
            mode = 'gui'
        elif a in ('--verilog', '-v'):
            use_verilog = True

    mode = os.environ.get('NPU_DEMO', mode).lower()

    if mode in ('gui', '--gui', '-g'):
        if 'DISPLAY' not in os.environ:
            print('No display available. Run with "terminal" mode:\n  python3 demo.py terminal')
            sys.exit(1)
        run_gui(use_verilog)
    else:
        run_terminal(use_verilog)
