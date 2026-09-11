module mac16 (
    input  wire clk,
    input  wire rst_n,
    input  wire clear,
    input  wire en,
    input  wire signed [15:0] a,
    input  wire signed [15:0] b,
    output reg signed [39:0] acc
);

    reg signed [31:0] product_reg;
    reg signed [39:0] acc_reg;


    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc <= '0;
            product_reg <= '0;
            acc_reg <= '0;
        end
        else if (clear) begin
            acc <= '0;
            acc_reg <= '0;
            product_reg <= '0;
        end
        else if (en) begin
            product_reg <= a * b;
            acc <= acc_reg + product_reg;
        end
    end

endmodule
