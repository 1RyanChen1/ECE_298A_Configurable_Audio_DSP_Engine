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
