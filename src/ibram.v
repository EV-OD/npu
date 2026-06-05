`include "instruction_defines.vh"

module ibram #(
    parameter DATA_WIDTH   = `INST_WIDTH,
    parameter SLOT_DEPTH   = 64
)(
    input  wire                         clk,
    input  wire                         rst,

    input  wire                         dma_en,
    input  wire                         dma_we,
    input  wire [$clog2(2*SLOT_DEPTH)-1:0] dma_addr,
    input  wire [DATA_WIDTH-1:0]        dma_din,

    input  wire                         pc_en,
    input  wire [$clog2(SLOT_DEPTH)-1:0] pc_addr,
    output reg  [DATA_WIDTH-1:0]        pc_dout,

    output reg                          active_slot,
    output reg                          ready,      // inactive slot fully loaded
    input  wire                         swap
);

    localparam NUM_WORDS = 2 * SLOT_DEPTH;

    reg [DATA_WIDTH-1:0] mem [0:NUM_WORDS-1];

    reg slot_a_full, slot_b_full;

    wire dma_last_a = (dma_addr[$clog2(SLOT_DEPTH)-1:0] == SLOT_DEPTH-1) && (dma_addr[$clog2(SLOT_DEPTH)] == 0);
    wire dma_last_b = (dma_addr[$clog2(SLOT_DEPTH)-1:0] == SLOT_DEPTH-1) && (dma_addr[$clog2(SLOT_DEPTH)] == 1);

    // DMA write
    always @(posedge clk) begin
        if (dma_en && dma_we)
            mem[dma_addr] <= dma_din;
    end

    // PC read with active-slot address translation
    // Register pc_dout at negedge so the value is stable when
    // the dispatch unit samples it at the next posedge (DECODE_W).
    always @(negedge clk) begin
        if (pc_en) begin
            if (active_slot == 0)
                pc_dout <= mem[pc_addr];
            else
                pc_dout <= mem[SLOT_DEPTH + pc_addr];
        end
    end

    // Slot full tracking + active slot management
    always @(posedge clk) begin
        if (rst) begin
            slot_a_full <= 0;
            slot_b_full <= 0;
            active_slot <= 0;
            ready       <= 0;
        end else begin
            if (dma_en && dma_we) begin
                if (dma_last_a) slot_a_full <= 1;
                if (dma_last_b) slot_b_full <= 1;
            end
            if (swap) begin
                active_slot <= ~active_slot;
                if (active_slot == 0) slot_a_full <= 0;
                else                  slot_b_full <= 0;
            end
            ready <= (active_slot == 0) ? slot_b_full : slot_a_full;
        end
    end

endmodule
