module shadow_bank (
    input  wire        clk,
    input  wire        write_en,
    input  wire [2:0]  coeff_idx,
    input  wire [15:0] data_in,

    output reg  [15:0] q0,
    output reg  [15:0] q1,
    output reg  [15:0] q2,
    output reg  [15:0] q3,
    output reg  [15:0] q4,
    output reg  [15:0] q5,
    output reg  [15:0] q6,
    output reg  [15:0] q7
);

    // 1-to-8 demux with write_en as the demux data input:
    // the selected output carries write_en, all others are 0.
    reg [7:0] we;
    always @(*) begin
        we = 8'b0;
        we[coeff_idx] = write_en;
    end

    always @(posedge clk) begin
        if (we[0]) q0 <= data_in;
        if (we[1]) q1 <= data_in;
        if (we[2]) q2 <= data_in;
        if (we[3]) q3 <= data_in;
        if (we[4]) q4 <= data_in;
        if (we[5]) q5 <= data_in;
        if (we[6]) q6 <= data_in;
        if (we[7]) q7 <= data_in;
    end

endmodule
