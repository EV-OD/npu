module BRAM #(
    parameter DATA_WIDTH = 16,
    parameter ADDR_WIDTH = 8
)(
    input  wire                     clk,

    // Port A
    input  wire                     en_a,  // Port enable
    input  wire                     we_a,  // Write enable (1=write, 0=read)
    input  wire [ADDR_WIDTH-1:0]    addr_a,
    input  wire [DATA_WIDTH-1:0]    din_a,
    output reg  [DATA_WIDTH-1:0]    dout_a,

    // Port B
    input  wire                     en_b,
    input  wire                     we_b,
    input  wire [ADDR_WIDTH-1:0]    addr_b,
    input  wire [DATA_WIDTH-1:0]    din_b,
    output reg  [DATA_WIDTH-1:0]    dout_b
);

    // Calculate memory depth
    localparam MEM_DEPTH = 1 << ADDR_WIDTH;

    // The memory array
    // (* ram_style = "block" *) is used to instruct synthesis tools (like Yosys, Vivado, Quartus) 
    // to map this specifically to Block RAM resources instead of distributed LUT/register logic.
    (* ram_style = "block" *) 
    reg [DATA_WIDTH-1:0] mem [0:MEM_DEPTH-1];

    // Initialize memory to zeros (useful for simulation)
    integer i;
    initial begin
        for (i = 0; i < MEM_DEPTH; i = i + 1) begin
            mem[i] = {DATA_WIDTH{1'b0}};
        end
    end

    // Port A Operation (Read-First behavior)
    always @(posedge clk) begin
        if (en_a) begin
            if (we_a) begin
                mem[addr_a] <= din_a;
            end
            
            // Read-during-write collision: If Port A reads while Port B writes 
            // the same address, forward the new Port B data directly to Port A.
            if (!we_a && we_b && addr_a == addr_b) begin
                dout_a <= din_b;
            end else begin
                dout_a <= mem[addr_a];
            end
        end
    end

    // Port B Operation (Read-First behavior)
    always @(posedge clk) begin
        if (en_b) begin
            // Collision handling:
            // 1. Write priority: Port A wins if both write to the same address.
            if (we_b && (!we_a || addr_a != addr_b)) begin 
                mem[addr_b] <= din_b;
            end
            
            // 2. Read-during-write collision: If Port B reads while Port A writes 
            // the same address, forward the new Port A data directly to Port B (write-first behavior for collisions).
            if (!we_b && we_a && addr_a == addr_b) begin
                dout_b <= din_a;
            end else begin
                dout_b <= mem[addr_b];
            end
        end
    end

endmodule
