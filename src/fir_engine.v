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


    //mux control signals
    reg [3:0] coefficient_select_mux;
    reg [3:0] sample_select_mux;
    reg upper_or_lower_select_coefficient; // mux control signal for upper and lower 8 bits of the coefficient bank
    reg upper_or_lower_select_sample; // mux control signal for the upper and lower 8 bits for the sample bank

    // counters and flags 
    reg grab_values;
    reg [3:0] sample_processor_counter; // large counter for overall proccessing 
    reg [2:0] high_and_low_counter; // counter to check if youve done lower lower, upper upper etc;



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

    if (!grab_values) begin
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

        case (coefficient_select_mux_select_mux)
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
    case()




    // go through each sample sequntially
    // for each sample, take the lower 8 bits and multiply them with eaach of the bits
    // shift where it feels appropriate 
    // feed this to an accumulator register
    // then create an output ready signal to feed to a safety register or smth lkke thatt?

end
endmodule
