**Configurable Audio DSP Engine**

**1.Overview**
The asic project aims as a configurable DSP engine for audio processing. The system consists of a RP 2040/2035 on the tinytapeout board(or any other electrically compatible MCU/FPGA SoC) that supplies the clock source for the system and transmits packetized data over an 8-bit DTR interface, and the audio pmod from TinyTapeout Store. The receiver will reassemble the 16 bits word and forward it to packet parser. The parser routes PCM samples directly to the DSP engine, configuration packets to the DSP configuration registers, and coefficient writes to a shadow coefficient bank. The active coefficient bank must not be modified during FIR processing. A COMMIT_COEFF command creates a pending coefficient update; the active and shadow coefficient banks are atomically exchanged only after processing of the current sample has completed. The configurable DSP will time multiplex the operation through a time-multiplexed 16-bit MAC datapath and forward the result to a sigma delta/PWM output 1 bit TX for Audio Pmod.

<img width="1295" height="363" alt="image" src="https://github.com/user-attachments/assets/123cbca5-a552-4d15-8b3f-4a6667f3467e" />

676767676767676767676767676767

**2. Host Interface**
  Host interface consists of following signals:
  Host:
    CLK 
    [7:0] link
    Valid
  Device:
    Ready

One logical transfer = one 16-bit flit.
Rising edge:
    flit[15:8] <- link[7:0]
Falling edge:
    flit[7:0] <- link[7:0] 
A new flit is accepted when VALID && READY are sampled high on the rising edge.
Once accepted, the host must complete the falling-edge transfer of the lower byte.

If VALID=1 and READY=0 at the rising edge, the host must retry the same logical 16-bit flit on the next cycle.

VALID must not depend on READY.
READY should indicate receiver availability independently of the currently transmitted data.

<img width="1443" height="314" alt="image" src="https://github.com/user-attachments/assets/057ca978-3656-4313-ae85-e69de4c8cf78" />
An example of DTR handshake waveform

**3. Packet Format**
   The communication between host and the system is packet based. Each packet is length varied can contains up to 16 flits(include header flit), length specifies the number of payload flits following the header.    Therefore total packet size is LEN + 1 flits, with a maximum packet size of 16 flits / 32 bytes.
   The header packet should follow such format.
   
   
   +-15------------6-5-----------2-1---------0 +
   
   | Reserved[15:6]  | length[5:2]  | type[1:0]   |
   
   +------------------------------------------ +

   Packet Type
   Type
   00  Control Packet: one-shot commands rather than persistent settings, e.g. COMMIT_COEFF, RESET_FILTER_STATE, FLUSH.
   01  Coefficient Packet: writes FIR coefficients into the shadow coefficient bank. It does not immediately affect the active filter.
   10  Config Packet: writes persistent DSP configuration, e.g. NUM_TAPS, maybe output scaling/format options later.
   11  Data Packet: carries PCM audio samples to the DSP datapath. The parser forwards the payload toward the sample/input register.
   
   Racing Condition
    COEFF_WRITE always targets the shadow bank.
    COMMIT_COEFF sets coeff_commit_pending flag.
    Once coeff_commit_pending=1, the shadow bank is frozen. New coefficient writes are stalled until the active/shadow bank exchange completes.
    The bank exchange occurs atomically only after the current output sample has finished processing. After the exchange, the previous active bank becomes the new shadow bank and coefficient writes may resume.
  Further Detail TBD

**4. DSP Engine**
   The DSP engine implements a configurable 0–8 tap FIR filter operating on 16-bit PCM samples and 16-bit coefficients. NUM_TAPS = 0 bypasses the filter, while NUM_TAPS = 1...8 determines the number of FIR taps evaluated for each output sample.

  To reduce area and improve timing closure, the engine uses a time-multiplexed 8×8 pipelined multiplier rather than a full combinational 16×16 multiplier. Each signed 16×16 multiplication is decomposed into four 8×8 partial products, which are shifted and accumulated to reconstruct the full product. The resulting products are then accumulated across the configured FIR taps. Pipelining stage could vary depends on timing slack (which Yosys does not tell you)/resume fanciness.

  Further Detail TBD
  
**5. Audio Output**
   The DSP produces signed 16bit PCM output samples. The audio output block converts each processed sample into a 1bit sigma-delta or PWM stream compatible with the Audio Pmod.
**6. Verification**
   By inspection the SoC will work
   
  
