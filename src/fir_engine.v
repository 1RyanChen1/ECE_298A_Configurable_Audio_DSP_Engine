`default_nettype none

module fir_engine (
    input  wire clk,
    input  wire rst,
    input  wire filter_reset,
    input  wire [3:0] num_taps,
    input  wire [3:0] out_shift,
    input  wire sat_en,
    input  wire pcm_valid,
    output wire pcm_ready,
    output wire dsp_busy,
    output reg sample_done,
    output reg out_valid,
    input  wire out_ready,
    input  wire signed [15:0] pcm_data,
`ifdef ARRAY_COEFF_PORT
    input  wire signed [15:0] coeff [0:7],
`else
    input  wire [127:0] coeff_flat,
`endif
    output reg signed [15:0]  out_data
);

`ifndef ARRAY_COEFF_PORT
    wire signed [15:0] coeff [0:7];
    genvar gi;
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : unpack_coeff
            assign coeff[gi] = coeff_flat[16*gi +: 16];
        end
    endgenerate
`endif

    localparam [2:0] S_IDLE    = 3'd0;
    localparam [2:0] S_LOAD    = 3'd1; // load M and Q for one 8x8 partial product
    localparam [2:0] S_MULT    = 3'd2; // 8 cycles of shift-and-add
    localparam [2:0] S_ACCUM   = 3'd3; // sign, align and add partial product
    localparam [2:0] S_TAP_ADD = 3'd4; // add completed 16x16 result to FIR sum
    localparam [2:0] S_FINISH  = 3'd5; // scale, saturate and publish result

    reg [2:0] state;
    reg signed [15:0] sample_history [0:7];
    reg signed [15:0] current_sample;
    reg signed [15:0] current_coefficient;
    reg [3:0] taps_latched;
    reg [3:0] shift_latched;
    reg sat_latched;
    reg [2:0] tap_idx;
    reg [1:0] part_idx;

    // Sequential unsigned 8x8 multiplier (shift-and-add).
    // {sm_acc, sm_q} is the 16-bit product register; sm_q starts as the
    // multiplier and is consumed bit by bit through sm_q[0].
    reg [7:0] sm_mcand;
    reg [7:0] sm_acc;
    reg [7:0] sm_q;
    reg [2:0] sm_cnt;

    reg signed [31:0] pp_acc;
    reg signed [34:0] fir_acc;

    wire [3:0] taps_used = (num_taps > 4'd8) ? 4'd8 : num_taps;
    assign dsp_busy  = (state != S_IDLE);
    assign pcm_ready = (state == S_IDLE) && (!out_valid || out_ready) && !(rst || filter_reset);

    // High bytes are signed 8-bit; low bytes are unsigned 8-bit.
    // Take each high byte's magnitude before multiplication so the
    // multiplier only ever sees unsigned 8-bit operands.
    wire [7:0] sample_byte = part_idx[1] ? current_sample[15:8] : current_sample[7:0];
    wire [7:0] coeff_byte  = part_idx[0] ? current_coefficient[15:8] : current_coefficient[7:0];
    wire sample_negative = part_idx[1] && sample_byte[7];
    wire coeff_negative  = part_idx[0] && coeff_byte[7];
    wire [7:0] sample_mag = sample_negative ? (~sample_byte + 8'd1) : sample_byte;
    wire [7:0] coeff_mag  = coeff_negative ? (~coeff_byte + 8'd1) : coeff_byte;

    // One shift-and-add step: single 8-bit adder, gated by multiplier bit q0.
    wire [8:0] sm_sum = {1'b0, sm_acc} + ({9{sm_q[0]}} & {1'b0, sm_mcand});
    wire [15:0] mag_product = {sm_acc, sm_q};
    wire signed [16:0] signed_partial = (sample_negative ^ coeff_negative) ? -$signed({1'b0, mag_product}) :  $signed({1'b0, mag_product});

    // part_idx: 00 = lo*lo, 01 = lo*hi, 10 = hi*lo, 11 = hi*hi.
    wire [4:0] part_shift = (part_idx == 2'b00) ? 5'd0 : (part_idx == 2'b11) ? 5'd16 : 5'd8;
    wire signed [31:0] mul_extended = {{15{signed_partial[16]}}, signed_partial};
    wire signed [31:0] aligned_partial = mul_extended <<< part_shift;

    wire signed [34:0] pp_extended = {{3{pp_acc[31]}}, pp_acc};
    wire signed [34:0] fir_shifted = fir_acc >>> shift_latched;
    wire signed [15:0] final_sample = (!sat_latched) ? fir_shifted[15:0] :(fir_shifted > 35'sd32767)  ? 16'sh7fff :(fir_shifted < -35'sd32768) ? 16'sh8000 :fir_shifted[15:0];

    integer i;
    always @(posedge clk) begin
        if (rst || filter_reset) begin
            state<= S_IDLE;
            current_sample<= 16'sd0;
            current_coefficient <= 16'sd0;
            taps_latched<= 4'd0;
            shift_latched <= 4'd0;
            sat_latched <= 1'b0;
            tap_idx <= 3'd0;
            part_idx <= 2'd0;
            sm_mcand <= 8'd0;
            sm_acc <= 8'd0;
            sm_q <= 8'd0;
            sm_cnt <= 3'd0;
            pp_acc <= 32'sd0;
            fir_acc <= 35'sd0;
            out_data <= 16'sd0;
            out_valid <= 1'b0;
            sample_done <= 1'b0;
            for (i = 0; i < 8; i = i + 1)
                sample_history[i] <= 16'sd0;
        end else begin
            sample_done <= 1'b0;

            if (out_valid && out_ready)
                out_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (pcm_valid && pcm_ready) begin
                        // History[0] is newest. A new sample shifts old
                        // history one position towards higher indices.
                        sample_history[0] <= pcm_data;
                        for (i = 1; i < 8; i = i + 1)
                            sample_history[i] <= sample_history[i-1];

                        if (taps_used == 4'd0) begin
                            // Bypass has no coefficient multiplication and
                            // must output the ORIGINAL signed PCM sample.
                            out_data    <= pcm_data;
                            out_valid   <= 1'b1;
                            sample_done <= 1'b1;
                        end else begin
                            taps_latched <= taps_used;
                            shift_latched <= out_shift;
                            sat_latched <= sat_en;
                            tap_idx <= 3'd0;
                            part_idx <= 2'd0;
                            current_sample <= pcm_data;
                            current_coefficient <= coeff[0];
                            pp_acc <= 32'sd0;
                            fir_acc <= 35'sd0;
                            state <= S_LOAD;
                        end
                    end
                end

                S_LOAD: begin
                    // M <= coefficient byte magnitude, Q <= sample byte magnitude, A <= 0.
                    sm_mcand <= coeff_mag;
                    sm_q     <= sample_mag;
                    sm_acc   <= 8'd0;
                    sm_cnt   <= 3'd0;
                    state    <= S_MULT;
                end

                S_MULT: begin
                    // Conditional add, then shift {sum, Q} right by one.
                    sm_acc <= sm_sum[8:1];
                    sm_q   <= {sm_sum[0], sm_q[7:1]};
                    sm_cnt <= sm_cnt + 3'd1;
                    if (sm_cnt == 3'd7)
                        state <= S_ACCUM;
                end

                S_ACCUM: begin
                    // {sm_acc, sm_q} holds the finished unsigned 8x8 product.
                    pp_acc <= pp_acc + aligned_partial;
                    if (part_idx == 2'd3)
                        state <= S_TAP_ADD;
                    else begin
                        part_idx <= part_idx + 2'd1;
                        state <= S_LOAD;
                    end
                end

                S_TAP_ADD: begin
                    // pp_acc is now the complete signed 16x16 product.
                    fir_acc <= fir_acc + pp_extended;
                    if (({1'b0, tap_idx} + 4'd1) < taps_latched) begin
                        tap_idx <= tap_idx + 3'd1;
                        part_idx <= 2'd0;
                        pp_acc <= 32'sd0;
                        current_sample <= sample_history[tap_idx + 3'd1];
                        current_coefficient <= coeff[tap_idx + 3'd1];
                        state <= S_LOAD;
                    end else begin
                        state <= S_FINISH;
                    end
                end

                S_FINISH: begin
                    // fir_acc includes the last tap (added in S_TAP_ADD).
                    out_data <= final_sample;
                    out_valid <= 1'b1;
                    sample_done <= 1'b1;
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
