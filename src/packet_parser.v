module FSM(

    input clk,
    input rst_n,
    
    // FSM inputs
    input transfer,
    input [15:0] flit_data,
    input cnt_is_zero,
    
    // Counter inputs
    output reg load_en,
    output reg dec_en,
    
    // Logic inputs
    output reg dsp_sample_valid,
    output reg [7:0] shadow_we,
    output reg exec_ctrl,
    output reg exec_cfg
);

    // State definitions (1-bit state variable)
    localparam STATE_IDLE   = 1'b0;
    localparam STATE_DECODE = 1'b1;

    reg state, next_state;

    // Direct slicing of fields from the incoming flit bus
    wire [1:0] raw_type = flit_data[1:0];
    wire [3:0] raw_len  = flit_data[5:2];

    // Internal registers to hold header metadata during DECODE state
    reg [1:0] latched_type;
    reg [7:0] latched_we;


// State Register
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= STATE_IDLE;
        end else begin
          state <= next_state;
        end
    end

// Next-State Logic
    always @(*) begin
        next_state = state; // Default: hold current state

        case (state)
            STATE_IDLE: begin
                // If a valid header flit arrives and LEN > 0, move to DECODE
                if (transfer && (raw_len > 4'b0000)) begin
                    next_state = STATE_DECODE;
                end
            end

            STATE_DECODE: begin
                // Once payload counter hits zero on a valid transfer, return to IDLE
                if (transfer && cnt_is_zero) begin
                    next_state = STATE_IDLE;
                end
            end

            default: next_state = STATE_IDLE;
        endcase
    end

// Header Register Latching
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            latched_type <= 2'b00;
            latched_we   <= 8'h00;
        end else if ((state == STATE_IDLE) && transfer) begin
            latched_type <= raw_type;
            latched_we   <= flit_data[13:6]; // COEFF_WE mask from header
        end
    end
    
// Output Dispatch Logic
    always @(*) begin
        // Default values
        load_en         = 1'b0;
        dec_en          = 1'b0;
        dsp_sample_valid = 1'b0;
        exec_ctrl        = 1'b0;
        exec_cfg         = 1'b0;

        case (state)
            STATE_IDLE: begin
                if (transfer) begin
                    if (raw_len > 4'b0000) begin
                        load_en = 1'b1; // Trigger payload counter load
                    end else begin
                        // Single-flit commands (LEN == 0)
                        if (raw_type == 2'b00) exec_ctrl = 1'b1;
                        if (raw_type == 2'b10) exec_cfg  = 1'b1;
                    end
                end
            end

            STATE_DECODE: begin
                if (transfer) begin
                    dec_en = 1'b1; // Decrement payload counter
                    
                    if (latched_type == 2'b11) begin
                        dsp_sample_valid = 1'b1; // DATA payload strobe
                    end
                end
            end
        endcase
    end

module payload_counter(

    input            clk,
    input            rst_n,
    input            load_cnt,
    input            dec_cnt,
    input      [3:0] load_val,
    
    output           cnt_is_zero
    
);

    reg [3:0] count;
    
    always@(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            count <= 4'b0000;
        end else if(load_cnt) begin
          count <= load_val - 4'b0001;
         end else if(dec_cnt && (count > 4'b0000)) begin
            count <= count - 4'b0001;
        end
    end
    
    assign cnt_is_zero = (count == 4'b0000);
    
endmodule



    

endmodule

module packet_parser (
  input wire clk,
  input wire rst_n,

  input wire [15:0] d_in,
  input wire valid_in,
  output wire ready_in,

  output reg [15:0] d_out,
  output reg valid_out,
  output reg config_reg,
  output reg config_addr
);


endmodule
