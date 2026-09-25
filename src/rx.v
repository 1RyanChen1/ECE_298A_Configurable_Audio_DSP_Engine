module rx (
  input wire clk,
  input wire rst_n,
  input wire [7:0] link,
  input wire valid_in,
  output wire ready_in,

  input wire ready_out,
  output wire valid_out,
  output wire [15:0] d_out
);

  reg[7:0] h_reg, l_reg;
  reg accepted;
  wire fifo_pop;

  wire [1:0] used;
  wire [2:0] used_after;

  assign fifo_pop = fifo_rd_v && fifo_rd_r;

  assign used_after = {1'b0, used} + (accepted ? 3'd1 : 3'd0) - (fifo_pop ? 3'd1 : 3'd0);

  assign ready_in = (used_after < 3'd2);
  // high reg and low reg
  always@(posedge clk or negedge rst_n) begin
    if(!rst_n) begin
      h_reg <= '0;
      accepted <= 0;
    end else if(valid_in && ready_in)begin 
      accepted <= 1;
      h_reg <= link;
      
    end else begin
      accepted <= 0;
    end    
  end

  always@(negedge clk or negedge rst_n) begin
    if(!rst_n) begin
      l_reg <= '0;
    end else if(accepted) begin 
      l_reg <= link;
    end
  end

  wire [15:0] fifo_wr, fifo_rd;
  wire fifo_wr_v,fifo_wr_r, fifo_rd_v, fifo_rd_r;

  assign fifo_wr = {h_reg,l_reg};
  assign fifo_wr_v = accepted;
  assign ready_in = (used_after < 3'd2);
  assign d_out = fifo_rd;
  assign valid_out = fifo_rd_v;
  assign fifo_rd_r = ready_out;
    
  fifo2 u_fifo(
               .clk(clk),
               .rst_n(rst_n),
               .d_in(fifo_wr),
               .valid_in(fifo_wr_v),
               .ready_in(fifo_wr_r),
    .ready_out(fifo_rd_r),
    .valid_out(fifo_rd_v),
    .d_out(fifo_rd),
    .used(used)
              );

  
endmodule

module fifo2 (
  input wire clk,
  input wire rst_n,
  input wire [15:0] d_in,
  input wire valid_in,
  output wire ready_in,

  input wire ready_out,
  output wire valid_out,
  output wire [15:0] d_out,

  output wire [1:0] used
);
  localparam DEPTH = 2;
  localparam ptr_width = DEPTH  > 1 ? $clog2(DEPTH) : 1;
  wire full,empty;
  reg[ptr_width:0] wr_ptr, rd_ptr;
  reg[15:0] fifo[0:DEPTH-1];
  
  assign full = (wr_ptr[ptr_width-1:0] == rd_ptr[ptr_width-1:0]) && (wr_ptr[ptr_width] != rd_ptr[ptr_width]); 
  assign empty = (wr_ptr[ptr_width:0] == rd_ptr[ptr_width:0]); 

  assign ready_in = !full || valid_out && ready_out;
  assign valid_out = !empty;

  assign used = wr_ptr - rd_ptr; // 0 means empty, 1 means 1 spot used, 2 means full
  assign d_out = fifo[rd_ptr[ptr_width-1:0]];
  always@(posedge clk or negedge rst_n)
      if(!rst_n) begin
        for(int i = 0; i<DEPTH;i++)
          fifo[i] <= '0;
        wr_ptr <= '0;
        rd_ptr <= '0;
    end else begin 
    if(ready_in && valid_in) begin
      wr_ptr <= wr_ptr + 1;
      fifo[wr_ptr[ptr_width-1:0]] <= d_in;
    end
    if(ready_out && valid_out) begin
      rd_ptr <= rd_ptr + 1;
    end

    end
endmodule
