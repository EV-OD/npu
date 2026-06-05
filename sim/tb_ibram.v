`timescale 1ns / 1ps
`include "../src/instruction_defines.vh"

module tb_ibram;

    parameter SLOT_DEPTH = 64;
    parameter DATA_WIDTH = `INST_WIDTH;

    reg clk, rst;
    reg dma_en, dma_we;
    reg [$clog2(2*SLOT_DEPTH)-1:0] dma_addr;
    reg [DATA_WIDTH-1:0] dma_din;
    reg pc_en;
    reg [$clog2(SLOT_DEPTH)-1:0] pc_addr;
    wire [DATA_WIDTH-1:0] pc_dout;
    wire active_slot, ready;
    reg swap;

    ibram #(.SLOT_DEPTH(SLOT_DEPTH)) uut (
        .clk(clk), .rst(rst),
        .dma_en(dma_en), .dma_we(dma_we),
        .dma_addr(dma_addr), .dma_din(dma_din),
        .pc_en(pc_en), .pc_addr(pc_addr), .pc_dout(pc_dout),
        .active_slot(active_slot), .ready(ready), .swap(swap)
    );

    always #5 clk = ~clk;

    integer errors, pass_count, fail_count, i;
    reg [31:0] rd;

    task check;
        input [255:0] msg;
        input cond;
        begin
            if (cond) pass_count = pass_count + 1;
            else begin
                $display("  FAIL: %s @ %0t", msg, $time);
                errors = errors + 1; fail_count = fail_count + 1;
            end
        end
    endtask

    task ps;
        begin @(posedge clk); #1; end
    endtask

    task dma_write;
        input [31:0] addr;
        input [31:0] data;
        begin
            @(negedge clk);
            dma_en <= 1; dma_we <= 1; dma_addr <= addr; dma_din <= data;
            ps();
            dma_en <= 0; dma_we <= 0;
        end
    endtask

    task pc_read;
        input [31:0] addr;
        begin
            @(negedge clk);
            pc_en <= 1; pc_addr <= addr;
            ps();
            rd <= pc_dout;
            pc_en <= 0;
        end
    endtask

    initial begin
        $dumpfile("tb_ibram.vcd");
        $dumpvars(0, tb_ibram);

        clk = 0; rst = 1; dma_en = 0; dma_we = 0; dma_addr = 0; dma_din = 0;
        pc_en = 0; pc_addr = 0; swap = 0;
        errors = 0; pass_count = 0; fail_count = 0;

        #18 rst = 0; ps();

        $display("=== IBRAM DOUBLE-BUFFER TEST (slot_depth=%0d) ===", SLOT_DEPTH);
        $display("");

        // -------------------------------------------------------
        // Test 1: Reset state
        // -------------------------------------------------------
        $display("--- Test 1: Reset state ---");
        check("active_slot=0 after rst", active_slot == 0);
        check("ready=0 after rst", ready == 0);

        // -------------------------------------------------------
        // Test 2: Fill Slot A, verify ready
        // -------------------------------------------------------
        $display("--- Test 2: Fill Slot A ---");
        for (i = 0; i < SLOT_DEPTH; i = i + 1)
            dma_write(i, 32'hA0000000 + i);
        check("slot A filled: ready=0 (slot B inactive not loaded)", ready == 0);

        // Test reading from slot A via PC port
        for (i = 0; i < SLOT_DEPTH; i = i + 1) begin
            pc_read(i);
            check($sformatf("slot A pc_read[%0d]=%h", i, rd), rd === 32'hA0000000 + i);
        end

        // -------------------------------------------------------
        // Test 3: Fill Slot B, verify ready
        // -------------------------------------------------------
        $display("--- Test 3: Fill Slot B ---");
        for (i = 0; i < SLOT_DEPTH; i = i + 1)
            dma_write(SLOT_DEPTH + i, 32'hB0000000 + i);
        check("slot B filled: ready=1", ready == 1);

        // -------------------------------------------------------
        // Test 4: Swap to Slot B
        // -------------------------------------------------------
        $display("--- Test 4: Swap to Slot B ---");
        @(negedge clk); swap = 1; ps(); swap = 0;
        check("active_slot=1 after swap", active_slot == 1);
        check("ready=0 after swap (slot A needs reload)", ready == 0);

        for (i = 0; i < SLOT_DEPTH; i = i + 1) begin
            pc_read(i);
            check($sformatf("slot B pc_read[%0d]=%h", i, rd), rd === 32'hB0000000 + i);
        end

        // -------------------------------------------------------
        // Test 5: Refill Slot A while reading Slot B
        // -------------------------------------------------------
        $display("--- Test 5: Refill Slot A while reading from Slot B ---");
        for (i = 0; i < SLOT_DEPTH; i = i + 1)
            dma_write(i, 32'hC0000000 + i);
        check("slot A refilled: ready=1", ready == 1);

        // Slot B still readable
        pc_read(0);
        check("slot B still readable while slot A fills", rd === 32'hB0000000);

        // -------------------------------------------------------
        // Test 6: Swap back to Slot A (now has new data)
        // -------------------------------------------------------
        $display("--- Test 6: Swap back to Slot A ---");
        @(negedge clk); swap = 1; ps(); swap = 0;
        check("active_slot=0 after swap", active_slot == 0);
        check("ready=0 (slot B stale)", ready == 0);

        for (i = 0; i < SLOT_DEPTH; i = i + 1) begin
            pc_read(i);
            check($sformatf("slot A new pc_read[%0d]=%h", i, rd), rd === 32'hC0000000 + i);
        }

        // Refill slot B while reading slot A
        for (i = 0; i < SLOT_DEPTH; i = i + 1)
            dma_write(SLOT_DEPTH + i, 32'hD0000000 + i);
        check("slot B refilled: ready=1", ready == 1);

        // -------------------------------------------------------
        // Test 7: End-of-slot detection via swap_req
        //   (tested by checking that PC can read last address)
        // -------------------------------------------------------
        $display("--- Test 7: Read at slot boundaries ---");
        pc_read(0);
        check("slot A[0] after swap back", rd === 32'hC0000000);
        pc_read(SLOT_DEPTH-1);
        check("slot A[63] last element", rd === 32'hC0000000 + SLOT_DEPTH-1);

        // -------------------------------------------------------
        // Test 8: Swap back to Slot B
        // -------------------------------------------------------
        $display("--- Test 8: Swap to Slot B (refilled) ---");
        @(negedge clk); swap = 1; ps(); swap = 0;
        check("active_slot=1", active_slot == 1);
        check("ready=0 (slot A stale)", ready == 0);

        for (i = 0; i < SLOT_DEPTH; i = i + 1) begin
            pc_read(i);
            check($sformatf("slot B refilled pc_read[%0d]=%h", i, rd), rd === 32'hD0000000 + i);
        }

        // -------------------------------------------------------
        // Test 9: DMA readback (not directly supported; verify via PC port)
        //   Write distinct patterns to each slot, read back
        // -------------------------------------------------------
        $display("--- Test 9: Isolated overwrite ---");
        // Write to slot A (while active=1, inactive=0)
        for (i = 0; i < SLOT_DEPTH; i = i + 1)
            dma_write(i, 32'hE0000000 + i);
        check("slot A refilled (2nd time): ready=1", ready == 1);

        // Swap to A, verify
        @(negedge clk); swap = 1; ps(); swap = 0;
        check("active_slot=0", active_slot == 0);
        for (i = 0; i < 4; i = i + 1) begin
            pc_read(i);
            check($sformatf("slot A[%0d]=%h", i, rd), rd === 32'hE0000000 + i);
        end

        // -------------------------------------------------------
        // Test 10: Swap without ready (should still work)
        // -------------------------------------------------------
        $display("--- Test 10: Swap without ready ---");
        // Currently active = A, inactive = B is stale
        // Swap to B even though ready=0
        @(negedge clk); swap = 1; ps(); swap = 0;
        check("active_slot=1 (swapped without ready)", active_slot == 1);
        // Should still read old B data
        pc_read(0);
        check("slot B old data still readable", rd === 32'hD0000000);

        // -------------------------------------------------------
        // Summary
        // -------------------------------------------------------
        $display("");
        $display("--- RESULTS ---");
        $display("  Checks: %0d passed, %0d failed, %0d total",
                 pass_count, fail_count, pass_count + fail_count);
        if (errors === 0)
            $display("*** IBRAM TEST PASSED ***");
        else
            $display("*** IBRAM TEST FAILED ***");
        #100 $finish;
    end

endmodule
