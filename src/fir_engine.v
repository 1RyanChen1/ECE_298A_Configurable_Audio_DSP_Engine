module fir_engine #(
)(
    input  wire clk, // clk for the module
    input  wire rst, // reset
    input  wire filter_reset, // reset the filter setings
    input  wire [3:0] num_taps, // number of taps being used
    input  wire [3:0] out_shift, // how much shifting is done for the signal
    input  wire sat_en, // saturation enable signal
    input  wire pcm_valid,// if the data is valid for this cycle
    output wire pcm_ready, // if the data is ready 
    output wire dsp_busy, // if the engine is currently proccesign samples
    output reg sample_done, // if the sample is finished being proccesing
    output reg out_valid, //if the output is valid
    input  wire out_ready // if the output pcm is ready to be sent
    input  wire signed [15:0] pcm_data, // the actual data beingg sent
`ifdef ARRAY_COEFF_PORT
    input  wire signed [15:0] coeff [0:7], // actual coefficiients
`else
    input  wire [127:0] coeff_flat, // actual coefficiients, flattened: coeff_flat[16*i +: 16] is coefficient i
`endif
    output reg signed [15:0] out_data // pcm data after it has already been proccessed
);
`ifndef ARRAY_COEFF_PORT
    // rebuild the array view of the flat port, so the rest of the code can keep using coeff[i]
    wire signed [15:0] coeff [0:7];
    genvar gi;
    generate
        for (gi = 0; gi < 8; gi = gi + 1) begin : unpack_coeff
            assign coeff[gi] = coeff_flat[16*gi +: 16];
        end
    endgenerate
`endif

    // sums and intermediary values for coefficients and samples
    reg signed [15:0] sample_history [0:7]; // previous samples, 0 is latest, 7 is the oldest
    reg [3:0] tap_counter; // to keep track of how many taps have been proceesed through the multiply-accumulate
    reg signed [34:0] accumulator; // accumulated sum, which then gates shifted
    reg signed [15:0] current_sample; // current pcm sample
    reg signed [15:0] current_coefficient; // current pcm sample
    reg [7:0] current_8_bits_coefficient; // current pcm sample
    reg [7:0] current_8_bits_sample; // current pcm sample

    //mux control signals
    reg [3:0] coefficient_select_mux;
    reg [3:0] sample_select_mux;
    wire upper_or_lower_select_coefficient; // mux control signal for upper and lower 8 bits of the coefficient bank
    wire upper_or_lower_select_sample; // mux control signal for the upper and lower 8 bits for the sample bank

    // counters and flags 
    reg grab_values;
    reg [3:0] sample_processor_counter; // large counter for overall proccessing 
    reg [1:0] high_and_low_counter; // counter to check if youve done lower lower, upper upper etc;
    reg signed [16:0] multiplication_result; // intermediary mulplication result

    // flags to track if low low, low high etc are being multplitied
    reg result_ready;
    reg [1:0] result_position; // 1 if = sample was upper , 0 if coefficient was upper

    integer i;

    // handshhake and status
    assign dsp_busy  = grab_values;
    assign pcm_ready = !grab_values && !out_valid;

    // caps taps to 8 if signal is more than that
    wire [3:0] taps_used = (num_taps > 4'd8) ? 4'd8 : num_taps;

    // high_and_low_counter: 0 = lower*lower, 1 = lower sample*upper coeff, 2 = upper sample*lower coeff, 3 = upper*upper
    assign upper_or_lower_select_coefficient = high_and_low_counter[0];
    assign upper_or_lower_select_sample      = high_and_low_counter[1];

    // byte going in to the mulitplier mux
    always @(*) begin
        case(upper_or_lower_select_coefficient)
        1'b0: current_8_bits_coefficient = current_coefficient [7:0];
        1'b1: current_8_bits_coefficient = current_coefficient [15:8];
        default: current_8_bits_coefficient = 8'b0;
        endcase

        case(upper_or_lower_select_sample)
        1'b0: current_8_bits_sample = current_sample [7:0];
        1'b1: current_8_bits_sample = current_sample [15:8];
        default: current_8_bits_sample = 8'b0;
        endcase
    end

    // unsigned 8x8 multiplier, then put the sign back on the product.
    wire coefficient_negative = upper_or_lower_select_coefficient & current_8_bits_coefficient[7];
    wire sample_negative = upper_or_lower_select_sample & current_8_bits_sample[7];

    wire [7:0] coefficient_magnitude = coefficient_negative ? (~current_8_bits_coefficient + 8'd1) : current_8_bits_coefficient;
    wire [7:0] sample_magnitude = sample_negative? (~current_8_bits_sample + 8'd1) : current_8_bits_sample;

    wire [15:0] unsigned_product = coefficient_magnitude * sample_magnitude; // the 8x8 multiplier

    wire signed [16:0] signed_product = (coefficient_negative ^ sample_negative) ? -$signed({1'b0, unsigned_product}):  $signed({1'b0, unsigned_product});

    // shift the registered partial product into place by how many bits 0 or 8 or 16
    wire [4:0] result_shift = (result_position[1] ? 5'd8 : 5'd0) + (result_position[0] ? 5'd8 : 5'd0);
    wire signed [34:0] product_ext = multiplication_result;
    wire signed [34:0] shifted_product = product_ext <<< result_shift;

    // output scaling (arithmetic shift, then saturate or truncate)
    wire signed [34:0] shifted_acc = accumulator >>> out_shift;
    wire signed [15:0] scaled_out  = !sat_en ? shifted_acc[15:0] : (shifted_acc >  35'sd32767)  ? 16'sh7FFF : (shifted_acc < -35'sd32768)  ? 16'sh8000 : shifted_acc[15:0];

always @(posedge clk) begin

    sample_done <= 1'b0; // only a 1 cycle pulse

   // first check for reset
    if (rst || filter_reset) begin   
        accumulator <= 35'sd0;
        tap_counter <= 4'b0;
        current_sample <= 16'sd0;
        current_coefficient <= 16'sd0;
        multiplication_result <= 17'sd0;
        result_ready <= 1'b0;
        result_position <= 2'b0;
        out_data <= 16'sd0;
        out_valid <= 1'b0;
        sample_done <= 1'b0;
        grab_values <= 1'b0;
        sample_processor_counter <= 4'b0;
        high_and_low_counter <= 2'b0;
        coefficient_select_mux <= 4'b0;
        sample_select_mux <= 4'b0;
        for (i = 0; i < 8; i = i + 1) begin 
            sample_history[i] <= 16'sd0;
        end 
    end
    else begin

        // output was taken by the next block
        if (out_valid && out_ready)
            out_valid <= 1'b0;

        //code block to set up the taps for recceiving the samples
        if (!grab_values && pcm_valid && pcm_ready) begin
            // shuffling the samples up one in the sample history bank
            sample_history[0] <= pcm_data;
            for (i = 1; i < 8; i = i + 1) begin
                sample_history[i] <= sample_history[i-1];
            end
            // if 0 taps are specified it just sends sample through directly
            if (taps_used == 4'd0) begin
                // bypass, no multiplying
                out_data <= pcm_data;
                out_valid <= 1'b1;
                sample_done <= 1'b1;
            end
            else begin // prepping for the multiplcation to happen
                grab_values <= 1'b1;
                sample_processor_counter <= 4'b0;
                high_and_low_counter <= 2'b0;
                sample_select_mux <= 4'b0;
                coefficient_select_mux <= 4'b0;
                accumulator <= 35'sd0;
                result_ready <= 1'b0;
                // first sample/coefficient pair
                current_sample <= pcm_data;
                current_coefficient <= coeff[15:0];
            end
        end

        if (grab_values) begin // if sample has been set up then being the cycle
            // start the multiplication cycle, product goes into a register
            multiplication_result <= signed_product;
            result_position <= high_and_low_counter;
            result_ready <= (sample_processor_counter < taps_used); // checks to see if the counter has properly gone through alal of the taps

            // add the product registered on the previous cycle
            if (result_ready)
                accumulator <= accumulator + shifted_product;

            if (sample_processor_counter < taps_used) begin
                high_and_low_counter <= high_and_low_counter + 1;

                // advance the muxes one cycle before they are used
                if (high_and_low_counter == 2'd2) begin
                    sample_select_mux <= sample_select_mux + 1;
                    coefficient_select_mux <= coefficient_select_mux + 1;
                end

                // last cycle of this tap, grab the next sample and coefficient
                if (high_and_low_counter == 2'd3) begin
                    sample_processor_counter <= sample_processor_counter + 1;

                    // selecting the current sample
                    case (sample_select_mux)
                        3'b000:  current_sample <= sample_history[0];
                        3'b001:  current_sample <= sample_history[1];
                        3'b010:  current_sample <= sample_history[2];
                        3'b011:  current_sample <= sample_history[3];
                        3'b100:  current_sample <= sample_history[4];
                        3'b101:  current_sample <= sample_history[5];
                        3'b110:  current_sample <= sample_history[6];
                        3'b111:  current_sample <= sample_history[7];
                        default: current_sample <= sample_history[0];  // Default case handles undefined states
                    endcase

                    case (coefficient_select_mux)
                        3'b000:  current_coefficient <= coeff[15:0];
                        3'b001:  current_coefficient <= coeff[31:16];
                        3'b010:  current_coefficient <= coeff[47:32];
                        3'b011:  current_coefficient <= coeff[63:48];
                        3'b100:  current_coefficient <= coeff[79:64];
                        3'b101:  current_coefficient <= coeff[95:80];
                        3'b110:  current_coefficient <= coeff[111:96];
                        3'b111:  current_coefficient <= coeff[127:112];
                        default: current_coefficient <= coeff[15:0];  // Default case handles undefined states
                    endcase
                end
            end
            else begin
                // two extra cycles: one to add the last product, one to scale the result
                sample_processor_counter <= sample_processor_counter + 1;
            end

            if (sample_processor_counter == taps_used + 4'd1) begin
                sample_done <= 1'b1;
                out_data <= scaled_out; // TEMPORARY FIGURE HOW TO PROPERLY SCALE THIS SO IT SOUNDS GOOD
                out_valid <= 1'b1;
                grab_values <= 1'b0;
                sample_processor_counter <= 4'b0;
                high_and_low_counter <= 2'b0;
                sample_select_mux <= 4'b0;
                coefficient_select_mux <= 4'b0;
                result_ready <= 1'b0;
            end
        end
    end
end
endmodule

