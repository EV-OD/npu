`timescale 1ns / 1ps

module tb_readout;

    parameter N = 3;
    parameter ACCUM_WIDTH = 40;

    reg clk, rst, trigger;
    reg [(N*N*ACCUM_WIDTH)-1:0] pe_c;
    wire valid;
    wire [(N*N*ACCUM_WIDTH)-1:0] result;

    wire [(N*ACCUM_WIDTH)-1:0] shift_row;
    wire shift_valid;
    wire shift_done;

    readout_shifter #(.N(N), .ACCUM_WIDTH(ACCUM_WIDTH)) shift (
        .clk(clk), .rst(rst), .load(trigger),
        .pe_c(pe_c),
        .row_out(shift_row), .row_valid(shift_valid), .shift_done(shift_done)
    );

    readout_unit #(.N(N), .ACCUM_WIDTH(ACCUM_WIDTH)) rdout (
        .clk(clk), .rst(rst),
        .shift_valid(shift_valid), .row_in(shift_row),
        .valid(valid), .result(result)
    );

    always #5 clk = ~clk;

    integer i, j, errors, pass_count, fail_count;
    integer idx, r;

    task check;
        input [256:0] msg;
        input cond;
        begin
            if (!cond) begin
                $display("  FAIL: %s @ %0t", msg, $time);
                errors = errors + 1;
                fail_count = fail_count + 1;
            end else begin
                pass_count = pass_count + 1;
            end
        end
    endtask

    task ps;
        begin
            @(posedge clk);
            #1;
        end
    endtask

    task load_pe_values;
        input [31:0] base;
        begin
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin
                    idx = i*N + j;
                    pe_c[(idx * ACCUM_WIDTH) +: ACCUM_WIDTH] = (idx + 1) * base;
                end
            $display("  PE values loaded (base=%0d):", base);
            for (i = 0; i < N; i = i + 1) begin
                $write("    ");
                for (j = 0; j < N; j = j + 1) begin
                    idx = i*N + j;
                    $write("%0d ", (idx+1)*base);
                end
                $write("\n");
            end
        end
    endtask

    task verify_values;
        input [31:0] base;
        integer element_errors;
        begin
            element_errors = 0;
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin
                    idx = i*N + j;
                    if ($signed(result[(idx*ACCUM_WIDTH)+:ACCUM_WIDTH]) != (idx+1)*base) begin
                        $display("  FAIL: [%0d][%0d] exp=%0d got=%0d @ %0t",
                                 i, j, (idx+1)*base,
                                 $signed(result[(idx*ACCUM_WIDTH)+:ACCUM_WIDTH]), $time);
                        errors = errors + 1;
                        element_errors = element_errors + 1;
                        fail_count = fail_count + 1;
                    end else begin
                        pass_count = pass_count + 1;
                    end
                end
            if (element_errors == 0)
                $display("  All %0d values match (base=%0d)", N*N, base);
            else
                $display("  %0d / %0d values mismatch (base=%0d)", element_errors, N*N, base);
        end
    endtask

    task trigger_load;
        begin
            @(negedge clk);
            trigger = 1;
            ps();
            trigger = 0;
        end
    endtask

    initial begin
        $dumpfile("tb_readout.vcd");
        $dumpvars(0, tb_readout);

        clk = 0; rst = 1; trigger = 0; pe_c = 0;
        errors = 0; pass_count = 0; fail_count = 0;
        #18 rst = 0;
        ps();

        $display("=== READOUT CHAIN TEST (N=%0d, shifter+readout_unit) ===", N);
        $display("");

        // -------------------------------------------------------
        // Test 1: Reset state
        // -------------------------------------------------------
        $display("--- Test 1: Post-reset ---");
        check("reset: valid=0", valid == 0);
        check("reset: shift_valid=0", shift_valid == 0);

        // -------------------------------------------------------
        // Test 2: Trigger and capture all rows
        // -------------------------------------------------------
        $display("");
        $display("--- Test 2: Trigger + shift out %0d rows ---", N);
        load_pe_values(100);
        @(negedge clk);
        trigger = 1;
        ps();
        trigger = 0;

        // Wait for all N shift cycles + 1 for final assembly
        $display("  Waiting for %0d shift cycles...", N);
        repeat (N) @(posedge clk);
        #1;

        check("capture: valid=1", valid == 1);
        verify_values(100);

        // -------------------------------------------------------
        // Test 3: Hold after input changes
        // -------------------------------------------------------
        $display("");
        $display("--- Test 3: Hold after pe_c changes ---");
        pe_c = 0;
        ps();
        check("hold: valid still 1", valid == 1);
        verify_values(100);

        // -------------------------------------------------------
        // Test 4: Re-trigger with new values
        // -------------------------------------------------------
        $display("");
        $display("--- Test 4: Re-trigger ---");
        load_pe_values(200);
        @(negedge clk);
        trigger = 1;
        ps();
        trigger = 0;

        repeat (N) @(posedge clk);
        #1;

        check("re-trigger: valid=1", valid == 1);
        verify_values(200);

        // -------------------------------------------------------
        // Test 5: Back-to-back triggers
        // -------------------------------------------------------
        $display("");
        $display("--- Test 5: Back-to-back triggers ---");
        load_pe_values(300);
        trigger_load();

        // Wait N-1 cycles (rows 0 and 1 shift out)
        repeat (N-1) @(posedge clk);

        // Assert load in same cycle as last row (row 2)
        load_pe_values(400);
        trigger_load();

        // Wait N cycles for B to shift out and assemble
        repeat (N) @(posedge clk);
        #1;

        check("back-to-back: valid=1 after B", valid == 1);
        verify_values(400);

        // -------------------------------------------------------
        // Test 6: Early trigger (while still shifting)
        // -------------------------------------------------------
        $display("");
        $display("--- Test 6: Early trigger (reload while shifting) ---");
        load_pe_values(500);
        trigger_load();

        // Let one row shift out
        ps();

        // Early reload with new values while shifter is active
        load_pe_values(600);
        @(negedge clk);
        trigger = 1;
        ps();
        trigger = 0;

        // readout_unit captured A_row0 and A_row1 (on reload cycle).
        // B_row0 arrives next, completing row_idx=2 => valid=1
        @(posedge clk);
        #1;

        check("early trigger: valid=1", valid == 1);

        // Verify: row0=A_row0(500), row1=A_row1(500), row2=B_row0(600)
        begin
            integer got, exp, ee;
            ee = 0;
            for (j = 0; j < N; j = j + 1) begin
                exp = (j+1)*500;
                got = $signed(result[(j*ACCUM_WIDTH)+:ACCUM_WIDTH]);
                if (got !== exp) begin
                    $display("  FAIL: [0][%0d] exp=%0d got=%0d @ %0t", j, exp, got, $time);
                    errors = errors + 1; fail_count = fail_count + 1; ee = ee + 1;
                end else pass_count = pass_count + 1;
            end
            for (j = 0; j < N; j = j + 1) begin
                exp = (N+j+1)*500;
                got = $signed(result[((N+j)*ACCUM_WIDTH)+:ACCUM_WIDTH]);
                if (got !== exp) begin
                    $display("  FAIL: [1][%0d] exp=%0d got=%0d @ %0t", j, exp, got, $time);
                    errors = errors + 1; fail_count = fail_count + 1; ee = ee + 1;
                end else pass_count = pass_count + 1;
            end
            for (j = 0; j < N; j = j + 1) begin
                exp = (j+1)*600;
                got = $signed(result[((2*N+j)*ACCUM_WIDTH)+:ACCUM_WIDTH]);
                if (got !== exp) begin
                    $display("  FAIL: [2][%0d] exp=%0d got=%0d @ %0t", j, exp, got, $time);
                    errors = errors + 1; fail_count = fail_count + 1; ee = ee + 1;
                end else pass_count = pass_count + 1;
            end
            if (ee == 0) $display("  All %0d early-trigger values match", N*N);
            else $display("  %0d / %0d early-trigger mismatch", ee, N*N);
        end

        // Verify remaining B rows shift out correctly.
        // After valid=1, idx=1, with N-1 rows remaining.
        for (r = 1; r < N; r = r + 1) begin
            if (r == N-1)
                check("early: last B row valid", shift_valid == 1);
            else
                check("early: shift_valid during B", shift_valid == 1);
            ps();
        end
        check("early: shift complete", shift_valid == 0);

        // -------------------------------------------------------
        // Test 7: Reset during shift
        // -------------------------------------------------------
        $display("");
        $display("--- Test 7: Reset during shift ---");
        // Flush readout_unit by doing a clean trigger
        load_pe_values(700);
        trigger_load();
        repeat (N) @(posedge clk);
        #1;

        // Start a new shift and reset mid-way
        load_pe_values(800);
        trigger_load();
        ps(); // 1 row shifted

        rst = 1;
        ps();
        check("reset: row_out=0", shift_row == 0);
        check("reset: shift_valid=0", shift_valid == 0);
        check("reset: valid=0", valid == 0);
        check("reset: result=0", result == 0);

        rst = 0;
        ps();

        // -------------------------------------------------------
        // Test 8: shift_done timing
        // -------------------------------------------------------
        $display("");
        $display("--- Test 8: shift_done timing ---");
        load_pe_values(1000);
        trigger_load();

        ps();
        check("shift_done=0 during shift", shift_done == 0);
        ps();
        check("shift_done=0 before last", shift_done == 0);
        ps();
        check("shift_done=1 on last row", shift_done == 1);
        ps();
        check("shift_done=0 after done", shift_done == 0);

        // -------------------------------------------------------
        // Test 9: Negative values
        // -------------------------------------------------------
        $display("");
        $display("--- Test 9: Negative values ---");
        pe_c = 0;
        for (i = 0; i < N; i = i + 1)
            for (j = 0; j < N; j = j + 1) begin
                idx = i*N + j;
                pe_c[(idx * ACCUM_WIDTH) +: ACCUM_WIDTH] = -$signed((idx+1)*10);
            end
        $display("  Loaded negative PE values");
        trigger_load();
        repeat (N) @(posedge clk);
        #1;
        check("negative: valid=1", valid == 1);
        begin
            integer exp_val, neg_errors;
            neg_errors = 0;
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin
                    idx = i*N + j;
                    exp_val = -$signed((idx+1)*10);
                    if ($signed(result[(idx*ACCUM_WIDTH)+:ACCUM_WIDTH]) !== exp_val) begin
                        $display("  FAIL: [%0d][%0d] exp=%0d got=%0d @ %0t",
                                 i, j, exp_val,
                                 $signed(result[(idx*ACCUM_WIDTH)+:ACCUM_WIDTH]), $time);
                        errors = errors + 1;
                        fail_count = fail_count + 1;
                        neg_errors = neg_errors + 1;
                    end else begin
                        pass_count = pass_count + 1;
                    end
                end
            if (neg_errors == 0)
                $display("  All %0d negative values match", N*N);
            else
                $display("  %0d / %0d negative values mismatch", neg_errors, N*N);
        end

        // -------------------------------------------------------
        // Test 10: Maximum and minimum accumulator values
        // -------------------------------------------------------
        $display("");
        $display("--- Test 10: Maximum accumulator values ---");

        // Max 40-bit signed: (1<<39)-1 = 40'h7FFFFFFFFF
        pe_c = 0;
        for (idx = 0; idx < N*N; idx = idx + 1)
            pe_c[(idx * ACCUM_WIDTH) +: ACCUM_WIDTH] = {1'b0, {(ACCUM_WIDTH-1){1'b1}}};
        $display("  Loaded max values (40'h7FFFFFFFFF)");
        trigger_load();
        repeat (N) @(posedge clk);
        #1;
        check("max: valid=1", valid == 1);
        begin
            integer max_errors;
            max_errors = 0;
            for (idx = 0; idx < N*N; idx = idx + 1) begin
                if ($signed(result[(idx*ACCUM_WIDTH)+:ACCUM_WIDTH]) !=
                    $signed({1'b0, {(ACCUM_WIDTH-1){1'b1}}})) begin
                    $display("  FAIL: [%0d] exp=max got=%0d @ %0t",
                             idx, $signed(result[(idx*ACCUM_WIDTH)+:ACCUM_WIDTH]), $time);
                    errors = errors + 1;
                    fail_count = fail_count + 1;
                    max_errors = max_errors + 1;
                end else begin
                    pass_count = pass_count + 1;
                end
            end
            if (max_errors == 0)
                $display("  All %0d max values match", N*N);
            else
                $display("  %0d / %0d max values mismatch", max_errors, N*N);
        end

        // Min 40-bit signed: -(1<<39) = 40'h8000000000
        $display("  Loading min values (40'h8000000000)");
        pe_c = 0;
        for (idx = 0; idx < N*N; idx = idx + 1)
            pe_c[(idx * ACCUM_WIDTH) +: ACCUM_WIDTH] = {1'b1, {(ACCUM_WIDTH-1){1'b0}}};
        trigger_load();
        repeat (N) @(posedge clk);
        #1;
        check("min: valid=1", valid == 1);
        begin
            integer min_errors;
            min_errors = 0;
            for (idx = 0; idx < N*N; idx = idx + 1) begin
                if ($signed(result[(idx*ACCUM_WIDTH)+:ACCUM_WIDTH]) !=
                    $signed({1'b1, {(ACCUM_WIDTH-1){1'b0}}})) begin
                    $display("  FAIL: [%0d] exp=min got=%0d @ %0t",
                             idx, $signed(result[(idx*ACCUM_WIDTH)+:ACCUM_WIDTH]), $time);
                    errors = errors + 1;
                    fail_count = fail_count + 1;
                    min_errors = min_errors + 1;
                end else begin
                    pass_count = pass_count + 1;
                end
            end
            if (min_errors == 0)
                $display("  All %0d min values match", N*N);
            else
                $display("  %0d / %0d min values mismatch", min_errors, N*N);
        end

        // -------------------------------------------------------
        // Test 11: All zeros after load then new data
        // -------------------------------------------------------
        $display("");
        $display("--- Test 11: All zeros then new data ---");
        pe_c = 0;
        trigger_load();

        for (i = 0; i < N; i = i + 1) begin
            ps();
            check("zero shift: row_out=0", shift_row == 0);
        end
        #1;
        check("zero: valid=1", valid == 1);
        check("zero: result=0", result == 0);

        load_pe_values(900);
        trigger_load();
        repeat (N) @(posedge clk);
        #1;
        check("zero-then-new: valid=1", valid == 1);
        verify_values(900);

        // -------------------------------------------------------
        // Summary
        // -------------------------------------------------------
        $display("");
        $display("--- RESULTS ---");
        $display("  Checks: %0d passed, %0d failed, %0d total", pass_count, fail_count, pass_count+fail_count);
        if (errors == 0) begin
            $display("");
            $display("*** READOUT CHAIN TEST PASSED ***");
        end else begin
            $display("");
            $display("*** READOUT CHAIN TEST FAILED with %0d errors ***", errors);
        end
        $finish;
    end

endmodule
