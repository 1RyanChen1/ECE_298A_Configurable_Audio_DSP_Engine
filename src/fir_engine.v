`default_nettype none

// FIR engine, area-optimised: NO multiplier. One 20-bit add/sub + shift per clock.
//
// Bit-serial across taps (distributed arithmetic style):
//   S = sum_t x[t]*c[t] = sum_k w_k * 2^k * Y_k,   Y_k = sum_t c[t][k] ? x[t] : 0
//   w_k = +1 for k<15, w_15 = -1 (sign bit of a two's-complement coefficient)
// For each coefficient bit k (LSB first) we walk all taps, conditionally adding
// x[t] into acc_hi.  After the last tap of that bit, acc_hi is shifted right by
// one and the bit that falls out goes into acc_lo.  After 16 bit-steps
// {acc_hi, acc_lo} holds the exact 36-bit signed sum of products.
//
// Latency = 16 * taps + 2 clocks (8 taps -> 130, 1 tap -> 18).
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

    localparam [1:0] S_IDLE   = 2'd0;
    localparam [1:0] S_ACC    = 2'd1; // one add/sub (+ shift on last tap) per clock
    localparam [1:0] S_FINISH = 2'd2; // scale, saturate and publish result

    reg [1:0] state;
    reg signed [15:0] sample_history [0:7];
    reg [3:0] taps_latched;
    reg [3:0] shift_latched;
    reg       sat_latched;
    reg [2:0] tap_idx;
    reg [3:0] bit_idx;
    // |acc_hi| < 2^19 for 8 taps, so 20 bits; acc_lo collects the shifted-out LSBs.
    reg signed [19:0] acc_hi;
    reg        [15:0] acc_lo;

    wire [3:0] taps_used = (num_taps > 4'd8) ? 4'd8 : num_taps;
    assign dsp_busy  = (state != S_IDLE);
    assign pcm_ready = (state == S_IDLE) && (!out_valid || out_ready) && !(rst || filter_reset);

    // ---- datapath: one adder/subtractor -------------------------------------
    wire signed [15:0] cur_sample = sample_history[tap_idx];
    wire        [15:0] cur_coeff  = coeff[tap_idx];
    wire coeff_bit = cur_coeff[bit_idx];
    wire sign_bit  = (bit_idx == 4'd15);            // MSB has weight -2^15
    wire last_tap  = (({1'b0, tap_idx} + 4'd1) == taps_latched);

    wire [19:0] sample_ext = {{4{cur_sample[15]}}, cur_sample};
    wire [19:0] addend     = coeff_bit ? (sign_bit ? ~sample_ext : sample_ext) : 20'd0;
    wire        carry_in   = coeff_bit & sign_bit;  // two's-complement negate = ~x + 1
    wire [19:0] sum        = acc_hi + addend + {19'd0, carry_in};

    // ---- output scale / saturate (unchanged behaviour) ----------------------
    wire signed [35:0] fir_full    = {acc_hi, acc_lo};
    wire signed [35:0] fir_shifted = fir_full >>> shift_latched;
    wire signed [15:0] final_sample = (!sat_latched) ? fir_shifted[15:0] :
                                      (fir_shifted >  36'sd32767)  ? 16'sh7fff :
                                      (fir_shifted < -36'sd32768)  ? 16'sh8000 :
                                      fir_shifted[15:0];

    integer i;
    always @(posedge clk) begin
        if (rst || filter_reset) begin
            state        <= S_IDLE;
            taps_latched <= 4'd0;
            shift_latched<= 4'd0;
            sat_latched  <= 1'b0;
            tap_idx      <= 3'd0;
            bit_idx      <= 4'd0;
            acc_hi       <= 20'sd0;
            acc_lo       <= 16'd0;
            out_data     <= 16'sd0;
            out_valid    <= 1'b0;
            sample_done  <= 1'b0;
            for (i = 0; i < 8; i = i + 1)
                sample_history[i] <= 16'sd0;
        end else begin
            sample_done <= 1'b0;

            if (out_valid && out_ready)
                out_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (pcm_valid && pcm_ready) begin
                        // History[0] is newest.
                        sample_history[0] <= pcm_data;
                        for (i = 1; i < 8; i = i + 1)
                            sample_history[i] <= sample_history[i-1];

                        if (taps_used == 4'd0) begin
                            // Bypass: output the ORIGINAL signed PCM sample.
                            out_data    <= pcm_data;
                            out_valid   <= 1'b1;
                            sample_done <= 1'b1;
                        end else begin
                            taps_latched  <= taps_used;
                            shift_latched <= out_shift;
                            sat_latched   <= sat_en;
                            tap_idx       <= 3'd0;
                            bit_idx       <= 4'd0;
                            acc_hi        <= 20'sd0;
                            acc_lo        <= 16'd0;
                            state         <= S_ACC;
                        end
                    end
                end

                S_ACC: begin
                    if (last_tap) begin
                        // Finish this coefficient bit: add, then >>1 (arithmetic).
                        acc_hi  <= {sum[19], sum[19:1]};
                        acc_lo  <= {sum[0], acc_lo[15:1]};
                        tap_idx <= 3'd0;
                        if (sign_bit)
                            state   <= S_FINISH;
                        else
                            bit_idx <= bit_idx + 4'd1;
                    end else begin
                        acc_hi  <= sum;
                        tap_idx <= tap_idx + 3'd1;
                    end
                end

                S_FINISH: begin
                    out_data    <= final_sample;
                    out_valid   <= 1'b1;
                    sample_done <= 1'b1;
                    state       <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule

`default_nettype wire
