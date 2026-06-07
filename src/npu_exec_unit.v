`include "instruction_defines.vh"

module npu_exec_unit #(
    parameter N = 4,
    parameter DATA_WIDTH = 16,
    parameter ACCUM_WIDTH = 40
)(
    input  wire                                clk,
    input  wire                                rst,

    input  wire                                start,
    input  wire [31:0]                         matrix_size,
    output reg                                 busy,
    output reg                                 done,

    input  wire                                a_we,
    input  wire [$clog2(2*N*N)-1:0]            a_waddr,
    input  wire signed [DATA_WIDTH-1:0]        a_din,

    input  wire                                b_we,
    input  wire [$clog2(2*N*N)-1:0]            b_waddr,
    input  wire signed [DATA_WIDTH-1:0]        b_din,

    output wire                                result_valid,
    output wire [(N*N*ACCUM_WIDTH)-1:0]        result_data
);

    wire        seq_data_valid;
    wire [31:0] seq_data_idx;
    wire        seq_acc_clr;
    wire        seq_acc_en;
    wire        seq_readout_trig;
    wire        seq_busy;
    wire        seq_done;

    execution_sequencer #(.N(N), .DRAIN_CYCLES(0)) u_seq (
        .clk(clk), .rst(rst),
        .start(start), .matrix_size(matrix_size),
        .data_valid(seq_data_valid), .data_idx(seq_data_idx),
        .acc_clr(seq_acc_clr), .acc_en(seq_acc_en),
        .readout_trig(seq_readout_trig),
        .busy(seq_busy), .done(seq_done)
    );

    wire [(N*DATA_WIDTH)-1:0] a_out;
    feed_buffer #(.N(N), .DATA_WIDTH(DATA_WIDTH), .COL_MAJOR(0)) u_fb_a (
        .clk(clk), .rst(rst),
        .we(a_we), .waddr(a_waddr), .din(a_din),
        .raddr(seq_data_idx[$clog2(2*N)-1:0]), .dout(a_out)
    );

    wire [(N*DATA_WIDTH)-1:0] b_out;
    feed_buffer #(.N(N), .DATA_WIDTH(DATA_WIDTH), .COL_MAJOR(0)) u_fb_b (
        .clk(clk), .rst(rst),
        .we(b_we), .waddr(b_waddr), .din(b_din),
        .raddr(seq_data_idx[$clog2(2*N)-1:0]), .dout(b_out)
    );

    // Gate feed data with data_valid: only feed every other cycle
    wire [(N*DATA_WIDTH)-1:0] a_gated;
    wire [(N*DATA_WIDTH)-1:0] b_gated;
    genvar gi;
    generate
        for (gi = 0; gi < N*DATA_WIDTH; gi = gi + 1) begin
            assign a_gated[gi] = seq_data_valid ? a_out[gi] : 1'b0;
            assign b_gated[gi] = seq_data_valid ? b_out[gi] : 1'b0;
        end
    endgenerate

    wire [(N*DATA_WIDTH)-1:0] a_skewed;
    skew_buffer #(.N(N), .DATA_WIDTH(DATA_WIDTH), .DELAY_PER_STEP(2)) u_skew_a (
        .clk(clk), .rst(rst), .din(a_gated), .dout(a_skewed)
    );

    wire [(N*DATA_WIDTH)-1:0] b_skewed;
    skew_buffer #(.N(N), .DATA_WIDTH(DATA_WIDTH), .DELAY_PER_STEP(2)) u_skew_b (
        .clk(clk), .rst(rst), .din(b_gated), .dout(b_skewed)
    );

    wire [(N*N*ACCUM_WIDTH)-1:0] sa_out;
    systolic_array_nxn_ctrl #(
        .N(N), .DATA_WIDTH(DATA_WIDTH), .ACCUM_WIDTH(ACCUM_WIDTH)
    ) u_sa (
        .clk(clk), .rst(rst),
        .acc_clr(seq_acc_clr), .acc_en(seq_acc_en),
        .in_left(a_skewed), .in_top(b_skewed), .out_c(sa_out)
    );

    wire [(N*ACCUM_WIDTH)-1:0] shift_out;
    wire                       shift_valid;
    wire                       shift_done;

    readout_shifter #(.N(N), .ACCUM_WIDTH(ACCUM_WIDTH)) u_shifter (
        .clk(clk), .rst(rst),
        .load(seq_readout_trig),
        .pe_c(sa_out),
        .row_out(shift_out), .row_valid(shift_valid),
        .shift_done(shift_done)
    );

    wire ro_valid;
    wire [(N*N*ACCUM_WIDTH)-1:0] ro_result;

    readout_unit #(.N(N), .ACCUM_WIDTH(ACCUM_WIDTH)) u_readout (
        .clk(clk), .rst(rst),
        .shift_valid(shift_valid),
        .row_in(shift_out),
        .valid(ro_valid),
        .result(ro_result)
    );

    assign result_valid = ro_valid;
    assign result_data  = ro_result;

    always @(posedge clk) begin
        if (rst) begin
            busy <= 0;
            done <= 0;
        end else begin
            busy <= seq_busy || shift_valid || seq_readout_trig;
            if (seq_done)
                done <= 1;
            else if (start)
                done <= 0;
        end
    end

endmodule
