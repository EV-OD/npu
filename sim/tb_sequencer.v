`timescale 1ns / 1ps

module tb_sequencer;

    parameter N = 4;

    reg clk, rst, start;
    wire data_valid;
    wire [31:0] data_idx;
    wire acc_clr, acc_en, readout_trig, busy, done;

    wire [31:0] matrix_size = N;  // default to full size for existing tests

    execution_sequencer #(.N(N)) uut (
        .clk(clk), .rst(rst), .start(start),
        .matrix_size(matrix_size),
        .data_valid(data_valid), .data_idx(data_idx),
        .acc_clr(acc_clr), .acc_en(acc_en),
        .readout_trig(readout_trig),
        .busy(busy), .done(done)
    );

    always #5 clk = ~clk;

    integer errors, fc, i;
    integer pass_count, fail_count;

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
        $dumpfile("tb_sequencer.vcd");
        $dumpvars(0, tb_sequencer);

        clk = 0; rst = 1; start = 0;
        errors = 0; pass_count = 0; fail_count = 0;
        #15 rst = 0;
        ps();
        $display("=== SEQUENCER TEST (N=%0d) ===", N);
        $display("");

        // -------------------------------------------------------
        // Test IDLE state
        // -------------------------------------------------------
        $display("--- Phase 1: IDLE state ---");
        check("IDLE: acc_en=0",       acc_en     == 0);
        check("IDLE: busy=0",         busy       == 0);
        check("IDLE: done=0",         done       == 0);
        check("IDLE: data_valid=0",   data_valid == 0);
        check("IDLE: readout_trig=0", readout_trig == 0);

        // -------------------------------------------------------
        // Start sequence: IDLE -> CLEAR -> LOAD
        // -------------------------------------------------------
        $display("");
        $display("--- Phase 2: Start -> CLEAR -> LOAD ---");
        @(negedge clk); start = 1;
        ps();  // CLEAR (outputs still reflect IDLE)
        ps();  // LOAD  (outputs reflect CLEAR state)
        check("CLEAR: acc_clr=1", acc_clr == 1);
        check("CLEAR: busy=1",    busy    == 1);
        check("CLEAR: acc_en=0",  acc_en  == 0);
        check("CLEAR: data_valid=0", data_valid == 0);
        check("CLEAR: readout_trig=0", readout_trig == 0);

        // -------------------------------------------------------
        // Test LOAD phase: data_valid pattern
        // -------------------------------------------------------
        $display("");
        $display("--- Phase 3: LOAD (2N = %0d cycles) ---", 2*N);
        ps();  // state LOAD (outputs LOAD)
        fc = 0;
        repeat (2*N) begin
            if (data_valid) begin
                $display("  [FEED] dv=1 idx=%0d (feed %0d of %0d)", data_idx, data_idx+1, N);
                check("idx in range [0, N-1]", data_idx < N);
                fc = fc + 1;
            end else begin
                $display("  [IDLE] dv=0 (gap cycle)");
            end
            check("LOAD: busy=1", busy == 1);
            check("LOAD: done=0", done == 0);
            check("LOAD: acc_en=1", acc_en == 1);
            ps();
        end
        check("FEED count = N", fc == N);

        // -------------------------------------------------------
        // Test DRAIN phase
        // -------------------------------------------------------
        $display("");
        $display("--- Phase 4: DRAIN (4N = %0d cycles) ---", 4*N);
        ps();  // state DRAIN (outputs still LOAD)
        repeat (4*N) begin
            ps();
            check("DRAIN: acc_en=1",      acc_en     == 1);
            check("DRAIN: data_valid=0",  data_valid == 0);
            check("DRAIN: readout_trig=0",readout_trig == 0);
            check("DRAIN: busy=1",        busy       == 1);
            check("DRAIN: done=0",        done       == 0);
        end
        $display("  DRAIN complete");

        // -------------------------------------------------------
        // Test RDOUT phase (1 cycle, triggers shifter load)
        // -------------------------------------------------------
        $display("");
        $display("--- Phase 5: RDOUT ---");
        ps();  // enter RDOUT
        check("RDOUT: readout_trig=1", readout_trig == 1);
        check("RDOUT: acc_en=0",       acc_en == 0);
        check("RDOUT: data_valid=0",   data_valid == 0);
        check("RDOUT: busy=1",         busy == 1);
        check("RDOUT: done=0",         done == 0);

        // -------------------------------------------------------
        // Test SHIFT phase (N cycles, one row per cycle)
        // -------------------------------------------------------
        $display("");
        $display("--- Phase 6: SHIFT (%0d cycles) ---", N);
        for (i = 0; i < N; i = i + 1) begin
            ps();
            $display("  SHIFT cycle %0d", i+1);
            check("SHIFT: busy=1", busy == 1);
            check("SHIFT: readout_trig=0", readout_trig == 0);
            check("SHIFT: done=0", done == 0);
            check("SHIFT: acc_en=0", acc_en == 0);
            check("SHIFT: data_valid=0", data_valid == 0);
        end

        // -------------------------------------------------------
        // Test DONE state
        // -------------------------------------------------------
        $display("");
        $display("--- Phase 7: DONE_S ---");
        // Deassert start immediately so next_state transitions to IDLE
        @(negedge clk); start = 0;
        ps();  // DONE_S
        check("DONE: done=1", done == 1);
        check("DONE: busy=0", busy == 0);
        check("DONE: acc_en=0", acc_en == 0);
        check("DONE: data_valid=0", data_valid == 0);
        check("DONE: readout_trig=0", readout_trig == 0);

        // -------------------------------------------------------
        // Return to IDLE
        // -------------------------------------------------------
        $display("");
        $display("--- Phase 8: Return to IDLE ---");
        // next_state was recomputed to IDLE (start=0) at the negedge
        ps();  // state transitions DONE_S -> IDLE
        ps();  // state IDLE
        check("IDLE again: busy=0", busy == 0);
        check("IDLE again: done=0", done == 0);
        check("IDLE again: acc_en=0", acc_en == 0);
        check("IDLE again: data_valid=0", data_valid == 0);

        // -------------------------------------------------------
        // Restart from IDLE (ping-pong style: pulse start)
        // -------------------------------------------------------
        $display("");
        $display("--- Phase 9: Restart from IDLE ---");
        // Pulse start for 1 cycle (like ping-pong testbench)
        @(negedge clk); start = 1;
        ps();  // posedge: state=IDLE, next_state=CLEAR (start=1)
        @(negedge clk); start = 0;
        ps();  // posedge: state=CLEAR
        check("CLEAR after restart: acc_clr=1", acc_clr == 1);
        check("CLEAR after restart: busy=1", busy == 1);
        ps();  // LOAD entry: data_valid=1, data_idx=0
        check("LOAD entry: data_valid=1", data_valid == 1);
        check("LOAD entry: data_idx=0", data_idx == 0);
        // Let the sequencer run to completion
        wait(done);
        check("DONE after restart: done=1", done == 1);
        ps();  // DONE_S -> IDLE (start already 0)
        ps();  // DONE_S -> IDLE (next_state=IDLE since start=0)
        ps();  // IDLE
        check("IDLE after restart: busy=0", busy == 0);

        // -------------------------------------------------------
        // Summary
        // -------------------------------------------------------
        $display("");
        $display("--- RESULTS ---");
        $display("  Checks: %0d passed, %0d failed, %0d total", pass_count, fail_count, pass_count+fail_count);
        if (errors == 0) begin
            $display("");
            $display("*** SEQUENCER TEST PASSED ***");
        end else begin
            $display("");
            $display("*** SEQUENCER TEST FAILED with %0d errors ***", errors);
        end
        $finish;
    end

endmodule
