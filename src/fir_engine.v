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
    input  wire signed [15:0] coeff [0:7], // actual coefficiients
    output reg signed [15:0] output_pcm_data, // pcm data after it has already been proccessed
);
    // sums and intermediary values for coefficients and samples
    reg signed [15:0] sample_history [0:7]; // previous samples, 0 is latest, 7 is the oldest
    reg [3:0] tap_counter; // to keep track of how many taps have been proceesed through the multiply-accumulate
    reg signed [31:0] accumulator; // accumulated sum, which then gates shifted
    reg signed [15:0] current_sample; // current pcm sample
    reg signed [15:0] current_coefficient; // current pcm sample
    reg signed [7:0] current_8_bits_coefficient; // current pcm sample
    reg signed [7:0] current_8_bits_sample; // current pcm sample

    //mux control signals
    reg [3:0] coefficient_select_mux;
    reg [3:0] sample_select_mux;
    reg upper_or_lower_select_coefficient; // mux control signal for upper and lower 8 bits of the coefficient bank
    reg upper_or_lower_select_sample; // mux control signal for the upper and lower 8 bits for the sample bank

    // counters and flags 
    reg grab_values;
    reg [3:0] sample_processor_counter; // large counter for overall proccessing 
    reg [1:0] high_and_low_counter; // counter to check if youve done lower lower, upper upper etc;
    reg signed [15:0] multiplication_result; // intermediary mulplication result



    // settinng all the intermediary values to 0
    sample_processor_counter <= 4'b0;
    coefficient_mux_select <= 4'b0;
    sample_mux_select <= 4'b0;
    upper_or_lower_select_coefficient <= 1'b0; // mux control signal for upper and lower 8 bits of the coefficient bank
    upper_or_lower_select_sample <= 1'b0;
    sample_history [0:7] <= 16'b0 // setting all the past coefficients to 0

always @(posedge) begin
 // shuffling the coefficients up one in the sample history bank

   // first check for reset
    if (rst || filter_reset) begin
            
        accumulator <= 32'sd0;
        tap_index <= 4'b0;
        current_sample <= 16'sd0;
        out_data <= 16'sd0;
        out_valid <= 1'b0;
        sample_done <= 1'b0;
        dsp_busy <= 1'b0;
        out_ready <= 1'b0;
        for (i = 0; i < MAX_TAPS; i = i + 1) begin 
            sample_history[i] <= 16'sd0;
        end 
    end

    if (!grab_values && pcm_valid && pcm_ready) begin
        grab_values <= 1'b1;
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
            3'b000:  current_coefficient <= coeff[0];
            3'b001:  current_coefficient <= coeff[1];
            3'b010:  current_coefficient <= coeff[2];
            3'b011:  current_coefficient <= coeff[3];
            3'b100:  current_coefficient <= coeff[4];
            3'b101:  current_coefficient <= coeff[5];
            3'b110:  current_coefficient <= coeff[6];
            3'b111:  current_coefficient <= coeff[7];
            default: current_coefficient <= coeff[0];  // Default case handles undefined states
        endcase
    end 

    // start the multiplication cycle
    if(grab_values && high_and_low_counter < 5)begin
        case(upper_or_lower_select_coefficient)
        1'b0: current_8_bits_coefficient <= current_coefficient [7:0];
        1'b1: current_8_bits_coefficient <= current_coefficient [15:8];
        default:
        endcase

        case(upper_or_lower_select_sample)
        1'b0: current_8_bits_sample <= current_sample [7:0];
        1'b1: current_8_bits_sample <= current_sample [15:8];
        default:
        endcase

        high_and_low_counter <= high_and_low_counter + 1;
    end

    multiplication_result <= current_coefficient * current_coefficient

    if(upper_or_lower_select_coefficient && upper_or_lower_select_sample)begin
        multiplication_result <= multiplication_result >> 16
        accumulator <= multiplication_result + accumulator
    end
    else begin
    multiplication_result <= multiplication_result >> 8 * (upper_or_lower_select_coefficient || upper_or_lower_select_sample)
    accumulator <= multiplication_result + accumulator
    end

    if (high_and_low_counter < 5 && grab_values)begin
        high_and_low_counter <= high_and_low_counter + 1;
        upper_or_lower_select_coefficient <= upper_or_lower_select_coefficient + 1;
        upper_or_lower_select_sample <= upper_or_lower_select_sample + 1;
    end

    if ( high_and_low_counter > 5 && sample_processor_counter < 8) begin
        high_and_low_counter <= 0;
        sample_processor_counter <= sample_processor_counter + 1;
        sample_select_mux <= sample_select_mux + 1;
        coefficient_select_mux <= coefficient_select_mux + 1;
    end 

    if(sample_processor_counter > 8) begin
        sampled_done <= 1;
        output_pcm_data <= accumulator / 16 // TEMPORARY FIGURE HOW TO PROPERLY SCALE THIS SO IT SOUNDS GOOD
        out_ready <= 1;
        out_valid <= 1;
    end

    // then create an output ready signal to feed to a safety register or smth lkke thatt?

end
endmodule
