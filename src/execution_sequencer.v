module execution_sequencer #(
    parameter N = 4,
    parameter DRAIN_CYCLES = 0  // 0 = auto (4*matrix_size), else fixed
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    input  wire [31:0]  matrix_size,  // runtime tile dimension (1..N)

    output reg          data_valid,
    output reg [31:0]   data_idx,
    output reg          acc_clr,
    output reg          acc_en,
    output reg          readout_trig,
    output reg          busy,
    output reg          done
);

    reg [31:0] M;  // latched matrix_size
    always @(posedge clk) begin
        if (rst) M <= N;
        else if (start) M <= matrix_size;
    end

    wire [31:0] drain_limit = (DRAIN_CYCLES == 0) ? (4*M) : DRAIN_CYCLES;

    localparam IDLE   = 3'd0;
    localparam CLEAR  = 3'd1;
    localparam LOAD   = 3'd2;
    localparam DRAIN  = 3'd3;
    localparam RDOUT  = 3'd4;
    localparam SHIFT  = 3'd5;
    localparam DONE_S = 3'd6;

    reg [2:0] state, next_state;
    reg [31:0] load_cycle;
    reg [31:0] drain_cnt;
    reg [31:0] shift_cnt;

    always @(posedge clk) begin
        if (rst) state <= IDLE;
        else      state <= next_state;
    end

    always @(*) begin
        next_state = state;
        case (state)
            IDLE:   if (start)                    next_state = CLEAR;
            CLEAR:                                 next_state = LOAD;
            LOAD:   if (load_cycle == 2*M)         next_state = DRAIN;
            DRAIN:  if (drain_cnt == drain_limit)  next_state = RDOUT;
            RDOUT:                                 next_state = SHIFT;
            SHIFT:  if (shift_cnt == M-1)          next_state = DONE_S;
            DONE_S: if (start)                     next_state = CLEAR;
                    else                            next_state = IDLE;
        endcase
    end

    always @(posedge clk) begin
        if (rst) begin
            load_cycle <= 0;
            drain_cnt  <= 0;
            shift_cnt  <= 0;
        end else begin
            case (state)
                CLEAR: begin load_cycle <= 0; drain_cnt <= 0; shift_cnt <= 0; end
                LOAD:  load_cycle <= load_cycle + 1;
                DRAIN: drain_cnt <= drain_cnt + 1;
                SHIFT: shift_cnt <= shift_cnt + 1;
            endcase
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            data_valid   <= 0;
            data_idx     <= 0;
            acc_clr      <= 0;
            acc_en       <= 0;
            readout_trig <= 0;
            busy         <= 0;
            done         <= 0;
        end else begin
            if (state == IDLE) begin
                acc_en  <= 0;
                busy    <= 0;
                done    <= 0;
                data_valid <= 0;
                readout_trig <= 0;
                acc_clr <= 0;
            end else if (state == CLEAR) begin
                acc_clr <= 1;
                acc_en  <= 0;
                busy    <= 1;
                data_valid <= 0;
                readout_trig <= 0;
                done    <= 0;
            end else if (state == LOAD) begin
                data_idx   <= load_cycle / 2;
                data_valid <= (load_cycle % 2 == 0) && (load_cycle < 2*M);
                acc_en     <= 1;
                busy    <= 1;
                acc_clr <= 0;
                readout_trig <= 0;
                done    <= 0;
            end else if (state == DRAIN) begin
                acc_en  <= 1;
                busy    <= 1;
                data_valid <= 0;
                readout_trig <= 0;
                acc_clr <= 0;
                done    <= 0;
            end else if (state == RDOUT) begin
                acc_en  <= 0;
                readout_trig <= 1;
                busy    <= 1;
                data_valid <= 0;
                acc_clr <= 0;
                done    <= 0;
            end else if (state == SHIFT) begin
                acc_en  <= 0;
                readout_trig <= 0;
                busy    <= 1;
                data_valid <= 0;
                acc_clr <= 0;
                done    <= 0;
            end else begin // DONE_S
                acc_en  <= 0;
                done    <= 1;
                busy    <= 0;
                data_valid <= 0;
                readout_trig <= 0;
                acc_clr <= 0;
            end
        end
    end

endmodule
