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
    output reg signed [15:0] out_data
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

    localparam [2:0] S_IDLE   = 3'd0;
    localparam [2:0] S_LOAD   = 3'd1;
    localparam [2:0] S_MULT   = 3'd2;
    localparam [2:0] S_ADD_HI = 3'd3;
    localparam [2:0] S_SCALE  = 3'd4;

    reg [2:0] state;
    reg [15:0] sample_history [0:7];
    reg [7:0] history_valid;
    reg [2:0] tap_idx;
    reg [2:0] last_tap;
    reg [3:0] shift_remaining;
    reg sat_latched;

    reg [15:0] multiplicand;
    reg [3:0] bit_idx;
    reg [18:0] mul_hi;
    // Eight full-precision products can sum to +2^33, requiring 35 bits.
    reg [34:0] fir_acc;

    wire clear = rst || filter_reset;
    wire pcm_fire = pcm_valid && pcm_ready;

    assign dsp_busy = (state != S_IDLE);
    assign pcm_ready = (state == S_IDLE) && (!out_valid || out_ready) && !clear;

    // Only the validity bits need clearing. Invalid history reads as zero,
    // and bypass samples enter history just like filtered samples.
    integer i;
    always @(posedge clk) begin
        if (pcm_fire) begin
            sample_history[0] <= pcm_data;
            for (i = 1; i < 8; i = i + 1)
                sample_history[i] <= sample_history[i-1];
        end
    end

    // During multiplication, {mul_hi, fir_acc[15:0]} is the signed
    // shift-and-add register. Its upper part starts with the old FIR sum's
    // low word, and its lower part starts with the coefficient bits.
    // After 16 shifts it contains sample * coefficient + old_sum[15:0].
    // S_ADD_HI then adds its high word to the saved old_sum[34:16].
    wire add_hi = (state == S_ADD_HI);
    wire mul_bit = !add_hi && fir_acc[0];
    wire subtract = mul_bit && (bit_idx == 4'd15);
    wire [18:0] sample_ext = {{3{multiplicand[15]}}, multiplicand};
    wire [18:0] adder_a = add_hi ? fir_acc[34:16] : mul_hi;
    wire [18:0] adder_b = add_hi ? mul_hi :
                           ((sample_ext & {19{mul_bit}}) ^ {19{subtract}});
    // The extra low bit supplies the two's-complement carry-in when
    // subtracting the coefficient's sign bit. Both phases use one adder.
    wire [18:0] sum;
    wire unused_carry;
    assign {sum, unused_carry} = {adder_a, 1'b1} + {adder_b, subtract};

    // A signed value fits in 16 bits iff bits [34:15] are all equal.
    wire overflow = (|fir_acc[34:15]) && !(&fir_acc[34:15]);
    wire [15:0] clip_value = fir_acc[34] ? 16'h8000 : 16'h7fff;

    always @(posedge clk) begin
        if (clear) begin
            state         <= S_IDLE;
            history_valid <= 8'd0;
            out_data      <= 16'sd0;
            out_valid     <= 1'b0;
            sample_done   <= 1'b0;
        end else begin
            sample_done <= 1'b0;
            if (out_valid && out_ready)
                out_valid <= 1'b0;

            case (state)
                S_IDLE: begin
                    if (pcm_fire) begin
                        history_valid <= {history_valid[6:0], 1'b1};
                        if (num_taps == 4'd0) begin
                            out_data    <= pcm_data;
                            out_valid   <= 1'b1;
                            sample_done <= 1'b1;
                        end else begin
                            state <= S_LOAD;
                        end
                    end
                end

                S_LOAD: state <= S_MULT;

                S_MULT: begin
                    if (bit_idx == 4'd15)
                        state <= S_ADD_HI;
                end

                S_ADD_HI: begin
                    if (tap_idx == last_tap)
                        state <= S_SCALE;
                    else
                        state <= S_LOAD;
                end

                S_SCALE: begin
                    if (shift_remaining == 4'd0) begin
                        out_data    <= sat_latched && overflow ? clip_value : fir_acc[15:0];
                        out_valid   <= 1'b1;
                        sample_done <= 1'b1;
                        state       <= S_IDLE;
                    end
                end

                default: state <= S_IDLE;
            endcase
        end
    end

    // Reset the multiply counter with the controller because its terminal
    // count drives FSM transitions.
    always @(posedge clk) begin
        if (clear || state == S_LOAD)
            bit_idx <= 4'd0;
        else if (state == S_MULT)
            bit_idx <= bit_idx + 4'd1;
    end

    // The FSM initializes working data before using it.
    always @(posedge clk) begin
        case (state)
            S_IDLE: begin
                if (pcm_fire && (num_taps != 4'd0)) begin
                    // Clamp values 9..15 to eight taps.
                    last_tap        <= num_taps[3] ? 3'd7 : num_taps[2:0] - 3'd1;
                    tap_idx         <= 3'd0;
                    shift_remaining <= out_shift;
                    sat_latched     <= sat_en;
                    fir_acc         <= 35'd0;
                end
            end

            S_LOAD: begin
                multiplicand  <= history_valid[tap_idx] ? sample_history[tap_idx] : 16'd0;
                mul_hi        <= {3'd0, fir_acc[15:0]};
                fir_acc[15:0] <= coeff[tap_idx];
            end

            S_MULT: begin
                mul_hi        <= {sum[18], sum[18:1]};
                fir_acc[15:0] <= {sum[0], fir_acc[15:1]};
            end

            S_ADD_HI: begin
                fir_acc[34:16] <= sum;
                tap_idx        <= tap_idx + 3'd1;
            end

            S_SCALE: begin
                if (shift_remaining != 4'd0) begin
                    fir_acc         <= {fir_acc[34], fir_acc[34:1]};
                    shift_remaining <= shift_remaining - 4'd1;
                end
            end

            default: begin end
        endcase
    end
endmodule

`default_nettype wire
