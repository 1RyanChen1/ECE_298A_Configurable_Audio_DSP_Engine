module out_tx (
    input  wire clk,
    input  wire rst_n,
  
    input  wire [15:0] pcm_data,
    input  wire pcm_valid,
    output wire pcm_ready,

    output reg audio_out
);

    reg [15:0] sample_reg;
    reg [15:0] sigma_acc;

    wire [15:0] unsigned_sample;
    wire [16:0] sigma_sum;

    // always ready assume sample schedule is done by RP
    assign pcm_ready = 1'b1;

    // convert to signed
    // -32768 -> 0
    //  0 -> 32768
    // +32767 -> 65535
    assign unsigned_sample = sample_reg ^ 16'h8000;
    // accumulator
    assign sigma_sum = {1'b0, sigma_acc} + {1'b0, unsigned_sample};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sample_reg <= 16'b0;
            sigma_acc  <= 16'b0;
            audio_out  <= 1'b0;
        end else begin
            // capture the latest processed PCM sample
            if (pcm_valid && pcm_ready)
                sample_reg <= pcm_data;
            // sigma delta modulation runs every clock
            sigma_acc <= sigma_sum[15:0];
            audio_out <= sigma_sum[16];
        end
    end

endmodule
