`timescale 1ns / 1ps
`include "../src/instruction_defines.vh"

module tb_decoder;

    reg [`INST_WIDTH-1:0] inst;
    wire [3:0] opcode;
    wire [7:0] matmul_wt_tile, matmul_act_tile, matmul_out_tile;
    wire [11:0] ls_dram_addr;
    wire [7:0] ls_buf_tile;
    wire [3:0] ls_size;
    wire [11:0] loop_count;
    wire [7:0] loop_target, loop_stride;
    wire [11:0] jump_target;

    instruction_decoder uut (
        .instruction(inst),
        .opcode(opcode),
        .matmul_wt_tile(matmul_wt_tile),
        .matmul_act_tile(matmul_act_tile),
        .matmul_out_tile(matmul_out_tile),
        .ls_dram_addr(ls_dram_addr),
        .ls_buf_tile(ls_buf_tile),
        .ls_size(ls_size),
        .loop_count(loop_count),
        .loop_target(loop_target),
        .loop_stride(loop_stride),
        .jump_target(jump_target)
    );

    integer errors, pass_count, fail_count;

    task check;
        input [255:0] msg;
        input cond;
        begin
            if (cond) pass_count = pass_count + 1;
            else begin
                $display("  FAIL: %s @ %0t", msg, $time);
                errors = errors + 1; fail_count = fail_count + 1;
            end
        end
    endtask

    initial begin
        errors = 0; pass_count = 0; fail_count = 0;

        $display("=== INSTRUCTION DECODER TEST ===");
        $display("");

        // -------------------------------------------------------
        // Test 1: MATMUL decode
        // -------------------------------------------------------
        $display("--- Test 1: MATMUL ---");
        inst = {`OP_MATMUL, 8'ha5, 8'h5a, 8'h99, 4'h0};
        check("MATMUL opcode", opcode == `OP_MATMUL);
        check("wt_tile=a5", matmul_wt_tile == 8'ha5);
        check("act_tile=5a", matmul_act_tile == 8'h5a);
        check("out_tile=99", matmul_out_tile == 8'h99);

        // -------------------------------------------------------
        // Test 2: LOAD decode
        // -------------------------------------------------------
        $display("--- Test 2: LOAD ---");
        inst = {`OP_LOAD, 12'habc, 8'h77, 4'h0, 4'h3};
        check("LOAD opcode", opcode == `OP_LOAD);
        check("dram_addr=abc", ls_dram_addr == 12'habc);
        check("buf_tile=77", ls_buf_tile == 8'h77);
        check("size=3", ls_size == 4'h3);

        // -------------------------------------------------------
        // Test 3: STORE decode
        // -------------------------------------------------------
        $display("--- Test 3: STORE ---");
        inst = {`OP_STORE, 12'hdef, 8'h33, 4'h0, 4'h1};
        check("STORE opcode", opcode == `OP_STORE);
        check("dram_addr=def", ls_dram_addr == 12'hdef);
        check("buf_tile=33", ls_buf_tile == 8'h33);
        check("size=1", ls_size == 4'h1);

        // -------------------------------------------------------
        // Test 4: LOOP decode
        // -------------------------------------------------------
        $display("--- Test 4: LOOP ---");
        inst = {`OP_LOOP, 12'h3E8, 8'h00, 8'h08};  // count=1000, target=0, stride=8
        check("LOOP opcode", opcode == `OP_LOOP);
        check("count=3E8=1000", loop_count == 12'h3E8);
        check("target=00", loop_target == 8'h00);
        check("stride=08", loop_stride == 8'h08);

        // -------------------------------------------------------
        // Test 5: JUMP decode
        // -------------------------------------------------------
        $display("--- Test 5: JUMP ---");
        inst = {`OP_JUMP, 12'h040, 12'h0, 4'h0};
        check("JUMP opcode", opcode == `OP_JUMP);
        check("target=040", jump_target == 12'h040);

        // -------------------------------------------------------
        // Test 6: BARRIER decode
        // -------------------------------------------------------
        $display("--- Test 6: BARRIER ---");
        inst = {`OP_BARRIER, 28'h0};
        check("BARRIER opcode", opcode == `OP_BARRIER);

        // -------------------------------------------------------
        // Test 7: NOP decode
        // -------------------------------------------------------
        $display("--- Test 7: NOP ---");
        inst = {`OP_NOP, 28'hA5A5A5A};
        check("NOP opcode", opcode == `OP_NOP);

        // -------------------------------------------------------
        // Test 8: All zeros
        // -------------------------------------------------------
        $display("--- Test 8: All zeros ---");
        inst = 0;
        check("zero instr opcode=0", opcode == 4'h0);
        check("zero instr all fields=0", 
              matmul_wt_tile == 0 && matmul_act_tile == 0 && matmul_out_tile == 0 &&
              ls_dram_addr == 0 && ls_buf_tile == 0 && ls_size == 0 &&
              loop_count == 0 && loop_target == 0 && loop_stride == 0 &&
              jump_target == 0);

        // -------------------------------------------------------
        // Test 9: All ones
        // -------------------------------------------------------
        $display("--- Test 9: All ones ---");
        inst = 32'hFFFFFFFF;
        check("all ones opcode=F (NOP)", opcode == 4'hF);
        check("all ones matmul tiles=FF", matmul_wt_tile == 8'hFF && matmul_act_tile == 8'hFF && matmul_out_tile == 8'hFF);
        check("all ones loop fields=FFF/FF/FF", loop_count == 12'hFFF && loop_target == 8'hFF && loop_stride == 8'hFF);

        // -------------------------------------------------------
        // Test 10: Mixed fields — MATMUL boundary
        // -------------------------------------------------------
        $display("--- Test 10: MATMUL field boundaries ---");
        inst = {`OP_MATMUL, 8'h01, 8'h02, 8'h04, 4'h0};
        check("matmul wt=01", matmul_wt_tile == 8'h01);
        check("matmul act=02", matmul_act_tile == 8'h02);
        check("matmul out=04", matmul_out_tile == 8'h04);

        // -------------------------------------------------------
        // Test 11: LOAD with max address
        // -------------------------------------------------------
        $display("--- Test 11: LOAD max fields ---");
        inst = {`OP_LOAD, 12'hFFF, 8'hFF, 4'h0, 4'hF};
        check("LOAD dram_addr=FFF", ls_dram_addr == 12'hFFF);
        check("LOAD buf_tile=FF", ls_buf_tile == 8'hFF);
        check("LOAD size=F", ls_size == 4'hF);

        // -------------------------------------------------------
        // Test 12: LOOP max count
        // -------------------------------------------------------
        $display("--- Test 12: LOOP max count ---");
        inst = {`OP_LOOP, 12'hFFF, 8'h3F, 8'h3F};
        check("LOOP count=FFF", loop_count == 12'hFFF);
        check("LOOP target=3F", loop_target == 8'h3F);
        check("LOOP stride=3F", loop_stride == 8'h3F);

        // -------------------------------------------------------
        // Test 13: Rapid opcode switching
        // -------------------------------------------------------
        $display("--- Test 13: Opcode switching ---");
        inst = {`OP_NOP, 28'h0};
        #1;
        check("opcode=NOP", opcode == `OP_NOP);
        inst = {`OP_MATMUL, 8'h10, 8'h20, 8'h30, 4'h0};
        #1;
        check("opcode=MATMUL after NOP", opcode == `OP_MATMUL);
        check("wt=10 after switch", matmul_wt_tile == 8'h10);
        check("act=20 after switch", matmul_act_tile == 8'h20);
        check("out=30 after switch", matmul_out_tile == 8'h30);
        inst = {`OP_LOOP, 12'h100, 8'h10, 8'h04};
        #1;
        check("opcode=LOOP after MATMUL", opcode == `OP_LOOP);
        check("loop count=100", loop_count == 12'h100);

        // -------------------------------------------------------
        // Summary
        // -------------------------------------------------------
        $display("");
        $display("--- RESULTS ---");
        $display("  Checks: %0d passed, %0d failed, %0d total",
                 pass_count, fail_count, pass_count + fail_count);
        if (errors === 0)
            $display("*** DECODER TEST PASSED ***");
        else
            $display("*** DECODER TEST FAILED ***");
        #100 $finish;
    end

endmodule
