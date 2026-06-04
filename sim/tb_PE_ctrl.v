`timescale 1ns/1ps

module tb_PE_ctrl;

    parameter N = 4;
    parameter DATA_WIDTH = 16;
    parameter ACCUM_WIDTH = 40;

    reg clk;
    reg rst;
    reg acc_clr;
    reg acc_en;
    reg signed [DATA_WIDTH-1:0] in_x;
    reg signed [DATA_WIDTH-1:0] in_y;
    reg signed [ACCUM_WIDTH-1:0] psum_in;
    wire signed [DATA_WIDTH-1:0] out_x;
    wire signed [DATA_WIDTH-1:0] out_y;
    wire signed [ACCUM_WIDTH-1:0] out_c;

    PE_ctrl #(
        .DATA_WIDTH(DATA_WIDTH),
        .ACCUM_WIDTH(ACCUM_WIDTH)
    ) uut (
        .clk     (clk),
        .rst     (rst),
        .acc_clr (acc_clr),
        .acc_en  (acc_en),
        .in_x    (in_x),
        .in_y    (in_y),
        .psum_in (psum_in),
        .out_x   (out_x),
        .out_y   (out_y),
        .out_c   (out_c)
    );

    reg signed [ACCUM_WIDTH-1:0] ref_accum;
    reg signed [DATA_WIDTH-1:0]  ref_x_reg;
    reg signed [DATA_WIDTH-1:0]  ref_y_reg;
    reg signed [(2*DATA_WIDTH)-1:0] ref_product_reg;
    reg signed [DATA_WIDTH-1:0]  ref_out_x;
    reg signed [DATA_WIDTH-1:0]  ref_out_y;
    reg signed [ACCUM_WIDTH-1:0] ref_out_c;

    always @(posedge clk) begin
        if (rst) begin
            ref_x_reg       <= 0;
            ref_y_reg       <= 0;
            ref_product_reg <= 0;
            ref_accum       <= 0;
            ref_out_x       <= 0;
            ref_out_y       <= 0;
            ref_out_c       <= 0;
        end else begin
            ref_x_reg <= in_x;
            ref_y_reg <= in_y;
            ref_product_reg <= ref_x_reg * ref_y_reg;
            if (acc_clr)
                ref_accum <= 0;
            else if (acc_en)
                ref_accum <= ref_accum + ref_product_reg;
            ref_out_x <= ref_x_reg;
            ref_out_y <= ref_y_reg;
            ref_out_c <= ref_accum + psum_in;
        end
    end

    always #5 clk = ~clk;

    integer errors;
    integer pass_count;
    integer fail_count;
    integer cycle_cnt;

    task check;
        input [200:0] msg;
        input pass;
        begin
            if (pass)
                pass_count = pass_count + 1;
            else begin
                $error("FAIL [%0d] %s", cycle_cnt, msg);
                fail_count = fail_count + 1;
                errors = errors + 1;
            end
        end
    endtask

    task ps;
        input signed [DATA_WIDTH-1:0] x;
        input signed [DATA_WIDTH-1:0] y;
        input signed [ACCUM_WIDTH-1:0] p;
        input clr;
        input en;
        begin
            @(negedge clk);
            check("out_x mismatch", out_x === ref_out_x);
            check("out_y mismatch", out_y === ref_out_y);
            check("out_c mismatch", out_c === ref_out_c);
            if (out_c === ref_out_c)
                $display("PASS [%0d] out_x=%d out_y=%d out_c=%d",
                         cycle_cnt, out_x, out_y, out_c);
            in_x    <= x;
            in_y    <= y;
            psum_in <= p;
            acc_clr <= clr;
            acc_en  <= en;
            cycle_cnt = cycle_cnt + 1;
        end
    endtask

    task reset_pipeline;
        begin
            rst = 1;
            repeat (2) @(posedge clk);
            rst = 0;
            cycle_cnt = 0;
            in_x = 0;
            in_y = 0;
            psum_in = 0;
            acc_clr = 0;
            acc_en = 1;
        end
    endtask

    initial begin
        $dumpfile("tb_PE_ctrl.vcd");
        $dumpvars(0, tb_PE_ctrl);

        clk = 0;
        rst = 1;
        in_x = 0;
        in_y = 0;
        psum_in = 0;
        acc_clr = 0;
        acc_en = 1;
        errors = 0;
        pass_count = 0;
        fail_count = 0;
        cycle_cnt = 0;

        repeat (3) @(posedge clk);
        rst = 0;
        in_x = 0;
        in_y = 0;
        psum_in = 0;
        acc_clr = 0;
        acc_en = 1;

        @(negedge clk);
        $display("=== Reset state: out_x=%d out_y=%d out_c=%d ===",
                 out_x, out_y, out_c);

        // =============================================
        // Test 1: Basic MAC  2*3 + 4*5 = 26
        // =============================================
        $display("\n=== Test 1: Basic MAC (2*3 + 4*5 = 26) ===");
        ps(16'd2,  16'd3,  40'd0, 1'b0, 1'b1);
        ps(16'd4,  16'd5,  40'd0, 1'b0, 1'b1);
        ps(16'd0,  16'd0,  40'd0, 1'b0, 1'b1);
        ps(16'd0,  16'd0,  40'd0, 1'b0, 1'b1);
        ps(16'd0,  16'd0,  40'd0, 1'b0, 1'b1);
        ps(16'd0,  16'd0,  40'd0, 1'b0, 1'b1);

        // =============================================
        // Test 2: Negative values  (-3)*4 + 2*(-5) = -22
        // =============================================
        $display("\n=== Test 2: Negative values (-3*4 + 2*-5 = -22) ===");
        reset_pipeline();
        @(negedge clk);
        $display("Reset state: out_x=%d out_y=%d out_c=%d", out_x, out_y, out_c);
        ps(-16'd3,  16'd4,   40'd0,  1'b0, 1'b1);
        ps(16'd2,   -16'd5,  40'd0,  1'b0, 1'b1);
        ps(16'd0,   16'd0,   40'd0,  1'b0, 1'b1);
        ps(16'd0,   16'd0,   40'd0,  1'b0, 1'b1);
        ps(16'd0,   16'd0,   40'd0,  1'b0, 1'b1);
        ps(16'd0,   16'd0,   40'd0,  1'b0, 1'b1);

        // =============================================
        // Test 3: acc_clr during operation
        //   Feed (7,3), wait 1 cycle, assert acc_clr, then feed (2,6)
        //   Expected: accumulator starts fresh after clear → 2*6 = 12
        // =============================================
        $display("\n=== Test 3: acc_clr during operation ===");
        reset_pipeline();
        @(negedge clk);
        $display("Reset state: out_x=%d out_y=%d out_c=%d", out_x, out_y, out_c);
        ps(16'd7,  16'd3,  40'd0, 1'b0, 1'b1);
        ps(16'd0,  16'd0,  40'd0, 1'b1, 1'b1);
        ps(16'd2,  16'd6,  40'd0, 1'b0, 1'b1);
        ps(16'd0,  16'd0,  40'd0, 1'b0, 1'b1);
        ps(16'd0,  16'd0,  40'd0, 1'b0, 1'b1);
        ps(16'd0,  16'd0,  40'd0, 1'b0, 1'b1);
        ps(16'd0,  16'd0,  40'd0, 1'b0, 1'b1);

        // =============================================
        // Test 4: acc_en gating
        //   Feed (10,2) with en=1, (3,6) with en=0, (1,1) with en=1
        //   Expected: 20 + 1 = 21 (second product NOT accumulated)
        // =============================================
        $display("\n=== Test 4: acc_en gating (10*2 + 1*1 = 21) ===");
        reset_pipeline();
        @(negedge clk);
        $display("Reset state: out_x=%d out_y=%d out_c=%d", out_x, out_y, out_c);
        ps(16'd10, 16'd2,  40'd0, 1'b0, 1'b1);
        ps(16'd3,  16'd6,  40'd0, 1'b0, 1'b0);
        ps(16'd1,  16'd1,  40'd0, 1'b0, 1'b1);
        ps(16'd0,  16'd0,  40'd0, 1'b0, 1'b1);
        ps(16'd0,  16'd0,  40'd0, 1'b0, 1'b1);
        ps(16'd0,  16'd0,  40'd0, 1'b0, 1'b1);
        ps(16'd0,  16'd0,  40'd0, 1'b0, 1'b1);

        // =============================================
        // Test 5: Overflow protection (40-bit modulo wrap)
        //   Accumulate large products to verify 40-bit wrap
        //   32767*32767 = 1073741824 = 2^30
        //   1024 * 2^30 = 2^40 → wraps to 0
        // =============================================
        $display("\n=== Test 5: Overflow protection (40-bit wrap) ===");
        reset_pipeline();
        @(negedge clk);
        $display("Reset state: out_x=%d out_y=%d out_c=%d", out_x, out_y, out_c);
        // Accumulate 1024 copies of max product, then check result is 0 (mod 2^40)
        repeat (1024) begin
            @(negedge clk);
            in_x <= 16'd32767;
            in_y <= 16'd32767;
            psum_in <= 40'd0;
            acc_clr <= 1'b0;
            acc_en  <= 1'b1;
            check("out_x mismatch", out_x === ref_out_x);
            check("out_y mismatch", out_y === ref_out_y);
            check("out_c mismatch", out_c === ref_out_c);
            if (out_c === ref_out_c)
                $display("PASS [%0d] out_x=%d out_y=%d out_c=%d",
                         cycle_cnt, out_x, out_y, out_c);
            cycle_cnt = cycle_cnt + 1;
        end
        // Drain pipeline (3 cycles)
        repeat (4) begin
            @(negedge clk);
            in_x <= 16'd0;
            in_y <= 16'd0;
            psum_in <= 40'd0;
            acc_clr <= 1'b0;
            acc_en  <= 1'b1;
            check("out_x mismatch", out_x === ref_out_x);
            check("out_y mismatch", out_y === ref_out_y);
            check("out_c mismatch", out_c === ref_out_c);
            if (out_c === ref_out_c)
                $display("PASS [%0d] out_x=%d out_y=%d out_c=%d",
                         cycle_cnt, out_x, out_y, out_c);
            cycle_cnt = cycle_cnt + 1;
        end

        // =============================================
        // Test 6: Maximum signed values
        //   in_x=-32768, in_y=-32768 -> product = 2^30 = 1073741824
        // =============================================
        $display("\n=== Test 6: Max signed values (-32768 * -32768 = 2^30) ===");
        reset_pipeline();
        @(negedge clk);
        $display("Reset state: out_x=%d out_y=%d out_c=%d", out_x, out_y, out_c);
        ps(-16'd32768, -16'd32768, 40'd0, 1'b0, 1'b1);
        ps(16'd0,      16'd0,      40'd0, 1'b0, 1'b1);
        ps(16'd0,      16'd0,      40'd0, 1'b0, 1'b1);
        ps(16'd0,      16'd0,      40'd0, 1'b0, 1'b1);
        ps(16'd0,      16'd0,      40'd0, 1'b0, 1'b1);
        ps(16'd0,      16'd0,      40'd0, 1'b0, 1'b1);

        // =============================================
        // Test 7: Alternating clear/stall
        //   Rapidly toggle acc_clr and acc_en:
        //   clr=0,en=1 → accumulate (5*5=25)
        //   clr=1,en=1 → clear (acc=0)
        //   clr=0,en=0 → stall (acc holds 0, product 3*3 not accumulated)
        //   clr=1,en=1 → clear again (acc=0)
        //   clr=0,en=1 → accumulate (4*4=16)
        //   Final accumulator should be 16
        // =============================================
        $display("\n=== Test 7: Alternating clear/stall ===");
        reset_pipeline();
        @(negedge clk);
        $display("Reset state: out_x=%d out_y=%d out_c=%d", out_x, out_y, out_c);
        ps(16'd5, 16'd5, 40'd0, 1'b0, 1'b1);
        ps(16'd3, 16'd3, 40'd0, 1'b1, 1'b1);
        ps(16'd2, 16'd2, 40'd0, 1'b0, 1'b0);
        ps(16'd1, 16'd1, 40'd0, 1'b1, 1'b1);
        ps(16'd4, 16'd4, 40'd0, 1'b0, 1'b1);
        ps(16'd0, 16'd0, 40'd0, 1'b0, 1'b1);
        ps(16'd0, 16'd0, 40'd0, 1'b0, 1'b1);
        ps(16'd0, 16'd0, 40'd0, 1'b0, 1'b1);
        ps(16'd0, 16'd0, 40'd0, 1'b0, 1'b1);

        // =============================================
        // Test 8: psum_in non-zero
        //   psum_in = 0x1234567890, feed (0,0) so product=0
        //   Verify out_c = accumulator + psum_in
        // =============================================
        $display("\n=== Test 8: psum_in non-zero (0x1234567890) ===");
        reset_pipeline();
        @(negedge clk);
        $display("Reset state: out_x=%d out_y=%d out_c=%d", out_x, out_y, out_c);
        ps(16'd0, 16'd0, 40'h1234567890, 1'b0, 1'b1);
        ps(16'd0, 16'd0, 40'd0,            1'b0, 1'b1);
        ps(16'd0, 16'd0, 40'd0,            1'b0, 1'b1);
        ps(16'd0, 16'd0, 40'd0,            1'b0, 1'b1);
        ps(16'd0, 16'd0, 40'd0,            1'b0, 1'b1);
        ps(16'd0, 16'd0, 40'd0,            1'b0, 1'b1);

        // =============================================
        // Test 9: Data forwarding timing
        //   Verify x_reg/y_reg/out_x/out_y timing
        //   in_x at cycle T appears at out_x at cycle T+2
        // =============================================
        $display("\n=== Test 9: Data forwarding timing ===");
        reset_pipeline();
        @(negedge clk);
        $display("Reset state: out_x=%d out_y=%d out_c=%d", out_x, out_y, out_c);
        ps(16'd1,  16'd10, 40'd0, 1'b0, 1'b1);
        ps(16'd2,  16'd20, 40'd0, 1'b0, 1'b1);
        ps(16'd3,  16'd30, 40'd0, 1'b0, 1'b1);
        ps(16'd4,  16'd40, 40'd0, 1'b0, 1'b1);
        ps(16'd0,  16'd0,  40'd0, 1'b0, 1'b1);
        ps(16'd0,  16'd0,  40'd0, 1'b0, 1'b1);
        ps(16'd0,  16'd0,  40'd0, 1'b0, 1'b1);

        // =============================================
        // Test 10: Random stress (50 random values)
        //   Accumulate 50 pseudo-random products,
        //   compare final accumulator against reference
        // =============================================
        $display("\n=== Test 10: Random stress (50 random pairs) ===");
        reset_pipeline();
        @(negedge clk);
        $display("Reset state: out_x=%d out_y=%d out_c=%d", out_x, out_y, out_c);

        // Drain initial pipeline bubbles
        ps(16'd0, 16'd0, 40'd0, 1'b0, 1'b1);
        ps(16'd0, 16'd0, 40'd0, 1'b0, 1'b1);

        // 50 random pairs with a fixed seed for reproducibility
        // Use a simple deterministic sequence
        begin
            integer k;
            reg signed [15:0] rx, ry;
            rx = 16'd12345;
            ry = 16'd6789;
            for (k = 0; k < 50; k = k + 1) begin
                rx = (rx << 1) ^ (rx < 0 ? 16'hB400 : 16'd0);
                ry = (ry << 1) ^ (ry < 0 ? 16'hD200 : 16'd0);
                ps(rx, ry, 40'd0, 1'b0, 1'b1);
            end
        end

        // Drain pipeline
        ps(16'd0, 16'd0, 40'd0, 1'b0, 1'b1);
        ps(16'd0, 16'd0, 40'd0, 1'b0, 1'b1);
        ps(16'd0, 16'd0, 40'd0, 1'b0, 1'b1);
        ps(16'd0, 16'd0, 40'd0, 1'b0, 1'b1);

        // =============================================
        // Summary
        // =============================================
        $display("\n================================");
        $display("Results: %0d passed, %0d failed out of %0d checks",
                 pass_count, fail_count, pass_count + fail_count);
        if (errors === 0)
            $display("*** ALL TESTS PASSED ***");
        else
            $display("*** %0d TEST(S) FAILED ***", errors);
        #100 $finish;
    end

endmodule
