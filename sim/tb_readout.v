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

    readout_shifter #(.N(N), .ACCUM_WIDTH(ACCUM_WIDTH)) shift (
        .clk(clk), .rst(rst), .load(trigger),
        .pe_c(pe_c),
        .row_out(shift_row), .row_valid(shift_valid), .shift_done()
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
