`include "instruction_defines.vh"

module dispatch_unit #(
    parameter N = 4,
    parameter SLOT_DEPTH = 64
)(
    input  wire                         clk,
    input  wire                         rst,

    input  wire [$clog2(SLOT_DEPTH)-1:0] pc_addr_in,
    output wire [$clog2(SLOT_DEPTH)-1:0] pc_addr,
    input  wire [`INST_WIDTH-1:0]        inst_dout,
    output wire                          pc_en,

    output reg                           dep_check_en,
    output reg  [7:0]                    dep_tile_a,
    output reg  [7:0]                    dep_tile_b,
    output reg  [7:0]                    dep_tile_c,
    output reg  [1:0]                    dep_num_tiles,
    input  wire                          dep_grant,
    input  wire [7:0]                    dep_conflict,

    output reg                           dep_release_en,
    output reg  [7:0]                    dep_release_a,
    output reg  [7:0]                    dep_release_b,
    output reg  [7:0]                    dep_release_c,
    output reg  [1:0]                    dep_release_num,

    output reg                           sys_start,
    output reg  [31:0]                   sys_matrix_size,
    output reg  [31:0]                   sys_act_base,
    output reg  [31:0]                   sys_wgt_base,
    output reg  [31:0]                   sys_out_base,
    input  wire                          sys_busy,
    input  wire                          sys_done,

    output reg                           pc_loop_jump,
    output reg  [$clog2(SLOT_DEPTH)-1:0] pc_loop_target,

    output reg                           swap_req,
    input  wire                          ibram_ready,

    output reg                           busy,
    output reg  [3:0]                    state_debug,
    output reg  [3:0]                    opcode_debug,
    output reg  [11:0]                   loop_remaining_debug
);

    localparam IDLE       = 4'd0;
    localparam FETCH      = 4'd1;
    localparam DECODE_W   = 4'd2;
    localparam CHECK      = 4'd3;
    localparam DISPATCH   = 4'd4;
    localparam WAIT_EXEC  = 4'd5;
    localparam RELEASE    = 4'd6;
    localparam LOOP_JUMP  = 4'd7;

    reg [3:0] state, nxt;
    reg [3:0] opcode;
    reg [7:0] wt_tile, act_tile, out_tile;
    reg [11:0] ls_dram_addr;
    reg [7:0] ls_buf_tile;
    reg [3:0] ls_size;
    reg [11:0] loop_count_field;
    reg [7:0] loop_target_field, loop_stride_field;
    reg [11:0] jump_target_field;

    reg [$clog2(SLOT_DEPTH)-1:0] pc;
    reg [1:0] num_tiles;

    // Loop state
    reg [11:0] loop_remaining;
    reg [7:0]  loop_body_target;
    reg        in_loop;

    assign loop_remaining_debug = loop_remaining;

    always @(posedge clk) begin
        if (rst) begin
            pc <= 0;
            loop_remaining <= 0;
            loop_body_target <= 0;
            in_loop <= 0;
        end else begin
            case (state)
                IDLE: begin
                    pc <= 0;
                    in_loop <= 0;
                end
                FETCH: begin
                    pc <= pc + 1;
                end
                LOOP_JUMP: begin
                    pc <= pc_loop_target;
                end
            endcase
        end
    end

    always @(posedge clk) begin
        if (rst) state <= IDLE;
        else      state <= nxt;
    end

    always @(*) begin
        nxt = state;
        case (state)
            IDLE:       if (ibram_ready)         nxt = FETCH;
            FETCH:                                nxt = DECODE_W;
            DECODE_W:                             nxt = CHECK;
            CHECK: begin
                if (opcode == `OP_NOP || opcode == `OP_BARRIER || opcode == `OP_LOOP || opcode == `OP_JUMP)
                    nxt = DISPATCH;
                else if (dep_grant)
                    nxt = DISPATCH;
            end
            DISPATCH: begin
                if (opcode == `OP_NOP || opcode == `OP_BARRIER)
                    nxt = FETCH;
                else if (opcode == `OP_LOOP) begin
                    if (in_loop && loop_remaining > 0)
                        nxt = LOOP_JUMP;
                    else if (!in_loop && loop_count_field > 0)
                        nxt = LOOP_JUMP;
                    else
                        nxt = FETCH;
                end
                else if (opcode == `OP_JUMP)
                    nxt = LOOP_JUMP;
                else
                    nxt = WAIT_EXEC;
            end
            WAIT_EXEC:  if (sys_done)             nxt = RELEASE;
            RELEASE:                              nxt = FETCH;
            LOOP_JUMP:                            nxt = FETCH;
            default:                              nxt = IDLE;
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            opcode <= `OP_NOP;
            wt_tile <= 0; act_tile <= 0; out_tile <= 0;
            ls_dram_addr <= 0; ls_buf_tile <= 0; ls_size <= 0;
            loop_count_field <= 0; loop_target_field <= 0; loop_stride_field <= 0;
            jump_target_field <= 0;
            num_tiles <= 0;
            sys_start <= 0; sys_matrix_size <= N;
            sys_act_base <= 0; sys_wgt_base <= 0; sys_out_base <= 0;
            dep_check_en <= 0; dep_tile_a <= 0; dep_tile_b <= 0; dep_tile_c <= 0;
            dep_num_tiles <= 0;
            dep_release_en <= 0; dep_release_a <= 0; dep_release_b <= 0; dep_release_c <= 0;
            dep_release_num <= 0;
            swap_req <= 0; pc_loop_jump <= 0; pc_loop_target <= 0;
            busy <= 0; state_debug <= IDLE;
            opcode_debug <= `OP_NOP;
        end else begin
            dep_check_en <= 0; dep_release_en <= 0;
            sys_start <= 0; pc_loop_jump <= 0; swap_req <= 0;

            case (state)
                IDLE: begin
                    busy <= 0; state_debug <= IDLE;
                end

                FETCH: begin
                    state_debug <= FETCH; busy <= 1;
                end

                DECODE_W: begin
                    state_debug <= DECODE_W;
                    opcode <= inst_dout[31:28];
                    opcode_debug <= inst_dout[31:28];
                    wt_tile <= inst_dout[27:20];
                    act_tile <= inst_dout[19:12];
                    out_tile <= inst_dout[11:4];
                    ls_dram_addr <= inst_dout[27:16];
                    ls_buf_tile <= inst_dout[15:8];
                    ls_size <= inst_dout[3:0];
                    loop_count_field <= inst_dout[27:16];
                    loop_target_field <= inst_dout[15:8];
                    loop_stride_field <= inst_dout[7:0];
                    jump_target_field <= inst_dout[27:16];
                end

                CHECK: begin
                    state_debug <= CHECK;
                    case (opcode)
                        `OP_MATMUL: begin
                            dep_check_en <= 1; num_tiles <= 3;
                            dep_tile_a <= wt_tile; dep_tile_b <= act_tile; dep_tile_c <= out_tile;
                            dep_num_tiles <= 3;
                        end
                        `OP_LOAD, `OP_STORE: begin
                            dep_check_en <= 1; num_tiles <= 1;
                            dep_tile_a <= ls_buf_tile; dep_tile_b <= 0; dep_tile_c <= 0;
                            dep_num_tiles <= 1;
                        end
                        default: num_tiles <= 0;
                    endcase
                end

                DISPATCH: begin
                    state_debug <= DISPATCH;
                    case (opcode)
                        `OP_MATMUL: begin
                            sys_start <= 1;
                            sys_matrix_size <= N;
                            sys_wgt_base <= wt_tile;
                            sys_act_base <= act_tile;
                            sys_out_base <= out_tile;
                        end
                        `OP_LOAD, `OP_STORE: begin
                        end
                        `OP_LOOP: begin
                            if (in_loop && loop_remaining > 0) begin
                                loop_remaining <= loop_remaining - 1;
                                pc_loop_target <= loop_body_target[$clog2(SLOT_DEPTH)-1:0];
                            end else if (!in_loop && loop_count_field > 0) begin
                                loop_remaining <= loop_count_field - 1;
                                loop_body_target <= loop_target_field;
                                in_loop <= 1;
                                pc_loop_target <= loop_target_field[$clog2(SLOT_DEPTH)-1:0];
                            end else begin
                                in_loop <= 0;
                            end
                        end
                        `OP_JUMP: begin
                            pc_loop_target <= jump_target_field[$clog2(SLOT_DEPTH)-1:0];
                        end
                        default: begin end
                    endcase
                end

                WAIT_EXEC: begin
                    state_debug <= WAIT_EXEC;
                end

                RELEASE: begin
                    state_debug <= RELEASE;
                    if (num_tiles > 0) begin
                        dep_release_en <= 1;
                        dep_release_a <= wt_tile;
                        dep_release_b <= act_tile;
                        dep_release_c <= out_tile;
                        dep_release_num <= num_tiles;
                    end
                end

                LOOP_JUMP: begin
                    state_debug <= LOOP_JUMP;
                    pc_loop_jump <= 1;
                end

                default: state_debug <= IDLE;
            endcase

            if (pc == SLOT_DEPTH-1 && state == FETCH)
                swap_req <= 1;
        end
    end

    assign pc_en   = (state == FETCH);
    assign pc_addr = (state == FETCH) ? pc : {$clog2(SLOT_DEPTH){1'b0}};

endmodule
