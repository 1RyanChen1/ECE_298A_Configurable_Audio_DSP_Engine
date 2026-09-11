module mac16 (
    input  wire clk,
    input  wire rst_n,
    input  wire clear,
    input  wire en,
    input  wire signed [15:0] a,
    input  wire signed [15:0] b,
    output wire signed [39:0] acc
);

    wire signed [31:0] product;

    assign product = a * b;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            acc <= '0;
        else if (clear)
            acc <= '0;
        else if (en)
            acc <= acc + product;
    end

endmodule
