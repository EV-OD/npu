`timescale 1ns / 1ps
`include "../src/instruction_defines.vh"

module tb_instruction_pipeline;

    parameter N = 4;
    parameter SLOT_DEPTH = 64;

    // IBRAM signals
    reg clk, rst;
    reg dma_en, dma_we;
    reg [6:0] dma_addr;
    reg [31:0] dma_din;
    wire [31:0] pc_dout;
    wire active_slot;
    wire ibram_ready;

    // Dispatch unit signals
    reg dep_grant;
    reg [7:0] dep_conflict;
    reg sys_busy, sys_done;
    wire [$clog2(SLOT_DEPTH)-1:0] pc_addr;
    wire pc_en;
    wire dep_check_en, dep_release_en;
    wire [7:0] dep_tile_a, dep_tile_b, dep_tile_c;
    wire [1:0] dep_num_tiles, dep_release_num;
    wire [7:0] dep_release_a, dep_release_b, dep_release_c;
    wire sys_start;
    wire [31:0] sys_matrix_size, sys_act_base, sys_wgt_base, sys_out_base;
    wire swap_req, pc_loop_jump;
    wire [$clog2(SLOT_DEPTH)-1:0] pc_loop_target;
    wire busy;
    wire [3:0] state_debug, opcode_debug;
    wire [11:0] loop_remaining_debug;

    // IBRAM instance
    ibram #(.SLOT_DEPTH(SLOT_DEPTH)) u_ibram (
        .clk(clk), .rst(rst),
        .dma_en(dma_en), .dma_we(dma_we),
        .dma_addr(dma_addr), .dma_din(dma_din),
        .pc_en(pc_en), .pc_addr(pc_addr),
        .pc_dout(pc_dout),
        .active_slot(active_slot),
        .ready(ibram_ready),
        .swap(swap_req)
    );

    // Dispatch unit
    dispatch_unit #(.N(N), .SLOT_DEPTH(SLOT_DEPTH)) u_dispatch (
        .clk(clk), .rst(rst),
        .pc_addr_in(0),
        .pc_addr(pc_addr), .inst_dout(pc_dout), .pc_en(pc_en),
        .dep_check_en(dep_check_en), .dep_tile_a(dep_tile_a),
        .dep_tile_b(dep_tile_b), .dep_tile_c(dep_tile_c),
        .dep_num_tiles(dep_num_tiles),
        .dep_grant(dep_grant), .dep_conflict(dep_conflict),
        .dep_release_en(dep_release_en),
        .dep_release_a(dep_release_a), .dep_release_b(dep_release_b), .dep_release_c(dep_release_c),
        .dep_release_num(dep_release_num),
        .sys_start(sys_start), .sys_matrix_size(sys_matrix_size),
        .sys_act_base(sys_act_base), .sys_wgt_base(sys_wgt_base), .sys_out_base(sys_out_base),
        .sys_busy(sys_busy), .sys_done(sys_done),
        .pc_loop_jump(pc_loop_jump), .pc_loop_target(pc_loop_target),
        .swap_req(swap_req), .ibram_ready(ibram_ready),
        .busy(busy), .state_debug(state_debug), .opcode_debug(opcode_debug),
        .loop_remaining_debug(loop_remaining_debug)
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

    // Mock execution: when sys_start, busy for EXEC_CYCLES then done
    reg [3:0] exec_count;
    reg exec_active;
    always @(posedge clk) begin
        if (rst) begin
            exec_active <= 0; exec_count <= 0;
            sys_busy <= 0; sys_done <= 0;
        end else begin
            sys_done <= 0;
            if (sys_start) begin
                exec_active <= 1; exec_count <= 4; sys_busy <= 1; // 4 cycle exec
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
        $dumpfile("tb_instruction_pipeline.vcd");
        $dumpvars(0, tb_instruction_pipeline);

        clk = 0; rst = 1;
        dma_en = 0; dma_we = 0; dma_addr = 0; dma_din = 0;
        dep_grant = 0; dep_conflict = 0;
        errors = 0; pass_count = 0; fail_count = 0;

        #18 rst = 0; ps();

        $display("=== INSTRUCTION PIPELINE INTEGRATION TEST ===");
        $display("");

        // ---------------------------------------------------------------
        // Program IBRAM: fill Slot A (addr 0-63) and Slot B (addr 64-127)
        // ---------------------------------------------------------------
        $display("Loading IBRAM...");

        // Slot A program:
        //   0: MATMUL(wt=1, act=2, out=3)
        //   1: MATMUL(wt=10, act=12, out=30)
        //   2: NOP
        //   3-63: NOP

        dma_write(0, {`OP_MATMUL, 8'h01, 8'h02, 8'h03, 4'h0});  // MATMUL(1,2,3)
        dma_write(1, {`OP_MATMUL, 8'h0A, 8'h0C, 8'h1E, 4'h0});  // MATMUL(10,12,30)
        dma_write(2, {`OP_NOP, 28'h0});                          // NOP
        // Fill rest of Slot A with NOPs
        for (integer i = 3; i < SLOT_DEPTH; i = i + 1)
            dma_write(i, {`OP_NOP, 28'h0});

        $display("  Slot A loaded (%0d words)", SLOT_DEPTH);

        // Fill Slot B with NOPs (needed for swap readiness)
        for (integer i = 0; i < SLOT_DEPTH; i = i + 1)
            dma_write(SLOT_DEPTH + i, {`OP_NOP, 28'h0});

        $display("  Slot B loaded (%0d words)", SLOT_DEPTH);
        $display("  ibram_ready=%0d (will be 1 after cycle)", ibram_ready);
        ps(); // Let ibram_ready update (NBA for ready used old slot_b_full)
        check("ibram_ready after DMA", ibram_ready == 1);

        // ---------------------------------------------------------------
        // Test 1: Execute MATMUL(1,2,3) from IBRAM
        // ---------------------------------------------------------------
        $display("");
        $display("--- Test 1: MATMUL(1,2,3) from IBRAM ---");
        ps(); // IDLE (ibram_ready NBA hasn't applied yet — stays IDLE)
        ps(); // FETCH(1)
        ps(); // DECODE_W(2) — MATMUL captured

        // At this point, we see the first instruction is MATMUL
        check("T1: DECODE_W, opcode=MATMUL", state_debug == 2 && opcode_debug == `OP_MATMUL);

        // Provide dep grant
        dep_grant <= 1;
        ps(); // CHECK(3)
        check("T1: CHECK", state_debug == 3);
        ps(); // DISPATCH(4) — sys_start should fire
        check("T1: DISPATCH, sys_start", state_debug == 4 && sys_start == 1);
        check("T1: wgt=1 act=2 out=3", sys_wgt_base==1 && sys_act_base==2 && sys_out_base==3);
        dep_grant <= 0;
        repeat (7) begin ps(); end
        ps(); // RELEASE(6)
        check("T1: RELEASE state", state_debug == 6);
        check("T1: dep_release_en", dep_release_en == 1);
        check("T1: release tiles 1/2/3", dep_release_a==1 && dep_release_b==2 && dep_release_c==3);

        ps(); // FETCH(1) — next instruction

        // ---------------------------------------------------------------
        // Test 2: Execute MATMUL(10,12,30) from IBRAM (no dependency conflict)
        // ---------------------------------------------------------------
        $display("--- Test 2: MATMUL(10,12,30) from IBRAM ---");
        ps(); // DECODE_W(2) — MATMUL captured
        check("T2: DECODE_W, opcode=MATMUL", state_debug == 2 && opcode_debug == `OP_MATMUL);
        dep_grant <= 1;
        ps(); // CHECK(3)
        ps(); // DISPATCH(4)
        check("T2: DISPATCH, wgt=10 act=12 out=30",
              sys_wgt_base==10 && sys_act_base==12 && sys_out_base==30);
        dep_grant <= 0;
        repeat (7) ps();
        ps(); // RELEASE(6)
        check("T2: RELEASE state", state_debug == 6);
        check("T2: release tiles 10/12/30", dep_release_a==10 && dep_release_b==12 && dep_release_c==30);

        ps(); // FETCH(1)

        // ---------------------------------------------------------------
        // Test 3: Execute NOP from IBRAM
        // ---------------------------------------------------------------
        $display("--- Test 3: NOP from IBRAM ---");
        ps(); // DECODE_W(2)
        check("T3: DECODE_W, opcode=NOP", state_debug == 2 && opcode_debug == `OP_NOP);
        ps(); // CHECK(3)
        ps(); // DISPATCH(4)
        ps(); // FETCH(1)
        check("T3: NOP completed", state_debug == 1);

        // ---------------------------------------------------------------
        // Test 4: Verify multiple NOPs from IBRAM (remaining instructions)
        // ---------------------------------------------------------------
        $display("--- Test 4: NOPs from IBRAM ---");
        // We're now at address 3 in IBRAM (after MATMUL(1,2,3) at 0,
        // MATMUL(10,12,30) at 1, NOP at 2). Remaining is all NOPs.
        // Let a few NOPs execute and verify FETCH cycles
        ps(); // DECODE_W
        ps(); // CHECK
        ps(); // DISPATCH
        ps(); // FETCH — NOP done
        ps(); // DECODE_W — next NOP
        ps(); // CHECK
        ps(); // DISPATCH
        ps(); // FETCH — NOP done
        check("T4: NOPs executing sequentially", state_debug == 1);
        check("busy active", busy == 1);
        check("pc_dout still NOP", pc_dout[31:28] == `OP_NOP);

        // ---------------------------------------------------------------
        // Summary
        // ---------------------------------------------------------------
        $display("");
        $display("--- RESULTS ---");
        $display("  Checks: %0d passed, %0d failed, %0d total",
                 pass_count, fail_count, pass_count + fail_count);
        if (errors === 0)
            $display("*** INSTRUCTION PIPELINE INTEGRATION TEST PASSED ***");
        else
            $display("*** INSTRUCTION PIPELINE INTEGRATION TEST FAILED ***");
        #100 $finish;
    end

endmodule
