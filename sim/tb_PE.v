`timescale 1ns/1ps

module tb_PE;

    parameter DATA_WIDTH = 16;
    parameter ACCUM_WIDTH = 40;

    reg clk;
    reg rst;
    reg signed [DATA_WIDTH-1:0] in_x;
    reg signed [DATA_WIDTH-1:0] in_y;
    wire signed [DATA_WIDTH-1:0] out_x;
    wire signed [DATA_WIDTH-1:0] out_y;
    wire signed [ACCUM_WIDTH-1:0] out_c;

    PE #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH)
    ) uut (
        .clk(clk),
        .rst(rst),
        .in_x(in_x),
        .in_y(in_y),
        .out_x(out_x),
        .out_y(out_y),
        .out_c(out_c)
    );

    always #10 clk = ~clk;

    integer   errors;
    integer   cycle_cnt;

    reg signed [DATA_WIDTH-1:0]  hist_x [0:31];
    reg signed [DATA_WIDTH-1:0]  hist_y [0:31];

    // Drive (x,y) on each negedge.
    // At negedge N, out_x/out_y reflect inputs from N-2 negedges ago.
    // out_c reflects the running accumulation of all products from N-4 negedges ago.
    task cycle;
        input signed [DATA_WIDTH-1:0] x;
        input signed [DATA_WIDTH-1:0] y;
        reg signed [ACCUM_WIDTH-1:0] exp_c;
        integer i;
        begin
            @(negedge clk);
            in_x <= x;
            in_y <= y;

            if (cycle_cnt >= 2) begin
                if (out_x !== hist_x[cycle_cnt-2] || out_y !== hist_y[cycle_cnt-2]) begin
                    $error("[%0d] out_x/y MISMATCH: got (%d,%d) exp (%d,%d)",
                           cycle_cnt, out_x, out_y,
                           hist_x[cycle_cnt-2], hist_y[cycle_cnt-2]);
                    errors = errors + 1;
                end
            end

            if (cycle_cnt >= 4) begin
                exp_c = 0;
                for (i = 0; i <= cycle_cnt-4; i = i + 1)
                    exp_c = exp_c + hist_x[i] * hist_y[i];
                if (out_c !== exp_c) begin
                    $error("[%0d] out_c MISMATCH: got %d exp %d (diff=%d)",
                           cycle_cnt, out_c, exp_c, out_c - exp_c);
                    errors = errors + 1;
                end else begin
                    $display("[%0d] PASS: out_x=%d out_y=%d out_c=%d",
                             cycle_cnt, out_x, out_y, out_c);
                end
            end else if (cycle_cnt >= 2) begin
                $display("[%0d] PASS: out_x=%d out_y=%d out_c=%d",
                         cycle_cnt, out_x, out_y, out_c);
            end

            hist_x[cycle_cnt] = x;
            hist_y[cycle_cnt] = y;
            cycle_cnt = cycle_cnt + 1;
        end
    endtask

    // Wipe history and drive zeros after reset
    task reset_pipeline;
        begin
            rst = 1;
            repeat (2) @(posedge clk);
            rst = 0;
            cycle_cnt = 0;
            // Blocking assignment to clear inputs immediately
            in_x = 0;
            in_y = 0;
        end
    endtask

    initial begin
        $dumpfile("tb_PE.vcd");
        $dumpvars(0, tb_PE);

        clk = 0;
        rst = 1;
        in_x = 0;
        in_y = 0;
        errors   = 0;
        cycle_cnt = 0;

        // Initial reset for 3 posedges
        repeat (3) @(posedge clk);
        rst = 0;
        in_x = 0;
        in_y = 0;

        // Sync to negedge, then check and start driving
        @(negedge clk);
        $display("=== Reset state: out_x=%d out_y=%d out_c=%d ===",
                 out_x, out_y, out_c);

        // =============================================
        // Test 1: Basic MAC 2*3 + 4*5
        // =============================================
        $display("\n=== Test 1: Basic MAC 2*3 + 4*5 ===");
        cycle(16'd2, 16'd3);   // cyc 0
        cycle(16'd4, 16'd5);   // cyc 1
        cycle(16'd0, 16'd0);   // cyc 2: out_x/y = (2,3)
        cycle(16'd0, 16'd0);   // cyc 3: out_x/y = (4,5)
        cycle(16'd0, 16'd0);   // cyc 4: out_c = 6
        cycle(16'd0, 16'd0);   // cyc 5: out_c = 26

        // =============================================
        // Test 2: Negative values
        // =============================================
        $display("\n=== Test 2: Negative values (-3)*4 + 2*(-5) ===");
        cycle(-16'd3, 16'd4);    // cyc 6
        cycle(16'd2, -16'd5);    // cyc 7
        cycle(16'd0, 16'd0);     // cyc 8
        cycle(16'd0, 16'd0);     // cyc 9
        cycle(16'd0, 16'd0);     // cyc10

        // =============================================
        // Test 3: Reset during operation
        // =============================================
        $display("\n=== Test 3: Reset during operation ===");
        cycle(16'd1, 16'd2);     // cyc11: last input before reset
        reset_pipeline();

        // Verify reset cleared everything
        @(negedge clk);
        if (out_x !== 0 || out_y !== 0 || out_c !== 0) begin
            $error("Reset check FAIL: out_x=%d out_y=%d out_c=%d",
                   out_x, out_y, out_c);
            errors = errors + 1;
        end else begin
            $display("Reset check PASS");
        end

        // =============================================
        // Test 4: Back-to-back MAC
        // =============================================
        $display("\n=== Test 4: Back-to-back MAC 7*3, 2*6, 1*9 ===");
        cycle(16'd7, 16'd3);     // cyc 0
        cycle(16'd2, 16'd6);     // cyc 1
        cycle(16'd1, 16'd9);     // cyc 2: out = (7,3)
        cycle(16'd0, 16'd0);     // cyc 3: out = (2,6)
        cycle(16'd0, 16'd0);     // cyc 4: out_c = 21
        cycle(16'd0, 16'd0);     // cyc 5: out_c = 33
        cycle(16'd0, 16'd0);     // cyc 6: out_c = 42

        // =============================================
        // Test 5: Large values
        // =============================================
        $display("\n=== Test 5: Max 16-bit signed: 32767 * 32767 ===");
        cycle(16'd32767, 16'd32767);  // cyc 7
        cycle(16'd0, 16'd0);          // cyc 8
        cycle(16'd0, 16'd0);          // cyc 9: out = (32767,32767)
        cycle(16'd0, 16'd0);          // cyc10: out = (0,0)
        cycle(16'd0, 16'd0);          // cyc11: out_c = 1073676289

        // =============================================
        // Summary
        // =============================================
        $display("\n================================");
        if (errors === 0)
            $display("*** ALL TESTS PASSED ***");
        else
            $display("*** %0d TEST(S) FAILED ***", errors);
        #100 $finish;
    end

endmodule
