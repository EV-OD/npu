`timescale 1ns / 1ps

module tb_readout;

    parameter N = 3;
    parameter ACCUM_WIDTH = 40;

    reg clk, rst, trigger;
    reg [(N*N*ACCUM_WIDTH)-1:0] pe_c;
    wire valid;
    wire [(N*N*ACCUM_WIDTH)-1:0] result;

    readout_unit #(.N(N), .ACCUM_WIDTH(ACCUM_WIDTH)) uut (
        .clk(clk), .rst(rst), .trigger(trigger),
        .pe_c(pe_c), .valid(valid), .result(result)
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

    // Wait for posedge + settle
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

        clk = 0; rst = 1; trigger = 0; pe_c = 0;
        errors = 0;
        #15 rst = 0;
        ps();

        $display("=== READOUT UNIT TEST ===");

        // Post-reset
        check("reset: valid=0", valid == 0);
        check("reset: result=0", result == 0);

        // Load PE values and trigger capture
        load_pe_values(100);
        @(negedge clk);
        trigger = 1;
        ps();  // capture happens here
        trigger = 0;

        check("triggered: valid=1", valid == 1);
        verify_values(100);

        // Change pe_c and verify result holds old values
        pe_c = 0;
        ps();
        check("hold: valid still 1", valid == 1);
        verify_values(100);

        // Re-trigger with new values
        load_pe_values(200);
        @(negedge clk);
        trigger = 1;
        ps();
        trigger = 0;

        verify_values(200);

        $display("");
        if (errors == 0)
            $display("*** READOUT UNIT TEST PASSED ***");
        else
            $display("*** READOUT UNIT TEST FAILED with %0d errors ***", errors);

        $finish;
    end

endmodule
