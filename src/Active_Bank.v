module active_bank (
    input  wire        clk,
    input  wire        write_en,

    input  wire [15:0] d0,
    input  wire [15:0] d1,
    input  wire [15:0] d2,
    input  wire [15:0] d3,
    input  wire [15:0] d4,
    input  wire [15:0] d5,
    input  wire [15:0] d6,
    input  wire [15:0] d7,

    output reg  [15:0] q0,
    output reg  [15:0] q1,
    output reg  [15:0] q2,
    output reg  [15:0] q3,
    output reg  [15:0] q4,
    output reg  [15:0] q5,
    output reg  [15:0] q6,
    output reg  [15:0] q7
);

    always @(posedge clk) begin
        if (write_en) begin
            q0 <= d0;
            q1 <= d1;
            q2 <= d2;
            q3 <= d3;
            q4 <= d4;
            q5 <= d5;
            q6 <= d6;
            q7 <= d7;
        end
    end

endmodule
