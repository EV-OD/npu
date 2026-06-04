`timescale 1ns / 1ps

module tb_sequencer;

    parameter N = 4;

    reg clk, rst, start;
    wire data_valid;
    wire [31:0] data_idx;
    wire acc_clr, acc_en, readout_trig, busy, done;

    execution_sequencer #(.N(N)) uut (
        .clk(clk), .rst(rst), .start(start),
        .data_valid(data_valid), .data_idx(data_idx),
        .acc_clr(acc_clr), .acc_en(acc_en),
        .readout_trig(readout_trig),
        .busy(busy), .done(done)
    );

    always #5 clk = ~clk;

    integer errors, fc;

    task check;
        input [256:0] msg;
        input cond;
        begin
            if (!cond) begin
                $display("  FAIL: %s @ %0t", msg, $time);
                errors = errors + 1;
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
        errors = 0;
        #15 rst = 0;
        ps();
        $display("=== SEQUENCER TEST (N=%0d) ===", N);

        // ---- IDLE ----
        check("IDLE: acc_en=0",       acc_en     == 0);
        check("IDLE: busy=0",         busy       == 0);
        check("IDLE: done=0",         done       == 0);
        check("IDLE: data_valid=0",   data_valid == 0);
        check("IDLE: readout_trig=0", readout_trig == 0);

        // ---- Start: IDLE->CLEAR->LOAD ----
        @(negedge clk); start = 1;
        ps();  // state CLEAR (outputs IDLE)
        ps();  // state LOAD  (outputs CLEAR)
        check("CLEAR: acc_clr=1", acc_clr == 1);
        check("CLEAR: busy=1",    busy    == 1);
        check("CLEAR: acc_en=0",  acc_en  == 0);

        // ---- LOAD with outputs active ----
        ps();  // state LOAD (outputs LOAD)
        fc = 0;
        repeat (2*N) begin
            if (data_valid) begin
                $display("  LOAD dv=1 idx=%0d", data_idx);
                check("idx in range", data_idx < N);
                fc = fc + 1;
            end
            check("LOAD: busy=1", busy == 1);
            check("LOAD: done=0", done == 0);
            ps();
        end
        check("columns fed", fc == N);

        // ---- DRAIN ----
        ps();  // state DRAIN (outputs LOAD)
        repeat (4*N) begin
            ps();
            check("DRAIN: acc_en=1",      acc_en     == 1);
            check("DRAIN: data_valid=0",  data_valid == 0);
            check("DRAIN: readout_trig=0",readout_trig == 0);
        end

        // ---- RDOUT ----
        ps();
        check("RDOUT: readout_trig=1", readout_trig == 1);
        check("RDOUT: acc_en=0",       acc_en == 0);

        // ---- DONE ----
        ps();
        check("DONE: done=1", done == 1);
        check("DONE: busy=0", busy == 0);
        check("DONE: acc_en=0", acc_en == 0);

        // ---- Back to IDLE ----
        @(negedge clk); start = 0;
        ps();  // state IDLE (outputs DONE)
        ps();  // state IDLE (outputs IDLE)
        check("IDLE again: busy=0", busy == 0);
        check("IDLE again: done=0", done == 0);

        $display("");
        if (errors == 0)
            $display("*** SEQUENCER TEST PASSED ***");
        else
            $display("*** SEQUENCER TEST FAILED with %0d errors ***", errors);

        $finish;
    end

endmodule
