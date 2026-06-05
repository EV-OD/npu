`timescale 1ns / 1ps

module tb_dependency;

    parameter NUM_TILES = 64;

    reg clk, rst;
    reg check_lock_en;
    reg [7:0] chk_tile_a, chk_tile_b, chk_tile_c;
    reg [1:0] chk_num_tiles;
    wire check_lock_grant;
    wire [7:0] conflict_tile;
    reg release_en;
    reg [7:0] release_tile_a, release_tile_b, release_tile_c;
    reg [1:0] release_num_tiles;
    wire [NUM_TILES-1:0] lock_status;

    dependency_checker #(.NUM_TILES(NUM_TILES)) uut (
        .clk(clk), .rst(rst),
        .check_lock_en(check_lock_en),
        .chk_tile_a(chk_tile_a), .chk_tile_b(chk_tile_b), .chk_tile_c(chk_tile_c),
        .chk_num_tiles(chk_num_tiles),
        .check_lock_grant(check_lock_grant),
        .conflict_tile(conflict_tile),
        .release_en(release_en),
        .release_tile_a(release_tile_a), .release_tile_b(release_tile_b), .release_tile_c(release_tile_c),
        .release_num_tiles(release_num_tiles),
        .lock_status(lock_status)
    );

    always #5 clk = ~clk;

    integer errors, pass_count, fail_count;

    task check;
        input string msg;
        input cond;
        begin
            if (cond) pass_count = pass_count + 1;
            else begin
                $display("  FAIL: %s @ %0t", msg, $time);
                errors = errors + 1; fail_count = fail_count + 1;
            end
        end
    endtask

    task ps;
        begin @(posedge clk); #1; end
    endtask

    // Lock 1-3 tiles
    task lock_tiles;
        input [7:0] a, b, c;
        input [1:0] n;
        begin
            @(negedge clk);
            check_lock_en = 1; chk_tile_a = a; chk_tile_b = b; chk_tile_c = c; chk_num_tiles = n;
            ps();
            check_lock_en = 0;
        end
    endtask

    task rel_tiles;
        input [7:0] a, b, c;
        input [1:0] n;
        begin
            @(negedge clk);
            release_en = 1; release_tile_a = a; release_tile_b = b; release_tile_c = c; release_num_tiles = n;
            ps();
            release_en = 0;
        end
    endtask

    initial begin
        $dumpfile("tb_dependency.vcd");
        $dumpvars(0, tb_dependency);

        clk = 0; rst = 1;
        check_lock_en = 0; chk_tile_a = 0; chk_tile_b = 0; chk_tile_c = 0; chk_num_tiles = 0;
        release_en = 0; release_tile_a = 0; release_tile_b = 0; release_tile_c = 0; release_num_tiles = 0;
        errors = 0; pass_count = 0; fail_count = 0;

        #18 rst = 0; ps();

        $display("=== DEPENDENCY CHECKER TEST (NUM_TILES=%0d) ===", NUM_TILES);
        $display("");

        // -------------------------------------------------------
        // Test 1: Lock single tile, check conflict
        // -------------------------------------------------------
        $display("--- Test 1: Lock single tile, detect conflict ---");
        lock_tiles(5, 0, 0, 1);
        check("grant for tile 5", check_lock_grant == 1);

        // Try to lock same tile
        lock_tiles(5, 0, 0, 1);
        check("deny on tile 5 (locked)", check_lock_grant == 0);
        check("conflict tile=5", conflict_tile == 5);

        // Release
        rel_tiles(5, 0, 0, 1);

        // Now should succeed
        lock_tiles(5, 0, 0, 1);
        check("grant tile 5 after release", check_lock_grant == 1);

        // -------------------------------------------------------
        // Test 2: Lock multiple tiles atomically
        // -------------------------------------------------------
        $display("--- Test 2: Lock 3 tiles atomically ---");
        rel_tiles(5, 0, 0, 1);
        // Lock 3 tiles at once
        lock_tiles(10, 20, 30, 3);
        check("grant 3 tiles", check_lock_grant == 1);

        // Any should be rejected
        lock_tiles(10, 0, 0, 1);
        check("deny tile 10", check_lock_grant == 0);
        check("conflict=10", conflict_tile == 10);

        lock_tiles(0, 20, 0, 2);
        check("deny tile 20", check_lock_grant == 0);
        check("conflict=20", conflict_tile == 20);

        lock_tiles(30, 0, 0, 1);
        check("deny tile 30", check_lock_grant == 0);
        check("conflict=30", conflict_tile == 30);

        // Tile 40 should be free
        lock_tiles(40, 0, 0, 1);
        check("grant tile 40 (free)", check_lock_grant == 1);

        // -------------------------------------------------------
        // Test 3: Release multiple tiles, verify all clean
        // -------------------------------------------------------
        $display("--- Test 3: Release 3 tiles ---");
        rel_tiles(10, 20, 30, 3);
        check("tiles 10,20,30 released", lock_status[10] == 0 && lock_status[20] == 0 && lock_status[30] == 0);
        // Also release tile 40 (locked in Test 2)
        rel_tiles(40, 0, 0, 1);

        lock_tiles(10, 20, 30, 3);
        check("grant after release", check_lock_grant == 1);

        // -------------------------------------------------------
        // Test 4: Check partial conflict (2 of 3 tiles free)
        // -------------------------------------------------------
        $display("--- Test 4: Partial conflict ---");
        // tile 10, 20, 30 locked from above. Try to lock 30, 40, 50
        lock_tiles(30, 40, 50, 3);
        check("deny (30 still locked)", check_lock_grant == 0);
        check("conflict=30", conflict_tile == 30);

        // Release 30 only
        rel_tiles(30, 0, 0, 1);
        // Now 30 is free but 10,20 still locked. Lock 30,40,50 → should grant (10,20 not requested)
        lock_tiles(30, 40, 50, 3);
        check("grant tiles 30,40,50 (10,20 not requested)", check_lock_grant == 1);
        // Tile 10 should still be locked
        lock_tiles(10, 0, 0, 1);
        check("deny tile 10 (still locked)", check_lock_grant == 0);
        check("conflict=10", conflict_tile == 10);

        // -------------------------------------------------------
        // Test 5: Release everything
        // -------------------------------------------------------
        $display("--- Test 5: Release all and verify ---");
        rel_tiles(10, 20, 0, 2);
        rel_tiles(30, 0, 0, 1);
        rel_tiles(40, 50, 0, 2);

        lock_tiles(10, 20, 30, 3);
        check("all free: grant", check_lock_grant == 1);

        // -------------------------------------------------------
        // Test 6: Tile out of range (>= NUM_TILES)
        // -------------------------------------------------------
        $display("--- Test 6: Out-of-range tiles ---");
        // Release current locks
        rel_tiles(10, 20, 30, 3);

        // Lock tile 100 (out of range) — should be silently ignored
        lock_tiles(100, 0, 0, 1);
        check("grant for out-of-range (ignored)", check_lock_grant == 1);

        // Lock tile 10 — should work
        lock_tiles(10, 0, 0, 1);
        check("grant for tile 10", check_lock_grant == 1);

        // -------------------------------------------------------
        // Test 7: Rapid lock-release cycle
        // -------------------------------------------------------
        $display("--- Test 7: Rapid lock-release ---");
        rel_tiles(10, 0, 0, 1);
        lock_tiles(15, 0, 0, 1);  // lock
        check("lock grant 15", check_lock_grant == 1);
        rel_tiles(15, 0, 0, 1);   // immediate release
        lock_tiles(15, 0, 0, 1);  // lock again
        check("lock grant 15 again", check_lock_grant == 1);
        rel_tiles(15, 0, 0, 1);

        // -------------------------------------------------------
        // Test 8: Many independent tiles
        // -------------------------------------------------------
        $display("--- Test 8: Many independent tiles ---");
        for (integer i = 0; i < 10; i = i + 1) begin
            lock_tiles(i, 0, 0, 1);
            if (check_lock_grant !== 1) begin
                $display("  FAIL: lock tile %0d @ %0t", i, $time);
                errors = errors + 1; fail_count = fail_count + 1;
            end else pass_count = pass_count + 1;
        end
        // All should be locked
        for (integer i = 0; i < 10; i = i + 1) begin
            lock_tiles(i, 0, 0, 1);
            if (check_lock_grant !== 0) begin
                $display("  FAIL: tile %0d still locked @ %0t", i, $time);
                errors = errors + 1; fail_count = fail_count + 1;
            end else pass_count = pass_count + 1;
        end
        // Release all
        for (integer i = 0; i < 10; i = i + 1)
            rel_tiles(i, 0, 0, 1);

        // -------------------------------------------------------
        // Test 9: Lock same tile with different num_tiles
        // -------------------------------------------------------
        $display("--- Test 9: Same tile multiple ways ---");
        // Lock with 3 tiles where a == b == c
        lock_tiles(7, 7, 7, 3);
        check("lock tile 7 (3-way same)", check_lock_grant == 1);
        // Should not be able to lock tile 7 again
        lock_tiles(7, 0, 0, 1);
        check("tile 7 still locked", check_lock_grant == 0);
        rel_tiles(7, 7, 7, 3);

        // -------------------------------------------------------
        // Test 10: lock_status debug readout
        // -------------------------------------------------------
        $display("--- Test 10: lock_status readout ---");
        lock_tiles(0, 1, 2, 3);
        check("status[0]=1", lock_status[0] == 1);
        check("status[1]=1", lock_status[1] == 1);
        check("status[2]=1", lock_status[2] == 1);
        check("status[3]=0", lock_status[3] == 0);
        rel_tiles(0, 1, 2, 3);
        check("status[0]=0 after release", lock_status[0] == 0);

        // -------------------------------------------------------
        // Summary
        // -------------------------------------------------------
        $display("");
        $display("--- RESULTS ---");
        $display("  Checks: %0d passed, %0d failed, %0d total",
                 pass_count, fail_count, pass_count + fail_count);
        if (errors === 0)
            $display("*** DEPENDENCY CHECKER TEST PASSED ***");
        else
            $display("*** DEPENDENCY CHECKER TEST FAILED ***");
        #100 $finish;
    end

endmodule
