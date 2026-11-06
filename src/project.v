/*
 * Configurable Audio DSP Engine - TinyTapeout top integration.
 *
 * Source-specific module names/ports checked against:
 *   src/packet_parser.v : rx_packet_parser
 *   src/fir_engine.v   : fir_engine
 *   src/output_tx.v   : out_tx
 *
 * The dsp_state_regs.v implementation now matches these ports.
 * The revised fir_engine.v included in this bundle fixes those issues.
 */
`default_nettype none

module tt_um_example (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

    // -------- Host DTR link / parser outputs --------
    wire        host_ready;
    wire        pcm_valid;
    wire        pcm_ready;
    wire        fir_pcm_ready;
    wire        fir_pcm_valid;
    wire [15:0] pcm_data;

    wire        cfg_valid;
    wire        cfg_ready;
    wire [3:0]  cfg_num_taps;
    wire [3:0]  cfg_out_shift;
    wire        cfg_sat_en;

    wire        coeff_valid;
    wire        coeff_ready;
    wire [2:0]  coeff_idx;
    wire [15:0] coeff_data;

    wire        ctrl_valid;
    wire        ctrl_ready;
    wire [1:0]  ctrl_id;
    wire        protocol_error;

    // -------- Active DSP state / read-only status --------
    wire [3:0]  active_num_taps;
    wire [3:0]  active_out_shift;
    wire        active_sat_en;
    wire [127:0] coeff_flat;   // {coeff[7], ..., coeff[0]}
    wire        filter_reset;
    wire        config_updated;
    wire        coeff_updated;
    wire        config_pending;
    wire        coeff_pending;

    // Do not start another PCM sample on the edge that updates the DSP
    // state or resets history. The parser and FIR must observe identical
    // handshake events (otherwise a sample can be silently dropped).
    wire block_pcm = config_pending || coeff_pending || filter_reset ||
                     cfg_valid || ctrl_valid;
    assign fir_pcm_valid = pcm_valid && !block_pcm;
    assign pcm_ready = fir_pcm_ready && !block_pcm;

    // -------- FIR to audio TX --------
    wire        dsp_busy;
    wire        sample_done;
    wire        out_valid;
    wire        out_ready;
    wire [15:0] out_data;
    wire        audio_out;

    rx_packet_parser u_rx_packet_parser (
        .clk           (clk),
        .rst_n         (rst_n),
        .link          (ui_in),
        .valid         (uio_in[0]),
        .ready         (host_ready),

        .pcm_valid     (pcm_valid),
        .pcm_ready     (pcm_ready),
        .pcm_data      (pcm_data),

        .coeff_valid   (coeff_valid),
        .coeff_ready   (coeff_ready),
        .coeff_idx     (coeff_idx),
        .coeff_data    (coeff_data),

        .cfg_valid     (cfg_valid),
        .cfg_ready     (cfg_ready),
        .cfg_num_taps  (cfg_num_taps),
        .cfg_out_shift (cfg_out_shift),
        .cfg_sat_en    (cfg_sat_en),

        .ctrl_valid    (ctrl_valid),
        .ctrl_ready    (ctrl_ready),
        .ctrl_id       (ctrl_id),
        .protocol_error(protocol_error)
    );

    // Pending-state handling, atomic config activation, coefficient-bank
    // commit, RESET_FILTER and STATUS_CLEAR are owned by this module.
    // See dsp_state_regs.v for its commit and status-clear behavior.
    dsp_state_regs u_dsp_state_regs (
        .clk              (clk),
        .rst_n            (rst_n),

        .cfg_valid        (cfg_valid),
        .cfg_ready        (cfg_ready),
        .cfg_num_taps     (cfg_num_taps),
        .cfg_out_shift    (cfg_out_shift),
        .cfg_sat_en       (cfg_sat_en),

        .coeff_valid      (coeff_valid),
        .coeff_ready      (coeff_ready),
        .coeff_idx        (coeff_idx),
        .coeff_data       (coeff_data),

        .ctrl_valid       (ctrl_valid),
        .ctrl_ready       (ctrl_ready),
        .ctrl_id          (ctrl_id),

        .dsp_busy         (dsp_busy),
        .sample_done      (sample_done),
        .filter_reset     (filter_reset),

        .active_num_taps  (active_num_taps),
        .active_out_shift (active_out_shift),
        .active_sat_en    (active_sat_en),
        .coeff_flat       (coeff_flat),

        .config_updated   (config_updated),
        .coeff_updated    (coeff_updated),
        .config_pending   (config_pending),
        .coeff_pending    (coeff_pending)
    );

    fir_engine u_fir_engine (
        .clk         (clk),
        .rst         (~rst_n),  // fir_engine currently expects active-HIGH reset
        .filter_reset(filter_reset),
        .num_taps    (active_num_taps),
        .out_shift   (active_out_shift),
        .sat_en      (active_sat_en),
        .pcm_valid   (fir_pcm_valid),
        .pcm_ready   (fir_pcm_ready),
        .pcm_data    (pcm_data),
        .dsp_busy    (dsp_busy),
        .sample_done (sample_done),
        .out_valid   (out_valid),
        .out_ready   (out_ready),
        .out_data    (out_data),
        .coeff_flat  (coeff_flat)
    );

    // output_tx.v actually declares module `out_tx` (not `audio_tx`).
    out_tx u_out_tx (
        .clk       (clk),
        .rst_n     (rst_n),
        .pcm_data  (out_data),
        .pcm_valid (out_valid),
        .pcm_ready (out_ready),
        .audio_out (audio_out)
    );

    // TT pinout from Arch.md:
    //   uo[7] Audio, [6] config updated, [5] coeff updated,
    //   [4] protocol error, [3] coeff pending, [2] config pending,
    //   [1] busy, [0] link ready.
    assign uo_out = {
        audio_out,
        config_updated,
        coeff_updated,
        protocol_error,
        coeff_pending,
        config_pending,
        dsp_busy,
        host_ready
    };

    // uio[0] is host VALID input. Others are reserved inputs.
    assign uio_out = 8'b0;
    assign uio_oe  = 8'b0;

    // TT enable is intentionally not used for clock gating.
    wire _unused = &{ena, uio_in[7:1], 1'b0};

endmodule

`default_nettype wire
