`timescale 1ns / 1ps
`include "../src/instruction_defines.vh"

module tb_dispatch;

    parameter N = 4;
    parameter SLOT_DEPTH = 64;

    reg clk, rst;
    reg [`INST_WIDTH-1:0] ibram_inst;
    reg ibram_ready;
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

    dispatch_unit #(.N(N), .SLOT_DEPTH(SLOT_DEPTH)) uut (
        .clk(clk), .rst(rst),
        .pc_addr_in(0),
        .pc_addr(pc_addr), .inst_dout(ibram_inst), .pc_en(pc_en),
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

    initial begin
        $dumpfile("tb_dispatch.vcd");
        $dumpvars(0, tb_dispatch);

        clk = 0; rst = 1; ibram_inst = 0; ibram_ready = 1;
        dep_grant = 0; dep_conflict = 0;
        sys_busy = 0; sys_done = 0;
        errors = 0; pass_count = 0; fail_count = 0;

        #18 rst = 0; ps();

        $display("=== DISPATCH UNIT TEST (N=%0d, slot_depth=%0d) ===", N, SLOT_DEPTH);
        $display("");

        // ============================================================
        // Test 1: NOP
        // State cycle: IDLE → FETCH → DECODE_W → CHECK → DISPATCH → FETCH
        // After each ps, state_debug shows the state we WERE in.
        // ============================================================
        $display("--- Test 1: NOP ---");
        ibram_inst <= {`OP_NOP, 28'h0};
        ps(); check("T1: FETCH", state_debug == 1);
        ps(); check("T1: DECODE_W", state_debug == 2);
        ps(); check("T1: CHECK", state_debug == 3);
        ps(); check("T1: DISPATCH", state_debug == 4);
        ps(); check("T1: FETCH again", state_debug == 1);
        check("busy=1", busy == 1);

        // ============================================================
        // Test 2: MATMUL with dep_grant
        // After T1: state=DECODE_W
        // ============================================================
        $display("--- Test 2: MATMUL ---");
        ibram_inst <= {`OP_MATMUL, 8'h01, 8'h02, 8'h03, 4'h0};
        ps(); check("T2: DECODE_W", state_debug == 2);
        dep_grant <= 1;
        ps(); check("T2: CHECK", state_debug == 3);
        ps(); check("T2: DISPATCH", state_debug == 4);
        check("sys_start", sys_start == 1);
        check("wgt=1 act=2 out=3", sys_wgt_base==1 && sys_act_base==2 && sys_out_base==3);
        dep_grant <= 0;
        ps(); check("T2: WAIT_EXEC", state_debug == 5);
        sys_done <= 1;
        ps(); check("T2: WAIT_EXEC(2)", state_debug == 5);
        ps(); check("T2: RELEASE", state_debug == 6);
        check("dep_release_en", dep_release_en == 1);
        check("a=1 b=2 c=3", dep_release_a==1 && dep_release_b==2 && dep_release_c==3);
        check("num=3", dep_release_num == 3);
        sys_done <= 0;
        ps(); check("T2: FETCH", state_debug == 1);

        // ============================================================
        // Test 3: MATMUL with dep stall
        // After T2: state=DECODE_W
        // ============================================================
        $display("--- Test 3: MATMUL dep stall ---");
        ibram_inst <= {`OP_MATMUL, 8'h10, 8'h20, 8'h30, 4'h0};
        ps(); check("T3: DECODE_W", state_debug == 2);
        dep_grant <= 0;
        ps(); check("T3: CHECK (stall)", state_debug == 3);
        ps(); check("T3: CHECK (stall2)", state_debug == 3);
        ps(); check("T3: CHECK (stall3)", state_debug == 3);
        dep_grant <= 1;
        ps(); check("T3: CHECK (last)", state_debug == 3);
        ps(); check("T3: DISPATCH", state_debug == 4);
        dep_grant <= 0;
        ps(); check("T3: WAIT_EXEC", state_debug == 5);
        sys_done <= 1;
        ps(); // WAIT_EXEC
        ps(); check("T3: RELEASE", state_debug == 6);
        sys_done <= 0;
        ps(); check("T3: FETCH", state_debug == 1);

        // ============================================================
        // Test 4: LOOP count=3, target=2
        // count=3 => 3 iterations then fall through (4th encounter)
        // After T3: state=DECODE_W
        // ============================================================
        $display("--- Test 4: LOOP ---");
        ibram_inst <= {`OP_LOOP, 12'h003, 8'h02, 8'h01};
        ps(); check("T4: DECODE_W", state_debug == 2);
        ps(); check("T4: CHECK", state_debug == 3);
        ps(); check("T4: DISPATCH (init)", state_debug == 4);
        check("loop_remaining=2", loop_remaining_debug == 2);
        ps(); check("T4: LOOP_JUMP", state_debug == 7);
        check("pc_loop_jump=1", pc_loop_jump == 1);
        check("target=2", pc_loop_target == 2);
        // 2nd encounter
        ps(); check("T4: FETCH", state_debug == 1);
        ps(); check("T4: DECODE_W(2)", state_debug == 2);
        ps(); check("T4: CHECK(2)", state_debug == 3);
        ps(); check("T4: DISPATCH (2nd)", state_debug == 4);
        check("loop_remaining=1", loop_remaining_debug == 1);
        ps(); check("T4: LOOP_JUMP(2)", state_debug == 7);
        // 3rd encounter — still jumps (rem=1→0)
        ps(); check("T4: FETCH(3)", state_debug == 1);
        ps(); check("T4: DECODE_W(3)", state_debug == 2);
        ps(); check("T4: CHECK(3)", state_debug == 3);
        ps(); check("T4: DISPATCH (3rd)", state_debug == 4);
        check("loop_remaining=0", loop_remaining_debug == 0);
        ps(); check("T4: LOOP_JUMP(3)", state_debug == 7);
        // 4th encounter — fall through
        ps(); check("T4: FETCH(4)", state_debug == 1);
        ps(); check("T4: DECODE_W(4)", state_debug == 2);
        ps(); check("T4: CHECK(4)", state_debug == 3);
        ps(); check("T4: DISPATCH (4th)", state_debug == 4);
        check("loop_remaining=0 fallthrough", loop_remaining_debug == 0);
        ps(); check("T4: FETCH (fall through)", state_debug == 1);

        // ============================================================
        // Test 5: JUMP to 0x10
        // ============================================================
        $display("--- Test 5: JUMP ---");
        ibram_inst <= {`OP_JUMP, 12'h010, 12'h0, 4'h0};
        ps(); check("T5: DECODE_W", state_debug == 2);
        ps(); check("T5: CHECK", state_debug == 3);
        ps(); check("T5: DISPATCH", state_debug == 4);
        ps(); check("T5: LOOP_JUMP", state_debug == 7);
        check("pc_loop_target=16", pc_loop_target == 16);
        check("pc_loop_jump=1", pc_loop_jump == 1);
        ps(); check("T5: FETCH", state_debug == 1);

        // ============================================================
        // Test 6: BARRIER
        // ============================================================
        $display("--- Test 6: BARRIER ---");
        ibram_inst <= {`OP_BARRIER, 28'h0};
        ps(); check("T6: DECODE_W", state_debug == 2);
        ps(); check("T6: CHECK", state_debug == 3);
        ps(); check("T6: DISPATCH", state_debug == 4);
        ps(); check("T6: FETCH", state_debug == 1);

        // ============================================================
        // Test 7: LOAD
        // ============================================================
        $display("--- Test 7: LOAD ---");
        ibram_inst <= {`OP_LOAD, 12'hABC, 8'h77, 4'h0, 4'h3};
        ps(); check("T7: DECODE_W", state_debug == 2);
        dep_grant <= 1;
        ps(); check("T7: CHECK", state_debug == 3);
        ps(); check("T7: DISPATCH", state_debug == 4);
        dep_grant <= 0;
        ps(); check("T7: WAIT_EXEC", state_debug == 5);
        sys_done <= 1;
        ps(); // WAIT_EXEC
        ps(); check("T7: RELEASE", state_debug == 6);
        check("LOAD dep_release_en", dep_release_en == 1);
        sys_done <= 0;
        ps(); check("T7: FETCH", state_debug == 1);

        // ============================================================
        // Test 8: MATMUL tile release
        // ============================================================
        $display("--- Test 8: MATMUL release ---");
        ibram_inst <= {`OP_MATMUL, 8'h0A, 8'h0B, 8'h0C, 4'h0};
        dep_grant <= 1;
        ps(); check("T8: DECODE_W", state_debug == 2);
        ps(); check("T8: CHECK", state_debug == 3);
        ps(); check("T8: DISPATCH", state_debug == 4);
        dep_grant <= 0;
        ps(); check("T8: WAIT_EXEC", state_debug == 5);
        sys_done <= 1;
        ps(); // WAIT_EXEC
        ps(); check("T8: RELEASE", state_debug == 6);
        check("rel en", dep_release_en == 1);
        check("a=10 b=11 c=12", dep_release_a==10 && dep_release_b==11 && dep_release_c==12);
        check("num=3", dep_release_num == 3);
        sys_done <= 0;
        ps(); check("T8: FETCH", state_debug == 1);

        // ============================================================
        // Summary
        // ============================================================
        $display("");
        $display("--- RESULTS ---");
        $display("  Checks: %0d passed, %0d failed, %0d total",
                 pass_count, fail_count, pass_count + fail_count);
        if (errors === 0)
            $display("*** DISPATCH UNIT TEST PASSED ***");
        else
            $display("*** DISPATCH UNIT TEST FAILED ***");
        #100 $finish;
    end

endmodule
