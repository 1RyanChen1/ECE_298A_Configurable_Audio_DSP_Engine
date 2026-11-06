// ============================================================================
// rx_packet_parser
//
// Receives the 8-bit DTR host link, rebuilds 16-bit flits, decodes packets and
// dispatches PCM / coefficient / config / control transactions.
//
// Structure
//   1. DTR front end   : upper byte @posedge, lower byte @negedge, pushed into
//                        a 2-entry flit FIFO. READY is registered and is
//                        derived from FIFO occupancy (credit based), so it can
//                        stay high on back-to-back cycles: one flit per clock
//                        is sustained as long as the parser keeps up.
//   2. Dispatch gating : the head flit is consumed by the packet FSM only
//                        when the output slot(s) it needs are free, and when
//                        older traffic it must stay ordered against has
//                        already been handed off (see consume_ok).
//   3. Packet FSM      : IDLE / DATA / COEFF.
//
// Error policy: any malformed header sets the sticky protocol_error flag and
// the packet is dropped WITHOUT resync. Payload flits of a bad header are
// parsed as headers. The host must reset (rst_n) to recover.
// ============================================================================
module rx_packet_parser (
    input  logic        clk,
    input  logic        rst_n,

    // 8-bit DTR host interface
    input  logic [7:0]  link,
    input  logic        valid,
    output logic        ready,

    // PCM input to FIR engine
    output logic        pcm_valid,
    input  logic        pcm_ready,
    output logic [15:0] pcm_data,

    // Coefficient write interface
    output logic        coeff_valid,
    input  logic        coeff_ready,
    output logic [2:0]  coeff_idx,
    output logic [15:0] coeff_data,

    // Configuration interface
    output logic        cfg_valid,
    input  logic        cfg_ready,
    output logic [3:0]  cfg_num_taps,
    output logic [3:0]  cfg_out_shift,
    output logic        cfg_sat_en,

    // Control interface
    output logic        ctrl_valid,
    input  logic        ctrl_ready,
    output logic [1:0]  ctrl_id,

    // Parser status
    // FLAG (OWNERSHIP): the sticky protocol_error flag lives in THIS module and
    // is cleared by snooping the STATUS_CLEAR handshake (see "STATUS_CLEAR"
    // block in the packet FSM). Arch.md says dsp_state_regs owns status flags.
    // To be resolved at integration. If ownership moves, only this port and
    // that block (plus the protocol_error <= 1'b1 assignments) change.
    output logic        protocol_error
);

    // ========================================================
    // PACKET DEFINITIONS
    // ========================================================

    localparam TYPE_CTRL   = 2'b00;
    localparam TYPE_COEFF  = 2'b01;
    localparam TYPE_CONFIG = 2'b10;
    localparam TYPE_DATA   = 2'b11;

    // ========================================================
    // INTERNAL SIGNALS
    // ========================================================

    // DTR front end
    logic [7:0]  upper_byte;     // upper byte captured @posedge on accept
    logic        upper_pending;  // high for the cycle after an accept
    logic        accept;         // valid && ready @posedge
    logic [1:0]  occ;            // flits accepted but not yet consumed
                                 //   (includes the one whose lower byte is in flight)
    logic [1:0]  occ_next;

    // 2-entry flit FIFO: written @negedge, read (head) @posedge
    logic [15:0] fifo_mem0;
    logic [15:0] fifo_mem1;
    logic [1:0]  wr_ptr;         // negedge domain
    logic [1:0]  rd_ptr;         // posedge domain
    logic [15:0] flit_data;      // FIFO head
    logic        flit_valid;     // FIFO not empty
    logic        flit_consume;   // FSM consumes the head flit on this posedge
    logic        consume_ok;     // dispatch gating (see below)

    // Output slot availability: empty, or being accepted on this very edge
    logic        pcm_free;
    logic        coeff_free;
    logic        cfg_free;
    logic        ctrl_free;

    // Packet FSM
    typedef enum logic [1:0] {
        IDLE,
        DATA,
        COEFF
    } state_t;

    state_t      state;
    logic [3:0]  remaining;      // DATA payload flits left
    logic [2:0]  coeff_index;    // COEFF payload position
    logic [7:0]  coeff_mask;     // COEFF_WE[7:0] from header

    // ========================================================
    // DTR FRONT END
    // Rising edge : accept upper byte when valid && ready
    // Falling edge: capture lower byte, push 16-bit flit into FIFO
    //
    // READY is registered and equals (occ != 2) after reset:
    //   - low during reset (and for the first clock after release)
    //   - independent of link data and of the packet type
    //   - stays high on consecutive cycles => one flit per clock
    //   - drops only when accepting another flit could overflow the FIFO
    // ========================================================

    assign accept = valid && ready;

    always_comb begin
        occ_next = occ + {1'b0, accept} - {1'b0, flit_consume};
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            upper_byte    <= 8'h00;
            upper_pending <= 1'b0;
            occ           <= 2'd0;
            ready         <= 1'b0;
            rd_ptr        <= 2'd0;
        end
        else begin
            upper_pending <= accept;
            if (accept)
                upper_byte <= link;

            occ   <= occ_next;
            ready <= (occ_next != 2'd2);

            if (flit_consume)
                rd_ptr <= rd_ptr + 2'd1;
        end
    end

    always_ff @(negedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= 2'd0;
        end
        else if (upper_pending) begin
            if (wr_ptr[0])
                fifo_mem1 <= {upper_byte, link};
            else
                fifo_mem0 <= {upper_byte, link};
            wr_ptr <= wr_ptr + 2'd1;
        end
    end

    assign flit_valid = (wr_ptr != rd_ptr);
    assign flit_data  = rd_ptr[0] ? fifo_mem1 : fifo_mem0;

    // ========================================================
    // DISPATCH GATING
    //
    // The head flit is only consumed when the slot(s) it will use are
    // free AND everything it must stay ordered against has been handed off.
    // "Free" = slot empty, or its current content is accepted on this very
    // edge (valid && ready). A new item then appears right after the old one
    // transferred, so order is preserved and full rate is possible.
    //
    // Ordering rules (host program order must be preserved between):
    //   PCM   <-> CONFIG   (sample must see the config sent before it)
    //   PCM   <-> CTRL     (e.g. RESET_FILTER)
    //   COEFF <-> CTRL     (write must reach regs before/after COMMIT_COEFF)
    // Independent (may overlap): COEFF <-> CONFIG, COEFF <-> PCM, CONFIG <-> CTRL
    //
    // Headers that emit nothing by themselves (COEFF, DATA) are always
    // consumed; their payload flits are gated instead.
    // This depends only on internal state, the head flit and the downstream
    // ready inputs, never on READY or link data.
    // ========================================================

    assign pcm_free   = !pcm_valid   || pcm_ready;
    assign coeff_free = !coeff_valid || coeff_ready;
    assign cfg_free   = !cfg_valid   || cfg_ready;
    assign ctrl_free  = !ctrl_valid  || ctrl_ready;

    always_comb begin
        consume_ok = 1'b1;

        case (state)

            IDLE: begin
                case (flit_data[1:0])
                    TYPE_CTRL:   consume_ok = ctrl_free && pcm_free && coeff_free;
                    TYPE_CONFIG: consume_ok = cfg_free  && pcm_free;
                    default:     consume_ok = 1'b1;   // COEFF / DATA headers
                endcase
            end

            DATA: begin
                consume_ok = pcm_free && cfg_free && ctrl_free;
            end

            COEFF: begin
                // A disabled coefficient is still consumed without output.
                if (coeff_mask[coeff_index])
                    consume_ok = coeff_free && ctrl_free;
                else
                    consume_ok = 1'b1;
            end

            default: begin
                consume_ok = 1'b1;   // illegal state: drain and recover below
            end

        endcase
    end

    assign flit_consume = flit_valid && consume_ok;

    // ========================================================
    // PACKET FSM
    // ========================================================

    always_ff @(posedge clk or negedge rst_n) begin

        if (!rst_n) begin

            state          <= IDLE;
            remaining      <= 4'd0;
            coeff_index    <= 3'd0;
            coeff_mask     <= 8'h00;

            pcm_valid      <= 1'b0;
            pcm_data       <= 16'h0000;

            coeff_valid    <= 1'b0;
            coeff_idx      <= 3'd0;
            coeff_data     <= 16'h0000;

            cfg_valid      <= 1'b0;
            cfg_num_taps   <= 4'd0;
            cfg_out_shift  <= 4'd0;
            cfg_sat_en     <= 1'b0;

            ctrl_valid     <= 1'b0;
            ctrl_id        <= 2'b00;

            protocol_error <= 1'b0;

        end
        else begin

            // ------------------------------------------------
            // Release output slots after handshake.
            // A new item loaded below on the same edge wins
            // (later nonblocking assignment).
            // ------------------------------------------------

            if (pcm_valid   && pcm_ready)   pcm_valid   <= 1'b0;
            if (coeff_valid && coeff_ready) coeff_valid <= 1'b0;
            if (cfg_valid   && cfg_ready)   cfg_valid   <= 1'b0;
            if (ctrl_valid  && ctrl_ready)  ctrl_valid  <= 1'b0;

            // ------------------------------------------------
            // STATUS_CLEAR (ctrl_id = 2'b11) accepted by regs.
            // This block is deliberately placed BEFORE the decode logic:
            // a later nonblocking assignment wins, so a protocol_error <= 1
            // on the same edge dominates this clear (set dominates clear).
            // This case is reachable: a bad CTRL header can be consumed on the
            // same edge a previous STATUS_CLEAR is accepted.
            // ------------------------------------------------

            if (ctrl_valid && ctrl_ready && (ctrl_id == 2'b11))
                protocol_error <= 1'b0;

            // ------------------------------------------------
            // Consume the head 16-bit flit
            // ------------------------------------------------

            if (flit_consume) begin

                case (state)

                    // ========================================
                    // IDLE: HEADER DECODE
                    // ========================================
                    IDLE: begin

                        case (flit_data[1:0])

                            // CONTROL: LEN must be 0, CTRL_ID 00 is invalid
                            TYPE_CTRL: begin
                                if ((flit_data[5:2] == 4'd0) &&
                                    (flit_data[7:6] != 2'b00)) begin
                                    ctrl_id    <= flit_data[7:6];
                                    ctrl_valid <= 1'b1;
                                end
                                else begin
                                    protocol_error <= 1'b1;
                                end
                            end

                            // COEFF_WRITE: LEN must be 8
                            TYPE_COEFF: begin
                                if (flit_data[5:2] == 4'd8) begin
                                    coeff_mask  <= flit_data[13:6];
                                    coeff_index <= 3'd0;
                                    state       <= COEFF;
                                end
                                else begin
                                    protocol_error <= 1'b1;
                                end
                            end

                            // CONFIG: LEN must be 0.
                            // FLAG (NUM_TAPS 9..15): not checked here, passed
                            // through as-is to save area. Downstream
                            // (dsp_state_regs / fir_engine) MUST handle values
                            // > 8 without hanging (e.g. clamp to 8 or treat as
                            // bypass); a tap counter that never reaches the
                            // value would stall the whole pipeline.
                            TYPE_CONFIG: begin
                                if (flit_data[5:2] == 4'd0) begin
                                    cfg_num_taps  <= flit_data[15:12];
                                    cfg_out_shift <= flit_data[11:8];
                                    cfg_sat_en    <= flit_data[7];
                                    cfg_valid     <= 1'b1;
                                end
                                else begin
                                    protocol_error <= 1'b1;
                                end
                            end

                            // DATA: LEN must be 1..15
                            TYPE_DATA: begin
                                if (flit_data[5:2] != 4'd0) begin
                                    remaining <= flit_data[5:2];
                                    state     <= DATA;
                                end
                                else begin
                                    protocol_error <= 1'b1;
                                end
                            end

                        endcase

                    end

                    // ========================================
                    // DATA PAYLOAD: one PCM sample per flit
                    // ========================================
                    DATA: begin

                        pcm_data  <= flit_data;
                        pcm_valid <= 1'b1;

                        if (remaining == 4'd1)
                            state <= IDLE;

                        remaining <= remaining - 4'd1;

                    end

                    // ========================================
                    // COEFF PAYLOAD: index advances for every flit,
                    // write only if the matching COEFF_WE bit is set
                    // ========================================
                    COEFF: begin

                        if (coeff_mask[coeff_index]) begin
                            coeff_idx   <= coeff_index;
                            coeff_data  <= flit_data;
                            coeff_valid <= 1'b1;
                        end

                        if (coeff_index == 3'd7)
                            state <= IDLE;

                        coeff_index <= coeff_index + 3'd1;   // wraps 7 -> 0

                    end

                    // Illegal encoding (should be unreachable): recover.
                    default: begin
                        state          <= IDLE;
                        protocol_error <= 1'b1;
                    end

                endcase

            end

        end

    end

endmodule
