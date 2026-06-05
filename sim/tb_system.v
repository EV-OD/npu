`timescale 1ns / 1ps
`include "../src/instruction_defines.vh"

module tb_system;

    parameter SLOT_DEPTH = 64;
    parameter NUM_TILES  = 64;

    reg clk, rst;
    reg dma_en, dma_we;
    reg [6:0] dma_addr;
    reg [31:0] dma_din;

    reg sys_busy, sys_done;
    wire sys_start;
    wire [31:0] sys_matrix_size, sys_act_base, sys_wgt_base, sys_out_base;

    wire active_slot, ibram_ready;
    wire busy;
    wire [3:0] state_debug, opcode_debug;
    wire [NUM_TILES-1:0] lock_status;

    system #(.SLOT_DEPTH(SLOT_DEPTH), .NUM_TILES(NUM_TILES)) u_sys (
        .clk(clk), .rst(rst),
        .dma_en(dma_en), .dma_we(dma_we),
        .dma_addr(dma_addr), .dma_din(dma_din),
        .sys_busy(sys_busy), .sys_done(sys_done),
        .sys_start(sys_start),
        .sys_matrix_size(sys_matrix_size),
        .sys_act_base(sys_act_base),
        .sys_wgt_base(sys_wgt_base),
        .sys_out_base(sys_out_base),
        .active_slot(active_slot),
        .ibram_ready(ibram_ready),
        .busy(busy),
        .state_debug(state_debug),
        .opcode_debug(opcode_debug),
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

    task dma_write;
        input [6:0] addr;
        input [31:0] data;
        begin
            @(negedge clk);
            dma_en <= 1; dma_we <= 1; dma_addr <= addr; dma_din <= data;
            @(posedge clk); #1;
            dma_en <= 0; dma_we <= 0;
        end
    endtask

    // Mock execution unit (4-cycle exec)
    reg [3:0] exec_count;
    reg exec_active;
    always @(posedge clk) begin
        if (rst) begin
            exec_active <= 0; exec_count <= 0;
            sys_busy <= 0; sys_done <= 0;
        end else begin
            sys_done <= 0;
            if (sys_start) begin
                exec_active <= 1; exec_count <= 4; sys_busy <= 1;
            end
            if (exec_active) begin
                if (exec_count == 0) begin
                    exec_active <= 0; sys_busy <= 0; sys_done <= 1;
                end else begin
                    exec_count <= exec_count - 1;
                end
            end
        end
    end

    initial begin
        $dumpfile("tb_system.vcd");
        $dumpvars(0, tb_system);

        clk = 0; rst = 1;
        dma_en = 0; dma_we = 0; dma_addr = 0; dma_din = 0;
        errors = 0; pass_count = 0; fail_count = 0;

        #18 rst = 0; ps();

        $display("=== SYSTEM INTEGRATION TEST ===");
        $display("");

        // ── Program IBRAM ───────────────────────────────────────────────
        $display("Loading IBRAM...");

        // Slot A:
        //   0: MATMUL(wt=1, act=2, out=3)
        //   1: MATMUL(wt=1, act=5, out=6)
        //   2: MATMUL(wt=7, act=8, out=9)
        //   3: NOP
        //   4-63: NOP

        dma_write(0, {`OP_MATMUL, 8'h01, 8'h02, 8'h03, 4'h0});
        dma_write(1, {`OP_MATMUL, 8'h01, 8'h05, 8'h06, 4'h0});
        dma_write(2, {`OP_MATMUL, 8'h07, 8'h08, 8'h09, 4'h0});
        dma_write(3, {`OP_NOP, 28'h0});
        for (integer i = 4; i < SLOT_DEPTH; i = i + 1)
            dma_write(i, {`OP_NOP, 28'h0});

        $display("  Slot A loaded (%0d words)", SLOT_DEPTH);

        for (integer i = 0; i < SLOT_DEPTH; i = i + 1)
            dma_write(SLOT_DEPTH + i, {`OP_NOP, 28'h0});

        $display("  Slot B loaded (%0d words)", SLOT_DEPTH);
        $display("  ibram_ready=%0d (will be 1 after cycle)", ibram_ready);
        ps(); check("ibram_ready after DMA", ibram_ready == 1);

        // ─────────────────────────────────────────────────────────────────
        // Test 1: MATMUL(1,2,3) — full lifecycle with dep checker
        //   State transitions:
        //     DECODE_W → CHECK (×3, dep processing) → DISPATCH → WAIT(×7)
        //     → RELEASE
        // ─────────────────────────────────────────────────────────────────
        $display("");
        $display("--- Test 1: MATMUL(1,2,3) — full lifecycle ---");
        ps(); // IDLE (stays IDLE — ibram_ready NBA pending)
        ps(); // FETCH
        ps(); // DECODE_W
        check("T1: DECODE_W, opcode=MATMUL", state_debug==2 && opcode_debug==`OP_MATMUL);

        // CHECK #1: dep_check_en asserted (NBA), dep not yet processed
        ps();
        check("T1: CHECK(1)", state_debug == 3);

        // CHECK #2: dep processes grant, tiles lock
        ps();
        check("T1: CHECK(2) dep grant", state_debug == 3);
        check("T1: tiles locked", lock_status[1] && lock_status[2] && lock_status[3]);

        // CHECK #3: dispatch sees dep_grant=1, nxt→DISPATCH
        ps();
        check("T1: CHECK(3) → DISPATCH pending", state_debug == 3);

        // DISPATCH
        ps();
        check("T1: DISPATCH, sys_start", state_debug==4 && sys_start==1);
        check("T1: wgt=1 act=2 out=3", sys_wgt_base==1 && sys_act_base==2 && sys_out_base==3);

        // WAIT_EXEC ×7 + RELEASE
        repeat (7) ps();
        ps(); // RELEASE(6)
        check("T1: RELEASE state", state_debug == 6);
        ps(); // FETCH — dep processes release here
        check("T1: tiles released", lock_status[1]==0 && lock_status[2]==0 && lock_status[3]==0);

        // ─────────────────────────────────────────────────────────────────
        // Test 2: MATMUL(1,5,6) — sequential (no conflict, T1 released)
        // ─────────────────────────────────────────────────────────────────
        $display("--- Test 2: MATMUL(1,5,6) — sequential ---");
        ps(); // DECODE_W (already in DECODE_W after T1's release check ps)
        check("T2: DECODE_W, opcode=MATMUL", state_debug==2 && opcode_debug==`OP_MATMUL);
        repeat (3) ps(); // CHECK ×3
        check("T2: tiles locked", lock_status[1] && lock_status[5] && lock_status[6]);
        ps(); // DISPATCH
        check("T2: DISPATCH, sys_start", state_debug==4 && sys_start==1);
        check("T2: wgt=1 act=5 out=6", sys_wgt_base==1 && sys_act_base==5 && sys_out_base==6);
        repeat (7) ps();
        ps(); // RELEASE(6)
        check("T2: RELEASE state", state_debug == 6);
        ps(); // FETCH — dep processes release
        check("T2: tiles released", lock_status[1]==0 && lock_status[5]==0 && lock_status[6]==0);

        // ─────────────────────────────────────────────────────────────────
        // Test 3: MATMUL(7,8,9) — sequential
        // ─────────────────────────────────────────────────────────────────
        $display("--- Test 3: MATMUL(7,8,9) — sequential ---");
        ps(); // DECODE_W (already in DECODE_W after T2's FETCH ps)
        check("T3: DECODE_W, opcode=MATMUL", state_debug==2 && opcode_debug==`OP_MATMUL);
        repeat (3) ps();
        check("T3: tiles locked", lock_status[7] && lock_status[8] && lock_status[9]);
        ps(); // DISPATCH
        check("T3: DISPATCH, sys_start", state_debug==4 && sys_start==1);
        check("T3: wgt=7 act=8 out=9", sys_wgt_base==7 && sys_act_base==8 && sys_out_base==9);
        repeat (7) ps();
        ps(); // RELEASE(6)
        check("T3: RELEASE state", state_debug == 6);
        ps(); // FETCH — dep processes release
        check("T3: tiles released", lock_status[7]==0 && lock_status[8]==0 && lock_status[9]==0);

        // ─────────────────────────────────────────────────────────────────
        // Test 4: NOP — no dep check, quick passthrough
        //   State: DECODE_W → CHECK → DISPATCH → FETCH
        // ─────────────────────────────────────────────────────────────────
        $display("--- Test 4: NOP passthrough ---");
        ps(); // DECODE_W (already in DECODE_W after T3's release check ps)
        check("T4: DECODE_W, opcode=NOP", state_debug==2 && opcode_debug==`OP_NOP);
        ps(); // CHECK (1 cycle only — NOP skips dep wait)
        check("T4: CHECK", state_debug == 3);
        ps(); // DISPATCH
        ps(); // FETCH done
        check("T4: NOP completed", state_debug == 1);
        check("T4: pc advanced", u_sys.u_dispatch.pc > 3);

        // ─────────────────────────────────────────────────────────────────
        // Summary
        // ─────────────────────────────────────────────────────────────────
        $display("");
        $display("--- RESULTS ---");
        $display("  Checks: %0d passed, %0d failed, %0d total",
                 pass_count, fail_count, pass_count + fail_count);
        if (errors === 0)
            $display("*** SYSTEM INTEGRATION TEST PASSED ***");
        else
            $display("*** SYSTEM INTEGRATION TEST FAILED ***");
        #100 $finish;
    end

endmodule
