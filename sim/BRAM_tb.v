`timescale 1ns / 1ps

module BRAM_tb;

    parameter DATA_WIDTH = 16;
    parameter ADDR_WIDTH = 8;

    reg clk;

    // Port A
    reg en_a;
    reg we_a;
    reg [ADDR_WIDTH-1:0] addr_a;
    reg [DATA_WIDTH-1:0] din_a;
    wire [DATA_WIDTH-1:0] dout_a;

    // Port B
    reg en_b;
    reg we_b;
    reg [ADDR_WIDTH-1:0] addr_b;
    reg [DATA_WIDTH-1:0] din_b;
    wire [DATA_WIDTH-1:0] dout_b;

    // Instantiate the Unit Under Test (UUT)
    BRAM #(
        .DATA_WIDTH(DATA_WIDTH),
        .ADDR_WIDTH(ADDR_WIDTH)
    ) uut (
        .clk(clk),
        .en_a(en_a), .we_a(we_a), .addr_a(addr_a), .din_a(din_a), .dout_a(dout_a),
        .en_b(en_b), .we_b(we_b), .addr_b(addr_b), .din_b(din_b), .dout_b(dout_b)
    );

    // 100 MHz Clock
    always #5 clk = ~clk;

    initial begin
        // Initialize Inputs
        clk = 0;
        en_a = 0; we_a = 0; addr_a = 0; din_a = 0;
        en_b = 0; we_b = 0; addr_b = 0; din_b = 0;

        $dumpfile("BRAM_tb.vcd");
        $dumpvars(0, BRAM_tb);

        // Wait to pass reset states
        #20;
        $display("==================================================");
        $display("              STARTING BRAM TESTS                 ");
        $display("==================================================");

        // Test 1: Write via Port A, Read via Port A
        $display("\n--- TEST 1: Basic Write/Read (Port A) ---");
        @(negedge clk);
        en_a = 1; we_a = 1; addr_a = 8'h10; din_a = 16'hABCD;
        $display("[Time %0t] Port A writing DATA = %h to ADDR = %h", $time, din_a, addr_a);
        
        @(negedge clk);
        we_a = 0; // Turn off write enable to read back
        $display("[Time %0t] Port A reading from ADDR = %h", $time, addr_a);
        
        @(negedge clk);
        if (dout_a !== 16'hABCD) $display("  -> [FAIL] Expected ABCD, Got %h", dout_a);
        else $display("  -> [PASS] Successfully read correct data: %h", dout_a);
        en_a = 0;

        // Test 2: Write via Port B, Read via Port A (Cross-port communication)
        $display("\n--- TEST 2: Cross-Port Communication ---");
        @(negedge clk);
        en_b = 1; we_b = 1; addr_b = 8'h20; din_b = 16'h1234;
        $display("[Time %0t] Port B writing DATA = %h to ADDR = %h", $time, din_b, addr_b);
        
        @(negedge clk);
        we_b = 0; en_b = 0; // Turn off Port B
        en_a = 1; we_a = 0; addr_a = 8'h20; // Read from Port A
        $display("[Time %0t] Port A reading from ADDR = %h", $time, addr_a);
        
        @(negedge clk);
        if (dout_a !== 16'h1234) $display("  -> [FAIL] Expected 1234, Got %h", dout_a);
        else $display("  -> [PASS] Port A successfully read Port B's data: %h", dout_a);
        en_a = 0;

        // Test 3: Dual Port Simultaneous Read/Write to different addresses
        $display("\n--- TEST 3: Simultaneous Dual Access (Different Addresses) ---");
        @(negedge clk);
        en_a = 1; we_a = 1; addr_a = 8'h30; din_a = 16'hDEAD;
        en_b = 1; we_b = 1; addr_b = 8'h40; din_b = 16'hBEEF;
        $display("[Time %0t] Port A writing DATA = %h to ADDR = %h", $time, din_a, addr_a);
        $display("[Time %0t] Port B writing DATA = %h to ADDR = %h", $time, din_b, addr_b);
        
        @(negedge clk);
        // Swap addresses and switch both to read mode
        en_a = 1; we_a = 0; addr_a = 8'h40; // Port A reads what Port B wrote
        en_b = 1; we_b = 0; addr_b = 8'h30; // Port B reads what Port A wrote
        $display("[Time %0t] Port A reading from ADDR = %h", $time, addr_a);
        $display("[Time %0t] Port B reading from ADDR = %h", $time, addr_b);
        
        @(negedge clk);
        if (dout_a !== 16'hBEEF) $display("  -> [FAIL] Port A Mismatch! Expected BEEF, Got %h", dout_a);
        else $display("  -> [PASS] Port A successfully read data: %h", dout_a);
        
        if (dout_b !== 16'hDEAD) $display("  -> [FAIL] Port B Mismatch! Expected DEAD, Got %h", dout_b);
        else $display("  -> [PASS] Port B successfully read data: %h", dout_b);


        // Test 4: Write Collision (Priority Test)
        $display("\n--- TEST 4: Write Collision (Priority Test) ---");
        @(negedge clk);
        en_a = 1; we_a = 1; addr_a = 8'h50; din_a = 16'hAAAA;
        en_b = 1; we_b = 1; addr_b = 8'h50; din_b = 16'hBBBB;
        $display("[Time %0t] collision writing to ADDR = %h", $time, addr_a);
        $display("[Time %0t] Port A trying to write: %h, Port B trying to write: %h", $time, din_a, din_b);
        
        @(negedge clk);
        we_a = 0; we_b = 0; // Both read the same address
        $display("[Time %0t] Both ports reading ADDR = %h to verify who won...", $time, addr_a);
        
        @(negedge clk);
        if (dout_a === 16'hAAAA) $display("  -> [PASS] Port A won the write collision. Memory contains: %h", dout_a);
        else $display("  -> [FAIL] Port A did NOT win! Memory contains: %h", dout_a);


        // Test 5: Read-during-Write collision (Forwarding Test)
        $display("\n--- TEST 5: Read-during-Write collision (Forwarding Test) ---");
        @(negedge clk);
        en_a = 1; we_a = 1; addr_a = 8'h60; din_a = 16'h1111;
        en_b = 1; we_b = 0; addr_b = 8'h60; 
        $display("[Time %0t] Port A is writing DATA = %h to ADDR = %h", $time, din_a, addr_a);
        $display("[Time %0t] Port B is SIMULTANEOUSLY reading from ADDR = %h", $time, addr_b);
        
        @(negedge clk);
        if (dout_b === 16'h1111) 
            $display("  -> [PASS] Read-forwarding successful! Port B immediately read: %h", dout_b);
        else 
            $display("  -> [FAIL] Read-forwarding failed! Port B read: %h", dout_b);

        en_a = 0; en_b = 0;
        
        #20;
        $display("\n==================================================");
        $display("                ALL TESTS COMPLETE                ");
        $display("==================================================");
        $finish;
    end
endmodule
