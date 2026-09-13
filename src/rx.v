module rx (
  input wire clk,
  input wire rst_n,
  input wire [7:0] link,
  input wire valid_in,
  output wire ready_in,

  input wire ready_out,
  output reg valid_out,
  output reg [15:0] d_out
);

  reg[7:0] h_reg, l_reg;
  reg prev_valid_in, prev_ready_in;
  // high reg and low reg
  assign ready_in = !valid_out || ready_out;
  always@(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      h_reg <= '0;
      prev_valid_in <= 0;
      prev_ready_in <= 0;
    end else if(valid_in && ready_in)begin 
      prev_valid_in <= valid_in;
      prev_ready_in <= ready_in;
      h_reg <= link;
      
    end
  end

  always@(negedge clk or negedge rst_n) begin
    if(!rst_n) begin
      l_reg <= '0;
    end else if(valid_in && ready_in) begin 
      l_reg <= link;
    end
  end
  
  always@(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      d_out <= '0;
      valid_out <= 0;
    end else  begin
      // if handshaked cleared valid
      if(valid_out && ready_out)
        valid_out <= 0;
      end
    // if input handshaked
    if(prev_valid_in && prev_ready_in) begin 
        d_out <= {h_reg, l_reg};
        valid_out <= 1;
      end
  end
  
endmodule
