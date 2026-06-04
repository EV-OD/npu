`timescale 1ns / 1ps

module tb_readout;

    parameter N = 3;
    parameter ACCUM_WIDTH = 40;

    reg clk, rst, trigger, shift_mode;
    reg [(N*N*ACCUM_WIDTH)-1:0] pe_c;
    wire valid;
    wire [(N*N*ACCUM_WIDTH)-1:0] result;
    wire shift_valid;
    wire [ACCUM_WIDTH-1:0] shift_out;
    wire shift_done;

    readout_unit #(.N(N), .ACCUM_WIDTH(ACCUM_WIDTH)) uut (
        .clk(clk), .rst(rst), .trigger(trigger), .shift_mode(shift_mode),
        .pe_c(pe_c), .valid(valid), .result(result),
        .shift_valid(shift_valid), .shift_out(shift_out), .shift_done(shift_done)
    );

    always #5 clk = ~clk;

    integer i, j, errors;
    reg [256:0] msg_str;

    task check;
        input [256:0] msg;
        input cond;
        begin
            if (!cond) begin
                $display("  FAIL: %s @ %0t", msg, $time);
                errors = errors + 1;
            end else begin
                $display("  OK:   %s", msg);
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
        input [15:0] base;
        integer idx;
        begin
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin
                    idx = i*N + j;
                    pe_c[(idx * ACCUM_WIDTH) +: ACCUM_WIDTH] = (idx + 1) * base;
                end
        end
    endtask

    task verify_values;
        input [15:0] base;
        integer idx;
        begin
            for (i = 0; i < N; i = i + 1)
                for (j = 0; j < N; j = j + 1) begin
                    idx = i*N + j;
                    if ($signed(result[(idx*ACCUM_WIDTH)+:ACCUM_WIDTH]) != (idx+1)*base) begin
                        $display("  FAIL: [%0d][%0d] exp=%0d got=%0d @ %0t",
                                 i, j, (idx+1)*base,
                                 $signed(result[(idx*ACCUM_WIDTH)+:ACCUM_WIDTH]), $time);
                        errors = errors + 1;
                    end
                end
        end
    endtask

    initial begin
        $dumpfile("tb_readout.vcd");
        $dumpvars(0, tb_readout);

        clk = 0; rst = 1; trigger = 0; shift_mode = 0; pe_c = 0;
        errors = 0;
        #15 rst = 0;
        ps();

        $display("=== READOUT UNIT TEST ===");

        // ---- Test 1: Parallel mode (shift_mode=0) ----
        $display("--- Test 1: Parallel capture ---");
        check("reset: valid=0", valid == 0);
        check("reset: result=0", result == 0);

        load_pe_values(100);
        @(negedge clk);
        trigger = 1;
        ps();
        trigger = 0;

        check("triggered: valid=1", valid == 1);
        verify_values(100);

        pe_c = 0;
        ps();
        check("hold: valid still 1", valid == 1);
        verify_values(100);

        load_pe_values(200);
        @(negedge clk);
        trigger = 1;
        ps();
        trigger = 0;
        verify_values(200);

        // ---- Test 2: Serial shift-out mode (shift_mode=1) ----
        $display("\n--- Test 2: Serial shift-out ---");
        load_pe_values(300);
        @(negedge clk);
        shift_mode = 1;
        trigger = 1;
        ps();
        trigger = 0;

        check("shift: valid=1", valid == 1);
        check("shift: shift_valid=1 on first word", shift_valid == 1);
        check("shift: shift_out[0]=300", $signed(shift_out) == 300);

        // Shift out remaining N*N-1 words
        for (i = 1; i < N*N; i = i + 1) begin
            ps();
            msg_str = "shift_valid during shift";
            check(msg_str, shift_valid == 1);
            msg_str = "shift_out value during shift";
            check(msg_str, $signed(shift_out) == (i+1)*300);
        end

        ps();
        check("shift: cycle done, shift_valid=0", shift_valid == 0);
        check("shift: shift_done=1", shift_done == 1);
        check("shift: parallel result unchanged", valid == 1);
        verify_values(300);

        $display("");
        if (errors == 0)
            $display("*** READOUT UNIT TEST PASSED ***");
        else
            $display("*** READOUT UNIT TEST FAILED with %0d errors ***", errors);

        $finish;
    end

endmodule
