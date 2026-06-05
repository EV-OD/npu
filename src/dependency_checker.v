module dependency_checker #(
    parameter NUM_TILES = 64
)(
    input  wire                         clk,
    input  wire                         rst,

    // Check & lock (atomic check-then-lock for up to 3 tiles)
    input  wire                         check_lock_en,
    input  wire [7:0]                   chk_tile_a,
    input  wire [7:0]                   chk_tile_b,
    input  wire [7:0]                   chk_tile_c,
    input  wire [1:0]                   chk_num_tiles,  // 1, 2, or 3
    output reg                          check_lock_grant,
    output reg [7:0]                    conflict_tile,

    // Release tiles (on instruction completion)
    input  wire                         release_en,
    input  wire [7:0]                   release_tile_a,
    input  wire [7:0]                   release_tile_b,
    input  wire [7:0]                   release_tile_c,
    input  wire [1:0]                   release_num_tiles,

    output reg [NUM_TILES-1:0]          lock_status
);

    reg locked_tiles [0:NUM_TILES-1];
    integer i;

    initial begin
        for (i = 0; i < NUM_TILES; i = i + 1)
            locked_tiles[i] = 0;
    end

    // Check if a tile is locked
    function is_locked;
        input [7:0] t;
        begin
            is_locked = (t < NUM_TILES) && locked_tiles[t];
        end
    endfunction

    // Lock a tile
    task lock_tile;
        input [7:0] t;
        begin
            if (t < NUM_TILES)
                locked_tiles[t] = 1;
        end
    endtask

    // Unlock a tile
    task release_tile;
        input [7:0] t;
        begin
            if (t < NUM_TILES)
                locked_tiles[t] = 0;
        end
    endtask

    // All requested tiles are unlocked?
    function all_free;
        input [7:0] a, b, c;
        input [1:0] n;
        begin
            all_free = 1;
            if (n >= 1 && is_locked(a)) all_free = 0;
            if (n >= 2 && is_locked(b)) all_free = 0;
            if (n >= 3 && is_locked(c)) all_free = 0;
        end
    endfunction

    // Find first conflicting tile
    function [7:0] first_conflict;
        input [7:0] a, b, c;
        input [1:0] n;
        begin
            first_conflict = 0;
            if (n >= 1 && is_locked(a)) first_conflict = a;
            else if (n >= 2 && is_locked(b)) first_conflict = b;
            else if (n >= 3 && is_locked(c)) first_conflict = c;
        end
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < NUM_TILES; i = i + 1)
                locked_tiles[i] <= 0;
            check_lock_grant <= 0;
            conflict_tile    <= 0;
        end else begin
            check_lock_grant <= 0;
            conflict_tile    <= 0;

            if (check_lock_en) begin
                if (all_free(chk_tile_a, chk_tile_b, chk_tile_c, chk_num_tiles)) begin
                    check_lock_grant <= 1;
                    lock_tile(chk_tile_a);
                    if (chk_num_tiles >= 2) lock_tile(chk_tile_b);
                    if (chk_num_tiles >= 3) lock_tile(chk_tile_c);
                end else begin
                    conflict_tile <= first_conflict(chk_tile_a, chk_tile_b, chk_tile_c, chk_num_tiles);
                end
            end

            if (release_en) begin
                release_tile(release_tile_a);
                if (release_num_tiles >= 2) release_tile(release_tile_b);
                if (release_num_tiles >= 3) release_tile(release_tile_c);
            end
        end
    end

    // Debug readout
    always @(*) begin
        for (i = 0; i < NUM_TILES; i = i + 1)
            lock_status[i] = locked_tiles[i];
    end

endmodule
