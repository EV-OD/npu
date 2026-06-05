`include "instruction_defines.vh"

module system #(
    parameter N          = 4,
    parameter SLOT_DEPTH = 64,
    parameter NUM_TILES  = 64
)(
    input  wire                                clk,
    input  wire                                rst,

    // IBRAM DMA write interface
    input  wire                                dma_en,
    input  wire                                dma_we,
    input  wire [$clog2(2*SLOT_DEPTH)-1:0]     dma_addr,
    input  wire [31:0]                         dma_din,

    // External execution unit handshake
    input  wire                                sys_busy,
    input  wire                                sys_done,
    output wire                                sys_start,
    output wire [31:0]                         sys_matrix_size,
    output wire [31:0]                         sys_act_base,
    output wire [31:0]                         sys_wgt_base,
    output wire [31:0]                         sys_out_base,

    // Debug / status outputs
    output wire                                active_slot,
    output wire                                ibram_ready,
    output wire                                busy,
    output wire [3:0]                          state_debug,
    output wire [3:0]                          opcode_debug,
    output wire [NUM_TILES-1:0]                lock_status
);

    // ── Interconnect wires ──────────────────────────────────────────────

    // IBRAM ↔ Dispatch
    wire [$clog2(SLOT_DEPTH)-1:0] pc_addr;
    wire                          pc_en;
    wire [31:0]                   pc_dout;
    wire                          swap_req;

    // Dispatch ↔ Dependency checker
    wire       dep_check_en;
    wire [7:0] dep_tile_a, dep_tile_b, dep_tile_c;
    wire [1:0] dep_num_tiles;
    wire       dep_grant;
    wire [7:0] dep_conflict;

    wire       dep_release_en;
    wire [7:0] dep_release_a, dep_release_b, dep_release_c;
    wire [1:0] dep_release_num;

    // Loop/jump
    wire       pc_loop_jump;
    wire [$clog2(SLOT_DEPTH)-1:0] pc_loop_target;

    // ── Component instances ─────────────────────────────────────────────

    ibram #(.SLOT_DEPTH(SLOT_DEPTH)) u_ibram (
        .clk          (clk),
        .rst          (rst),
        .dma_en       (dma_en),
        .dma_we       (dma_we),
        .dma_addr     (dma_addr),
        .dma_din      (dma_din),
        .pc_en        (pc_en),
        .pc_addr      (pc_addr),
        .pc_dout      (pc_dout),
        .active_slot  (active_slot),
        .ready        (ibram_ready),
        .swap         (swap_req)
    );

    dependency_checker #(.NUM_TILES(NUM_TILES)) u_dep (
        .clk              (clk),
        .rst              (rst),
        .check_lock_en    (dep_check_en),
        .chk_tile_a       (dep_tile_a),
        .chk_tile_b       (dep_tile_b),
        .chk_tile_c       (dep_tile_c),
        .chk_num_tiles    (dep_num_tiles),
        .check_lock_grant (dep_grant),
        .conflict_tile    (dep_conflict),
        .release_en       (dep_release_en),
        .release_tile_a   (dep_release_a),
        .release_tile_b   (dep_release_b),
        .release_tile_c   (dep_release_c),
        .release_num_tiles(dep_release_num),
        .lock_status      (lock_status)
    );

    dispatch_unit #(.N(N), .SLOT_DEPTH(SLOT_DEPTH)) u_dispatch (
        .clk                (clk),
        .rst                (rst),
        .pc_addr_in         (0),
        .pc_addr            (pc_addr),
        .inst_dout          (pc_dout),
        .pc_en              (pc_en),
        .dep_check_en       (dep_check_en),
        .dep_tile_a         (dep_tile_a),
        .dep_tile_b         (dep_tile_b),
        .dep_tile_c         (dep_tile_c),
        .dep_num_tiles      (dep_num_tiles),
        .dep_grant          (dep_grant),
        .dep_conflict       (dep_conflict),
        .dep_release_en     (dep_release_en),
        .dep_release_a      (dep_release_a),
        .dep_release_b      (dep_release_b),
        .dep_release_c      (dep_release_c),
        .dep_release_num    (dep_release_num),
        .sys_start          (sys_start),
        .sys_matrix_size    (sys_matrix_size),
        .sys_act_base       (sys_act_base),
        .sys_wgt_base       (sys_wgt_base),
        .sys_out_base       (sys_out_base),
        .sys_busy           (sys_busy),
        .sys_done           (sys_done),
        .pc_loop_jump       (pc_loop_jump),
        .pc_loop_target     (pc_loop_target),
        .swap_req           (swap_req),
        .ibram_ready        (ibram_ready),
        .busy               (busy),
        .state_debug        (state_debug),
        .opcode_debug       (opcode_debug),
        .loop_remaining_debug()
    );

endmodule
