`timescale 1ns / 1ps

module tb_output_buffer;

    parameter N = 3;
    parameter ACCUM_WIDTH = 40;

    reg clk, rst;
    reg we;
    reg [$clog2(2*N)-1:0] waddr;
    reg signed [(N*ACCUM_WIDTH)-1:0] row_in;
    reg [$clog2(2*N)-1:0] raddr;
    wire signed [(N*ACCUM_WIDTH)-1:0] dout;

    output_buffer #(.N(N), .ACCUM_WIDTH(ACCUM_WIDTH)) uut (
        .clk(clk), .rst(rst),
        .we(we), .waddr(waddr), .row_in(row_in),
        .raddr(raddr), .dout(dout)
    );

    always #5 clk = ~clk;

    integer i, j, errors, pass_count, fail_count;
    integer idx;

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

    task load_row;
        input integer r;
        input [31:0] base;
        integer c;
        begin
            for (c = 0; c < N; c = c + 1)
                row_in[(c*ACCUM_WIDTH) +: ACCUM_WIDTH] = (r*N + c + 1) * base;
        end
    endtask

    task verify_row;
        input integer r;
        input [31:0] base;
        integer c;
        integer errs;
        begin
            errs = 0;
            for (c = 0; c < N; c = c + 1) begin
                if ($signed(dout[(c*ACCUM_WIDTH) +: ACCUM_WIDTH]) != (r*N + c + 1) * base) begin
                    $display("  FAIL: row%0d[%0d] exp=%0d got=%0d @ %0t",
                             r, c, (r*N + c + 1) * base,
                             $signed(dout[(c*ACCUM_WIDTH) +: ACCUM_WIDTH]), $time);
                    errors = errors + 1;
                    errs = errs + 1;
                    fail_count = fail_count + 1;
                end else begin
                    pass_count = pass_count + 1;
                end
            end
            if (errs == 0)
                $display("  row %0d correct (base=%0d)", r, base);
        end
    endtask

    initial begin
        $dumpfile("tb_output_buffer.vcd");
        $dumpvars(0, tb_output_buffer);

        clk = 0; rst = 1; we = 0; waddr = 0; row_in = 0; raddr = 0;
        errors = 0; pass_count = 0; fail_count = 0;

        #18 rst = 0;
        ps();

        $display("=== OUTPUT BUFFER TEST (N=%0d) ===", N);
        $display("");

        // Test 1: Reset → all zeros
        $display("--- Test 1: Post-reset zeros ---");
        raddr = 0; #1;
        check("row0[0]=0", $signed(dout[0*ACCUM_WIDTH +: ACCUM_WIDTH]) == 0);

        // Test 2: Write rows sequentially, read back
        $display("");
        $display("--- Test 2: Sequential row writes ---");
        for (i = 0; i < N; i = i + 1) begin
            @(negedge clk);
            load_row(i, 100);
            we = 1;
            waddr = i;
            ps();
            we = 0;
        end

        for (i = 0; i < N; i = i + 1) begin
            raddr = i;
            #1;
            verify_row(i, 100);
        end

        // Test 3: Overwrite a row
        $display("");
        $display("--- Test 3: Overwrite row 1 ---");
        @(negedge clk);
        load_row(1, 999);
        we = 1;
        waddr = 1;
        ps();
        we = 0;

        raddr = 1;
        #1;
        verify_row(1, 999);

        // Test 4: Other rows unchanged after overwrite
        $display("");
        $display("--- Test 4: Verify row 0 unchanged ---");
        raddr = 0;
        #1;
        verify_row(0, 100);

        // Test 5: Write all rows in reverse order
        $display("");
        $display("--- Test 5: Reverse order writes ---");
        for (i = N-1; i >= 0; i = i - 1) begin
            @(negedge clk);
            load_row(i, 200 + i);
            we = 1;
            waddr = i;
            ps();
            we = 0;
        end

        for (i = 0; i < N; i = i + 1) begin
            raddr = i;
            #1;
            verify_row(i, 200 + i);
        end

        $display("");
        $display("--- RESULTS ---");
        $display("  Checks: %0d passed, %0d failed, %0d total", pass_count, fail_count, pass_count+fail_count);
        if (errors == 0) begin
            $display("");
            $display("*** OUTPUT BUFFER TEST PASSED ***");
        end else begin
            $display("");
            $display("*** OUTPUT BUFFER TEST FAILED with %0d errors ***", errors);
        end
        $finish;
    end

endmodule
