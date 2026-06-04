module system #(
    parameter N = 4,
    parameter DATA_WIDTH = 16,
    parameter ACCUM_WIDTH = 40
)(
    input  wire                                     clk,
    input  wire                                     rst,
    input  wire                                     start,

    // Runtime configuration (latched at start)
    input  wire [31:0]                              matrix_size,  // tile dimension (1..N)
    input  wire [31:0]                              act_base,     // activation column offset
    input  wire [31:0]                              wgt_base,     // weight row offset
    input  wire [31:0]                              out_base,     // output row offset

    // Activation buffer write (preload)
    input  wire                                     act_we,
    input  wire [$clog2(2*N*N)-1:0]                 act_waddr,
    input  wire signed [DATA_WIDTH-1:0]             act_din,

    // Weight buffer write (preload)
    input  wire                                     wgt_we,
    input  wire [$clog2(2*N*N)-1:0]                 wgt_waddr,
    input  wire signed [DATA_WIDTH-1:0]             wgt_din,

    // Output buffer read (result, row-level async)
    input  wire [$clog2(2*N)-1:0]                   out_raddr,
    output wire signed [(N*ACCUM_WIDTH)-1:0]        out_dout,

    // Status
    output wire                                     done
);

    // Sequencer
    wire data_valid;
    wire [31:0] data_idx;
    wire readout_trig, acc_clr, acc_en, busy;

    execution_sequencer #(.N(N)) seq (
        .clk(clk), .rst(rst), .start(start),
        .matrix_size(matrix_size),
        .data_valid(data_valid), .data_idx(data_idx),
        .acc_clr(acc_clr), .acc_en(acc_en),
        .readout_trig(readout_trig),
        .busy(busy), .done(done)
    );

    // Feed buffers
    wire signed [(N*DATA_WIDTH)-1:0] act_dout, wgt_dout;
    reg [$clog2(2*N)-1:0] act_feed_idx, wgt_feed_idx;

    feed_buffer #(.N(N), .DATA_WIDTH(DATA_WIDTH), .COL_MAJOR(1)) act_buf (
        .clk(clk), .rst(rst),
        .we(act_we), .waddr(act_waddr), .din(act_din),
        .raddr(act_feed_idx), .dout(act_dout)
    );

    feed_buffer #(.N(N), .DATA_WIDTH(DATA_WIDTH), .COL_MAJOR(0)) wgt_buf (
        .clk(clk), .rst(rst),
        .we(wgt_we), .waddr(wgt_waddr), .din(wgt_din),
        .raddr(wgt_feed_idx), .dout(wgt_dout)
    );

    // Feed control
    reg data_feed_active;
    reg [(N*DATA_WIDTH)-1:0] raw_a_col, raw_b_row;

    always @(posedge clk) begin
        if (rst) begin
            data_feed_active <= 0;
            act_feed_idx <= 0;
            wgt_feed_idx <= 0;
        end else begin
            data_feed_active <= data_valid;
            act_feed_idx <= data_idx + act_base;
            wgt_feed_idx <= data_idx + wgt_base;
        end
    end

    // Register feed data at negedge
    always @(negedge clk) begin
        if (rst) begin
            raw_a_col <= 0;
            raw_b_row <= 0;
        end else if (data_feed_active) begin
            raw_a_col <= act_dout;
            raw_b_row <= wgt_dout;
        end else begin
            raw_a_col <= 0;
            raw_b_row <= 0;
        end
    end

    // Skew buffers
    wire [(N*DATA_WIDTH)-1:0] skewed_a, skewed_b;

    skew_buffer #(.N(N), .DATA_WIDTH(DATA_WIDTH), .DELAY_PER_STEP(2)) skew_a (
        .clk(clk), .rst(rst), .din(raw_a_col), .dout(skewed_a)
    );
    skew_buffer #(.N(N), .DATA_WIDTH(DATA_WIDTH), .DELAY_PER_STEP(2)) skew_b (
        .clk(clk), .rst(rst), .din(raw_b_row), .dout(skewed_b)
    );

    // Systolic array
    wire [(N*N*ACCUM_WIDTH)-1:0] pe_c;

    systolic_array_nxn_ctrl #(.N(N), .DATA_WIDTH(DATA_WIDTH), .ACCUM_WIDTH(ACCUM_WIDTH)) sys_arr (
        .clk(clk), .rst(rst),
        .acc_clr(acc_clr), .acc_en(acc_en),
        .in_left(skewed_a), .in_top(skewed_b),
        .out_c(pe_c)
    );

    // Readout shifter
    wire [(N*ACCUM_WIDTH)-1:0] shift_row;
    wire shift_valid;

    readout_shifter #(.N(N), .ACCUM_WIDTH(ACCUM_WIDTH)) rdout_shift (
        .clk(clk), .rst(rst),
        .load(readout_trig),
        .pe_c(pe_c),
        .row_out(shift_row), .row_valid(shift_valid), .shift_done()
    );

    // Readout unit (assembles full result)
    wire rdout_valid;
    wire [(N*N*ACCUM_WIDTH)-1:0] rdout_result;

    readout_unit #(.N(N), .ACCUM_WIDTH(ACCUM_WIDTH)) rdout (
        .clk(clk), .rst(rst),
        .shift_valid(shift_valid),
        .row_in(shift_row),
        .valid(rdout_valid),
        .result(rdout_result)
    );

    // Output buffer: write one row per SHIFT cycle
    // we is combinational; waddr is registered starting at out_base
    wire        out_we;
    reg [$clog2(2*N)-1:0] out_waddr;

    assign out_we = shift_valid && !readout_trig && !done;

    always @(posedge clk) begin
        if (rst) begin
            out_waddr <= 0;
        end else if (readout_trig) begin
            out_waddr <= out_base;
        end else if (shift_valid && !done) begin
            out_waddr <= out_waddr + 1;
        end
    end

    output_buffer #(.N(N), .ACCUM_WIDTH(ACCUM_WIDTH)) out_buf (
        .clk(clk), .rst(rst),
        .we(out_we), .waddr(out_waddr), .row_in(shift_row),
        .raddr(out_raddr), .dout(out_dout)
    );

endmodule
