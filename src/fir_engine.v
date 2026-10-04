module fir_engine #(
)(
    input  wire clk, // clk for the module
    input  wire rst, // reset
    input  wire [3:0] num_taps, // number of taps being used
    input  wire [3:0] out_shift, // how much shifting is done for the signal
    input  wire sat_en, // saturation enable signal
    input  wire pcm_valid,// if the data is valid for this cycle
    output wire pcm_ready, // if the data is ready 
    input  wire signed [15:0] pcm_data, // the actual data beingg sent
    input  wire signed [15:0] coeff [0:MAX_TAPS-1], // actual coefficiients
    input  wire filter_reset, // reset the filter setings
    output reg signed [15:0] output_pcm_data, // pcm data after it has already been proccessed
    output wire dsp_busy, // if the engine is currently proccesign samples
    output reg sample_done, // if the sample is finished being proccesing
    output reg out_valid, //if the output is valid
    input  wire out_ready // if the output pcm is ready to be sent
);
    reg signed [15:0] sample_history [0:MAX_TAPS-1]; // previous samples to move along the multiplier
    reg [3:0] tap_counter; // to keep track of how many taps have been proceesed through the multiply-accumulate
    reg signed [31:0] accumulator; // accumulated sum, which then gates shifted
    reg [3:0] tap_index; // select for the tap mux
    reg signed [15:0] current_sample; // current pcm sample
    reg [1:0] sample_processor_counter;

always @(posedge) begin

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

    if (sample_processor_counter == 1)begin

    end 

end
endmodule
