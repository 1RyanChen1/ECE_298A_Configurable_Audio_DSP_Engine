`default_nettype none

// Persistent DSP configuration, coefficient state, and control/status logic.
//
// Control opcodes (header[7:6]):
//   2'b01 : COMMIT_COEFF
//   2'b10 : RESET_FILTER
//   2'b11 : STATUS_CLEAR
//   2'b00 : reserved (parser rejects this)
//
// Commit semantics:
//   All writes target shadow_coeff_bank. A COMMIT copies shadow into active
//   at a safe boundary; shadow retains the new contents. This deliberately
//   keeps shadow == active immediately after commit, so masked/partial writes
//   in later packets preserve coefficients from the CURRENT filter.
//   Unlike a literal bank SWAP, old active coefficients are not copied back
//   into the shadow bank.
//
// Safe boundary:
//   If DSP is idle, an accepted config or commit is applied immediately.
//   If busy, the request is latched and applied once DSP is idle. Pending
//   requests block later requests of the same class via READY.
//   Integration must prevent a new PCM handshake on the same edge as a
//   control/config update, or while config_pending/coeff_pending/filter_reset
//   is asserted (see accompanying project.v).
//
// Sticky status:
//   config_updated/coeff_updated are cleared by STATUS_CLEAR only.
//   A newly completed update wins over a simultaneous STATUS_CLEAR.
//   protocol_error is intentionally owned by rx_packet_parser, NOT here.
//
module dsp_state_regs (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         cfg_valid,
    output wire         cfg_ready,
    input  wire [3:0]   cfg_num_taps,
    input  wire [3:0]   cfg_out_shift,
    input  wire         cfg_sat_en,

    input  wire         coeff_valid,
    output wire         coeff_ready,
    input  wire [2:0]   coeff_idx,
    input  wire [15:0]  coeff_data,

    input  wire         ctrl_valid,
    output reg          ctrl_ready,
    input  wire [1:0]   ctrl_id,

    input  wire         dsp_busy,
    input  wire         sample_done, // informative; idle controls safe activation
    output wire         filter_reset,

    output reg  [3:0]   active_num_taps,
    output reg  [3:0]   active_out_shift,
    output reg          active_sat_en,
    output wire [127:0] coeff_flat,

    output reg          config_updated,
    output reg          coeff_updated,
    output reg          config_pending,
    output reg          coeff_pending
);

    localparam [1:0] CTRL_COMMIT = 2'b01;
    localparam [1:0] CTRL_RESET  = 2'b10;
    localparam [1:0] CTRL_CLEAR  = 2'b11;

    reg [3:0] pending_num_taps;
    reg [3:0] pending_out_shift;
    reg       pending_sat_en;
    reg       reset_pending;

    reg [127:0] active_coeff_bank;
    reg [127:0] shadow_coeff_bank;

    wire cfg_fire;
    wire coeff_fire;
    wire ctrl_fire;
    wire commit_fire;
    wire reset_fire;
    wire status_clear;
    wire safe;
    wire apply_cfg_pending;
    wire apply_coeff_pending;

    assign safe = !dsp_busy;

    assign cfg_ready   = !config_pending;
    assign coeff_ready = !coeff_pending;

    // Do not accept a COMMIT concurrently with an outstanding coefficient
    // write. The parser can hand off the previously written coefficient first.
    always @(*) begin
        case (ctrl_id)
            CTRL_COMMIT: ctrl_ready = !coeff_pending && !coeff_valid;
            CTRL_RESET:  ctrl_ready = !reset_pending;
            CTRL_CLEAR:  ctrl_ready = 1'b1;
            default:     ctrl_ready = 1'b1;
        endcase
    end

    assign cfg_fire    = cfg_valid && cfg_ready;
    assign coeff_fire  = coeff_valid && coeff_ready;
    assign ctrl_fire   = ctrl_valid && ctrl_ready;
    assign commit_fire = ctrl_fire && (ctrl_id == CTRL_COMMIT);
    assign reset_fire  = ctrl_fire && (ctrl_id == CTRL_RESET);
    assign status_clear= ctrl_fire && (ctrl_id == CTRL_CLEAR);

    assign apply_cfg_pending   = config_pending && safe;
    assign apply_coeff_pending = coeff_pending && safe;

    // Synchronous FIR reset, asserted during an idle clock cycle.
    // If a RESET_FILTER command arrives while idle, it can reset immediately;
    // otherwise wait until the DSP becomes idle. Pending clears on the
    // rising edge on which FIR observes filter_reset.
    assign filter_reset = safe && (reset_pending || reset_fire);

    // coeff[i] occupies bits [16*i +: 16]
    assign coeff_flat = active_coeff_bank;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_num_taps  <= 4'd0; // bypass by default
            active_out_shift <= 4'd0;
            active_sat_en    <= 1'b0;
            pending_num_taps <= 4'd0;
            pending_out_shift <= 4'd0;
            pending_sat_en  <= 1'b0;

            active_coeff_bank <= 128'd0;
            shadow_coeff_bank <= 128'd0;

            config_pending <= 1'b0;
            coeff_pending  <= 1'b0;
            reset_pending  <= 1'b0;
            config_updated <= 1'b0;
            coeff_updated  <= 1'b0;
        end else begin
            // Clear first: an update event lower down overrides this clear.
            if (status_clear) begin
                config_updated <= 1'b0;
                coeff_updated  <= 1'b0;
            end

            // One pending configuration can be held while the FIR is busy.
            // Values 9..15 are clamped to 8 so the FIR cannot hang.
            if (cfg_fire) begin
                if (safe) begin
                    active_num_taps   <= (cfg_num_taps > 4'd8) ? 4'd8 : cfg_num_taps;
                    active_out_shift <= cfg_out_shift;
                    active_sat_en    <= cfg_sat_en;
                    config_updated   <= 1'b1;
                end else begin
                    pending_num_taps  <= (cfg_num_taps > 4'd8) ? 4'd8 : cfg_num_taps;
                    pending_out_shift <= cfg_out_shift;
                    pending_sat_en   <= cfg_sat_en;
                    config_pending   <= 1'b1;
                end
            end

            if (apply_cfg_pending) begin
                active_num_taps   <= pending_num_taps;
                active_out_shift <= pending_out_shift;
                active_sat_en    <= pending_sat_en;
                config_pending   <= 1'b0;
                config_updated   <= 1'b1;
            end

            // Only the shadow bank can be written by the host.
            if (coeff_fire) begin
                case (coeff_idx)
                    3'd0: shadow_coeff_bank[ 15:  0] <= coeff_data;
                    3'd1: shadow_coeff_bank[ 31: 16] <= coeff_data;
                    3'd2: shadow_coeff_bank[ 47: 32] <= coeff_data;
                    3'd3: shadow_coeff_bank[ 63: 48] <= coeff_data;
                    3'd4: shadow_coeff_bank[ 79: 64] <= coeff_data;
                    3'd5: shadow_coeff_bank[ 95: 80] <= coeff_data;
                    3'd6: shadow_coeff_bank[111: 96] <= coeff_data;
                    3'd7: shadow_coeff_bank[127:112] <= coeff_data;
                endcase
            end

            // Commit activates all eight shadow entries atomically.
            // Shadow retains the committed image, supporting later partial
            // writes without stale coefficients from an older filter.
            if (commit_fire) begin
                if (safe) begin
                    active_coeff_bank <= shadow_coeff_bank;
                    coeff_updated    <= 1'b1;
                end else begin
                    coeff_pending <= 1'b1;
                end
            end

            if (apply_coeff_pending) begin
                active_coeff_bank <= shadow_coeff_bank;
                coeff_pending    <= 1'b0;
                coeff_updated    <= 1'b1;
            end

            if (reset_fire && !safe)
                reset_pending <= 1'b1;

            if (filter_reset)
                reset_pending <= 1'b0;
        end
    end

    // sample_done is present to match the top-level interface. The FIR's
    // dsp_busy deassertion is the chosen safe-boundary indication: it remains
    // idle while output_valid is held, so pending changes cannot interrupt a
    // partially executed multiply/accumulate sequence.
    wire _unused = sample_done;

endmodule

`default_nettype wire
