`timescale 1ns / 1ps

module tb_feed_buffer;

    parameter N = 4;
    parameter DATA_WIDTH = 16;

    reg clk, rst;
    reg we;
    reg [$clog2(2*N*N)-1:0] waddr;
    reg signed [DATA_WIDTH-1:0] din;
    reg [$clog2(2*N)-1:0] raddr;
    wire signed [(N*DATA_WIDTH)-1:0] dout;

    feed_buffer #(.N(N), .DATA_WIDTH(DATA_WIDTH)) uut (
        .clk(clk), .rst(rst),
        .we(we), .waddr(waddr), .din(din),
        .raddr(raddr), .dout(dout)
    );

    always #5 clk = ~clk;

    integer i, j, errors, pass_count, fail_count;

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

    initial begin
        $dumpfile("tb_feed_buffer.vcd");
        $dumpvars(0, tb_feed_buffer);

        clk = 0; rst = 1; we = 0; waddr = 0; din = 0; raddr = 0;
        errors = 0; pass_count = 0; fail_count = 0;

        #18 rst = 0;
        ps();

        $display("=== FEED BUFFER TEST (N=%0d) ===", N);
        $display("");

        // Test 1: Reset → all zeros
        $display("--- Test 1: Post-reset zeros ---");
        raddr = 0;
        #1;
        check("row0[0]=0", $signed(dout[0*DATA_WIDTH +: DATA_WIDTH]) == 0);
        check("row0[1]=0", $signed(dout[1*DATA_WIDTH +: DATA_WIDTH]) == 0);
        raddr = 2;
        #1;
        check("row2[0]=0", $signed(dout[0*DATA_WIDTH +: DATA_WIDTH]) == 0);

        // Test 2: Write and read back individual elements
        $display("");
        $display("--- Test 2: Element writes, row reads ---");
        // Write matrix: row i, col j = i*N + j
        for (i = 0; i < N; i = i + 1) begin
            for (j = 0; j < N; j = j + 1) begin
                @(negedge clk);
                we = 1;
                waddr = i*N + j;
                din = i*N + j + 1;
                ps();
                we = 0;
            end
        end

        // Read back each row and verify
        for (i = 0; i < N; i = i + 1) begin
            raddr = i;
            #1;
            $display("  verify row %0d", i);
            for (j = 0; j < N; j = j + 1) begin
                check("element matches", $signed(dout[(j*DATA_WIDTH) +: DATA_WIDTH]) == i*N + j + 1);
            end
        end

        // Test 3: Overwrite elements
        $display("");
        $display("--- Test 3: Overwrite ---");
        @(negedge clk);
        we = 1;
        waddr = 0;
        din = 99;
        ps();
        we = 0;

        raddr = 0;
        #1;
        check("row0[0] overwritten to 99", $signed(dout[0*DATA_WIDTH +: DATA_WIDTH]) == 99);
        check("row0[1] unchanged", $signed(dout[1*DATA_WIDTH +: DATA_WIDTH]) == 2);

        // Test 4: Async read — write then immediately read same row
        $display("");
        $display("--- Test 4: Write then async read same row ---");
        @(negedge clk);
        we = 1;
        waddr = 5;
        din = 77;
        ps();
        we = 0;

        // Read row containing waddr=5: i=1, j=1 => row 1
        raddr = 1;
        #1;
        check("row1[1]=77 (overwritten)", $signed(dout[1*DATA_WIDTH +: DATA_WIDTH]) == 77);
        check("row1[0]=5 (unchanged)", $signed(dout[0*DATA_WIDTH +: DATA_WIDTH]) == 5);

        $display("");
        $display("--- RESULTS ---");
        $display("  Checks: %0d passed, %0d failed, %0d total", pass_count, fail_count, pass_count+fail_count);
        if (errors == 0) begin
            $display("");
            $display("*** FEED BUFFER TEST PASSED ***");
        end else begin
            $display("");
            $display("*** FEED BUFFER TEST FAILED with %0d errors ***", errors);
        end
        $finish;
    end

endmodule
