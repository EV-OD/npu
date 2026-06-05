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

    // ── State name for debug ────────────────────────────────────────────
    function [95:0] state_name;
        input [3:0] s;
        begin
            case (s)
                0: state_name = "IDLE       ";
                1: state_name = "FETCH      ";
                2: state_name = "DECODE_W   ";
                3: state_name = "CHECK      ";
                4: state_name = "DISPATCH   ";
                5: state_name = "WAIT_EXEC  ";
                6: state_name = "RELEASE    ";
                7: state_name = "LOOP_JUMP  ";
                default: state_name = "?????????? ";
            endcase
        end
    endfunction

    // ── Opcode name for debug ───────────────────────────────────────────
    function [63:0] op_name;
        input [3:0] op;
        begin
            case (op)
                `OP_MATMUL:  op_name = "MATMUL ";
                `OP_LOAD:    op_name = "LOAD   ";
                `OP_STORE:   op_name = "STORE  ";
                `OP_LOOP:    op_name = "LOOP   ";
                `OP_JUMP:    op_name = "JUMP   ";
                `OP_BARRIER: op_name = "BARRIER";
                `OP_NOP:     op_name = "NOP    ";
                default:     op_name = "???    ";
            endcase
        end
    endfunction

    // ── Verbose cycle: show state + key signals after clock edge ────────
    task ps_dbg;
        input string desc;
        reg [3:0] s;
        reg [3:0] op;
        begin
            @(posedge clk);
            // Capture pre-NBA state for reference (state about to transition from)
            s = state_debug;
            op = opcode_debug;
            #1;
            // After #1, NBAs have taken effect — show the state we were IN
            // (state_debug was set by case(state) at posedge, visible now)
            $write("  [%0t] %s", $time, desc);
            $write("  state=%-12s", state_name(s));
            $write(" opcode=%-8s", op_name(op));
            if (busy) $write(" busy");
            if (u_sys.u_dispatch.pc_en) $write(" pc_addr=%0d", u_sys.u_dispatch.pc_addr);
            $write(" inst=%08h", u_sys.u_ibram.pc_dout);
            if (sys_start) $write(" sys_start");
            if (sys_done)  $write(" sys_done=%d", sys_done);
            if (u_sys.u_dep.check_lock_grant) $write(" dep_grant");
            if (u_sys.u_dep.conflict_tile != 0)
                $write(" conflict=%0d", u_sys.u_dep.conflict_tile);
            if (u_sys.u_dispatch.dep_check_en)   $write(" chk_en");
            if (u_sys.u_dispatch.dep_release_en) $write(" rel_en");
            $write("  tiles[1..9]=");
            for (integer t = 1; t <= 9; t = t + 1)
                $write("%d", lock_status[t]);
            $display("");
        end
    endtask

    // ── Aliases ─────────────────────────────────────────────────────────
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

    // ── Mock execution unit (4-cycle exec) ──────────────────────────────
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

    task check;
        input string msg;
        input cond;
        begin
            if (cond) begin
                pass_count = pass_count + 1;
                $write("  PASS");
            end else begin
                $write("  FAIL");
                errors = errors + 1; fail_count = fail_count + 1;
            end
            $display(": %s", msg);
        end
    endtask

    initial begin
        $dumpfile("tb_system.vcd");
        $dumpvars(0, tb_system);

        clk = 0; rst = 1;
        dma_en = 0; dma_we = 0; dma_addr = 0; dma_din = 0;
        errors = 0; pass_count = 0; fail_count = 0;

        #18 rst = 0; ps_dbg("Reset deasserted");

        $display("");
        $display("=== SYSTEM INTEGRATION TEST (VERBOSE) ===");
        $display("");

        // ═════════════════════════════════════════════════════════════════
        // PROGRAM IBRAM
        // ═════════════════════════════════════════════════════════════════
        $display("─── Loading IBRAM ────────────────────────────────────────");
        $display("");
        $display("  Slot A program:");
        $display("    [0] MATMUL(wt=1,  act=2,  out=3)");
        $display("    [1] MATMUL(wt=1,  act=5,  out=6)   <-- shares tile 1 with [0]");
        $display("    [2] MATMUL(wt=7,  act=8,  out=9)");
        $display("    [3] NOP");
        $display("    [4..63] NOP (fill)");
        $display("");

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
        $display("  ibram_ready=%0d (NBA pending — will be 1 after next posedge)", ibram_ready);

        ps_dbg("Wait for ibram_ready NBA");
        check("ibram_ready after DMA", ibram_ready == 1);
        $display("");

        // ═════════════════════════════════════════════════════════════════
        // TEST 1: MATMUL(1,2,3) — full lifecycle
        //   Fetch from IBRAM addr 0 → decode → check deps (no conflict)
        //   → dispatch to exec → wait 7 cycles → release tiles
        // ═════════════════════════════════════════════════════════════════
        $display("═══════════════════════════════════════════════════════════");
        $display("  TEST 1: MATMUL(wt=1, act=2, out=3)  — full lifecycle");
        $display("═══════════════════════════════════════════════════════════");
        $display("");

        // After `ps_dbg` above, state=IDLE (ibram_ready was applied AFTER that posedge)
        ps_dbg("(IDLE)    ibram_ready=1 now, IDLE→FETCH next");
        // State should still be IDLE (nxt→FETCH applied at this posedge)

        ps_dbg("(FETCH)   pc_en=1, IBRAM reads mem[pc]");
        // State=Fetch, pc_en=1, IBRAM reads addr 0 → pc_dout = MATMUL(1,2,3) at negedge

        ps_dbg("(DECODE_W) Decoding instruction");
        check("T1: DECODE_W, opcode=MATMUL", state_debug==2 && opcode_debug==`OP_MATMUL);

        // ── CHECK phase (3 cycles: assert→process→advance) ──────────────
        $display("  --- CHECK phase (dep checker handshake) ---");

        ps_dbg("(CHECK#1) dep_check_en asserted (NBA), dep not yet processed");
        check("T1: CHECK(1) state", state_debug == 3);

        ps_dbg("(CHECK#2) dep checker evaluates: all_free(1,2,3)=1 → grant");
        check("T1: CHECK(2) state", state_debug == 3);
        check("T1: dep checker granted", u_sys.u_dep.check_lock_grant == 1);
        check("T1: tiles locked by dep checker",
              lock_status[1] && lock_status[2] && lock_status[3]);

        ps_dbg("(CHECK#3) dispatch sees dep_grant=1, nxt→DISPATCH");
        check("T1: CHECK(3) → about to leave CHECK", state_debug == 3);

        // ── DISPATCH ────────────────────────────────────────────────────
        $display("  --- DISPATCH ---");

        ps_dbg("(DISPATCH) sys_start=1, sys params driven");
        check("T1: DISPATCH state", state_debug == 4);
        check("T1: sys_start pulsed", sys_start == 1);
        check("T1: sys_wgt_base=1", sys_wgt_base == 1);
        check("T1: sys_act_base=2", sys_act_base == 2);
        check("T1: sys_out_base=3", sys_out_base == 3);

        // ── WAIT_EXEC (7 cycles: mock exec runs 4→3→2→1→0→done, then nxt update)
        $display("  --- WAIT_EXEC (4-cycle mock exec) ---");

        ps_dbg("(WAIT#1)  exec_count loaded? no — sys_start was just set via NBA, seen next cycle");
        ps_dbg("(WAIT#2)  exec_count=4 → 3  (sys_start seen now)");
        ps_dbg("(WAIT#3)  exec_count=3 → 2");
        ps_dbg("(WAIT#4)  exec_count=2 → 1");
        ps_dbg("(WAIT#5)  exec_count=1 → 0");
        ps_dbg("(WAIT#6)  exec_count=0 → sys_done=1 (NBA)");
        ps_dbg("(WAIT#7)  dispatch sees sys_done=1, nxt→RELEASE");

        // ── RELEASE ─────────────────────────────────────────────────────
        $display("  --- RELEASE ---");

        ps_dbg("(RELEASE)  dep_release_en=1, tiles being released");
        check("T1: RELEASE state", state_debug == 6);

        // Dep checker processes release on the NEXT posedge (NBA delay)
        ps_dbg("(FETCH)    dep processes release, tiles unlocked");
        check("T1: tiles 1,2,3 released",
              lock_status[1]==0 && lock_status[2]==0 && lock_status[3]==0);

        $display("");

        // ═════════════════════════════════════════════════════════════════
        // TEST 2: MATMUL(1,5,6) — sequential (no conflict, T1 released)
        // ═════════════════════════════════════════════════════════════════
        $display("═══════════════════════════════════════════════════════════");
        $display("  TEST 2: MATMUL(wt=1, act=5, out=6)  — sequential");
        $display("  (same tile 1, but T1 already released — no conflict)");
        $display("═══════════════════════════════════════════════════════════");
        $display("");

        // After T1's FETCH ps: state=DECODE_W, pc_dout holds instruction at addr 1
        ps_dbg("(DECODE_W) Decoding MATMUL(1,5,6) from IBRAM addr 1");
        check("T2: DECODE_W, opcode=MATMUL", state_debug==2 && opcode_debug==`OP_MATMUL);

        ps_dbg("(CHECK#1)  dep_check_en asserted");
        ps_dbg("(CHECK#2)  dep evaluates: all tiles free → grant");
        check("T2: dep checker granted", u_sys.u_dep.check_lock_grant == 1);
        check("T2: tiles 1,5,6 locked",
              lock_status[1] && lock_status[5] && lock_status[6]);
        ps_dbg("(CHECK#3)  nxt→DISPATCH");

        ps_dbg("(DISPATCH) sys params for MATMUL(1,5,6)");
        check("T2: DISPATCH state", state_debug == 4);
        check("T2: sys_wgt_base=1",  sys_wgt_base == 1);
        check("T2: sys_act_base=5",  sys_act_base == 5);
        check("T2: sys_out_base=6",  sys_out_base == 6);
        check("T2: sys_start pulsed", sys_start == 1);

        ps_dbg("(WAIT#1)  exec starts");
        ps_dbg("(WAIT#2)  count 4→3");
        ps_dbg("(WAIT#3)  count 3→2");
        ps_dbg("(WAIT#4)  count 2→1");
        ps_dbg("(WAIT#5)  count 1→0");
        ps_dbg("(WAIT#6)  count 0→sys_done=1");
        ps_dbg("(WAIT#7)  nxt→RELEASE");

        ps_dbg("(RELEASE)  releasing tiles 1,5,6");
        check("T2: RELEASE state", state_debug == 6);

        ps_dbg("(FETCH)    dep processes release");
        check("T2: tiles 1,5,6 released",
              lock_status[1]==0 && lock_status[5]==0 && lock_status[6]==0);

        $display("");

        // ═════════════════════════════════════════════════════════════════
        // TEST 3: MATMUL(7,8,9) — sequential
        // ═════════════════════════════════════════════════════════════════
        $display("═══════════════════════════════════════════════════════════");
        $display("  TEST 3: MATMUL(wt=7, act=8, out=9)  — sequential");
        $display("═══════════════════════════════════════════════════════════");
        $display("");

        ps_dbg("(DECODE_W) Decoding MATMUL(7,8,9) from IBRAM addr 2");
        check("T3: DECODE_W, opcode=MATMUL", state_debug==2 && opcode_debug==`OP_MATMUL);

        ps_dbg("(CHECK#1)  dep_check_en asserted");
        ps_dbg("(CHECK#2)  dep grants, tiles 7,8,9 locked");
        check("T3: tiles 7,8,9 locked",
              lock_status[7] && lock_status[8] && lock_status[9]);
        ps_dbg("(CHECK#3)  nxt→DISPATCH");

        ps_dbg("(DISPATCH) sys params for MATMUL(7,8,9)");
        check("T3: DISPATCH state", state_debug == 4);
        check("T3: sys_wgt_base=7",  sys_wgt_base == 7);
        check("T3: sys_act_base=8",  sys_act_base == 8);
        check("T3: sys_out_base=9",  sys_out_base == 9);

        ps_dbg("(WAIT#1)");
        ps_dbg("(WAIT#2)");
        ps_dbg("(WAIT#3)");
        ps_dbg("(WAIT#4)");
        ps_dbg("(WAIT#5)");
        ps_dbg("(WAIT#6)");
        ps_dbg("(WAIT#7)");

        ps_dbg("(RELEASE)");
        check("T3: RELEASE state", state_debug == 6);

        ps_dbg("(FETCH)    dep processes release");
        check("T3: tiles 7,8,9 released",
              lock_status[7]==0 && lock_status[8]==0 && lock_status[9]==0);

        $display("");

        // ═════════════════════════════════════════════════════════════════
        // TEST 4: NOP — fast passthrough (no dep check, no WAIT_EXEC)
        // ═════════════════════════════════════════════════════════════════
        $display("═══════════════════════════════════════════════════════════");
        $display("  TEST 4: NOP  — dispatch bypasses dep/exec");
        $display("═══════════════════════════════════════════════════════════");
        $display("");

        ps_dbg("(DECODE_W) Decoding NOP from IBRAM addr 3");
        check("T4: DECODE_W, opcode=NOP", state_debug==2 && opcode_debug==`OP_NOP);

        $display("  --- NOP: CHECK (no dep — NOP goes directly to DISPATCH) ---");
        ps_dbg("(CHECK)    NOP skips dep wait");
        check("T4: CHECK state", state_debug == 3);

        $display("  --- NOP: DISPATCH (nop → back to FETCH) ---");
        ps_dbg("(DISPATCH) NOP dispatched, nxt=FETCH");

        $display("  --- NOP: FETCH (instruction complete) ---");
        ps_dbg("(FETCH)    NOP done, next instruction fetch begins");
        check("T4: NOP completed", state_debug == 1);
        check("T4: pc advanced past first 3 instructions",
              u_sys.u_dispatch.pc > 3);

        $display("");

        // ═════════════════════════════════════════════════════════════════
        // SUMMARY
        // ═════════════════════════════════════════════════════════════════
        $display("═══════════════════════════════════════════════════════════");
        $display("  RESULTS");
        $display("═══════════════════════════════════════════════════════════");
        $display("  Checks: %0d passed, %0d failed, %0d total",
                 pass_count, fail_count, pass_count + fail_count);
        if (errors === 0)
            $display("  *** SYSTEM INTEGRATION TEST PASSED ***");
        else
            $display("  *** SYSTEM INTEGRATION TEST FAILED ***");
        $display("═══════════════════════════════════════════════════════════");
        #100 $finish;
    end

endmodule
