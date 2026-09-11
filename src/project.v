/*
 * Copyright (c) 2024 Your Name
 * SPDX-License-Identifier: Apache-2.0
 */

`default_nettype none

module tt_um_example (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    /*
     * Temporary MAC synthesis test.
     *
     * Use primary inputs for operands so synthesis cannot
     * constant-fold the multiplier.
     */
    (* keep *) wire signed [15:0] mac_a;
    (* keep *) wire signed [15:0] mac_b;
    (* keep *) wire signed [39:0] mac_acc;

    assign mac_a = {ui_in, uio_in};
    assign mac_b = {uio_in, ui_in};

    /*
     * Keep the instance even though mac_acc is not currently
     * connected to a TinyTapeout output.
     */
    (* keep *)
    mac16 u_mac (
        .clk   (clk),
        .rst_n (rst_n),
        .clear (1'b0),
        .en    (1'b1),
        .a     (mac_a),
        .b     (mac_b),
        .acc   (mac_acc)
    );

    // Not exposing the MAC result yet.
    assign uo_out  = 8'b0;
    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;

    /*
     * Consume otherwise-unused inputs to avoid lint warnings.
     *
     * ui_in/uio_in/clk/rst_n are already used above.
     */
    wire _unused = &{
        ena,
        mac_acc,
        1'b0
    };

endmodule

`default_nettype wire
