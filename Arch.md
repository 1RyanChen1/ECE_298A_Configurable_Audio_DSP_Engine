### **Configurable Audio DSP Engine**

### **Overview**

The asic project aims as a configurable DSP engine for audio processing. The system consists of a RP 2040/2035 on the tinytapeout board(or any other electrically compatible MCU/FPGA SoC) that supplies the clock source for the system and transmits packetized data over an 8-bit DTR interface, and the audio pmod from TinyTapeout Store. The receiver will reassemble the 16 bits word and forward it to packet parser. The parser routes PCM samples directly to the DSP engine, configuration packets to the DSP configuration registers, and coefficient writes to a shadow coefficient bank. The active coefficient bank must not be modified during FIR processing. A COMMIT_COEFF command creates a pending coefficient update; the active and shadow coefficient banks are atomically exchanged only after processing of the current sample has completed. The configurable DSP will time multiplex the operation through a time-multiplexed 16-bit MAC datapath and forward the result to a sigma delta/PWM output 1 bit TX for Audio Pmod.

<img width="1295" height="474" alt="image" src="https://github.com/user-attachments/assets/25d7cd03-5dc6-4c56-9256-78aaae66133d" />



676767676767676767676767676767

### **1. Module Interface**
  Module interface should use ready/valid handshake
  | Interface       | Signals                                                       | Purpose                                         |
| --------------- | ------------------------------------------------------------- | ----------------------------------------------- |
| PCM data        | `valid`, `ready`, `data[15:0]` | Transfer PCM samples from parser to DSP |
| Config          | `valid`, `ready`, `num_taps[3:0]`, `out_shift[3:0]`, `sat_en` | Submit a complete pending DSP configuration |
| Coefficient     | `valid`, `ready`, `idx[2:0]`, `data[15:0]` | Write one coefficient into shadow bank |
| Control         | `valid`, `ready`, `ctrl_id[1:0]` | Submit control command |
| Sample boundary | `sample_done` | DSP indicates current output sample is complete |


### **2. Host Interface**

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

### **3. Packet Format**

   The communication between host and the system is packet based. Each packet is length varied can contains up to 16 flits(include header flit), length specifies the number of payload flits following the header.    Therefore total packet size is LEN + 1 flits, with a maximum packet size of 16 flits / 32 bytes.
   The header packet should follow such format.
   
   
```text
15                  6 5           2 1         0
+--------------------+-------------+-----------+
| Type specific[15:6]| Length[5:2] | Type[1:0] |
+--------------------+-------------+-----------+
```


### Packet Types
| Type | Packet | Description |
|------|--------|-------------|
| `00` | Control | Control the Coeffient overwrite/FIR statemachine, e.g. `COMMIT_COEFF`, `RESET_FILTER`. |
| `01` | Coefficient | Writes FIR coefficients into the shadow coefficient bank. It does not immediately affect the active filter. |
| `10` | Config | Writes persistent DSP configuration, e.g. `NUM_TAPS` and potentially output scaling/format options. |
| `11` | Data | Carries PCM audio samples to the DSP datapath. The parser forwards the payload toward the sample/input register. |


### CONTROL Packet

The CONTROL packet is a single-flit packet (`LEN = 0`). The command is encoded in the type-specific header bits.

| Bits | Field | Description |
|---|---|---|
| `[15:8]` | `RESERVED` | Must be transmitted as `0`; ignored by receiver |
| `[7:6]` | `CTRL_ID[1:0]` | Control command |
| `[5:2]` | `LEN` | Must be `0000` |
| `[1:0]` | `TYPE` | Must be `00` |

| `CTRL_ID` | Command | Description |
|---|---|---|
| `00` | `Reserved` |Reserved |
| `01` | `COMMIT_COEFF` | Requests atomic exchange of active and shadow coefficient banks after the current sample finishes processing |
| `10` | `RESET_FILTER` | Clears FIR sample history/state registers |
| `11` | `Reserved` |Reserved |


### CONFIG Packet

The CONFIG packet is a single-flit packet (`LEN = 0`). Configuration changes must not affect a sample already being processed. If a CONFIG packet arrives while the DSP is processing a sample, the configuration update becomes effective after the current sample completes.

| Bits | Field | Description |
|---|---|---|
| `[15:12]` | `NUM_TAPS[3:0]` | Number of active FIR taps. `0` = bypass, `1–8` = FIR tap count |
| `[11:8]` | `OUT_SHIFT[3:0]` | Arithmetic right-shift applied to the FIR accumulator before conversion back to 16b PCM |
| `[7]` | `SAT_EN` | Enables signed output saturation |
| `[6]` | `RESERVED` | Must be transmitted as `0`; ignored by receiver |
| `[5:2]` | `LEN` | Must be `0000` |
| `[1:0]` | `TYPE` | Must be `10` |

`NUM_TAPS = 0` bypasses FIR processing.

`NUM_TAPS = 1` performs a single coefficient multiplication and can therefore be used as a gain operation.

`NUM_TAPS = 2–8` performs an N-tap FIR.


### COEFF_WRITE Packet

A COEFF_WRITE packet writes FIR coefficients into the shadow coefficient bank. It does not modify the active coefficient bank.

The packet always contains 8 coefficient payload flits, therefore `LEN = 8`.

| Header Bits | Field | Description |
|---|---|---|
| `[15:14]` | `RESERVED` | Must be transmitted as `0`; ignored by receiver |
| `[13:6]` | `COEFF_WE[7:0]` | Per coefficient write enable mask |
| `[5:2]` | `LEN` | Must be `1000` (`8`) |
| `[1:0]` | `TYPE` | Must be `01` |

Payload format:

| Payload Flit | Contents |
|---:|---|
| `0` | `COEFF[0]` |
| `1` | `COEFF[1]` |
| `2` | `COEFF[2]` |
| `3` | `COEFF[3]` |
| `4` | `COEFF[4]` |
| `5` | `COEFF[5]` |
| `6` | `COEFF[6]` |
| `7` | `COEFF[7]` |

For each coefficient `i`:

`COEFF_WE[i] = 1` causes payload flit `i` to overwrite `shadow_coeff[i]`.

`COEFF_WE[i] = 0` causes payload flit `i` to be consumed but leaves `shadow_coeff[i]` unchanged.

Coefficient writes always target the shadow bank. They do not affect the active coefficient bank until a `COMMIT_COEFF` command is processed.

If `coeff_commit_pending = 1`, new COEFF_WRITE packets are stalled until the active/shadow bank exchange has completed.


### DATA Packet

A DATA packet carries signed 16-bit PCM samples.

| Header Bits | Field | Description |
|---|---|---|
| `[15:6]` | `RESERVED` | Must be transmitted as `0`; ignored by receiver |
| `[5:2]` | `LEN` | Number of PCM samples contained in the packet (`1–15`) |
| `[1:0]` | `TYPE` | Must be `11` |

Each payload flit contains exactly one signed 16-bit PCM sample.

| Payload Flit | Contents |
|---:|---|
| `0` | Sample 0 |
| `1` | Sample 1 |
| `...` | `...` |
| `LEN-1` | Sample `LEN-1` |

The maximum DATA packet contains 15 PCM samples:

`1 header + 15 payload flits = 16 flits = 32 bytes`.
   
   Racing Condition:
   
    COEFF_WRITE always targets the shadow bank.
    COMMIT_COEFF sets coeff_commit_pending flag.
    Once coeff_commit_pending=1, the shadow bank is frozen. New coefficient writes are stalled until the active/shadow bank overwrite completes.
    The bank exchange occurs atomically only after the current output sample has finished processing. After the exchange, the previous active bank becomes the new shadow bank and coefficient writes may resume.

    Config update can be concurrent to COEFF_WRITE but must not when DSP is in processing state. If DSP is in processing state, set config_pending to 1 and latch the data, update when DSP returns IDLE. 

    Status Clear: TBD
    
  Further Detail TBD

### **4. DSP Engine** 

   The DSP engine implements a configurable 0–8 tap FIR filter operating on 16-bit PCM samples and 16-bit coefficients. NUM_TAPS = 0 bypasses the filter, while NUM_TAPS = 1...8 determines the number of FIR taps evaluated for each output sample.

  To reduce area and improve timing closure, the engine uses a time-multiplexed 8×8 pipelined multiplier rather than a full combinational 16×16 multiplier. Each signed 16×16 multiplication is decomposed into four 8×8 partial products, which are shifted and accumulated to reconstruct the full product. The resulting products are then accumulated across the configured FIR taps. Pipelining stage could vary depends on timing slack (which Yosys does not tell you)/resume fanciness.

  Signed fixed point semantics and further detail TBD.
  
### **5. Audio Output**
   The DSP produces signed 16bit PCM output samples. The audio output block converts each processed sample into a 1bit sigma-delta or PWM stream compatible with the Audio Pmod.


### **6. Status Signal**
   Status Signal will be used to display chip status directly as long latency sticky flags. Status flag must only be reset through (`Status_Clear`), otherwise the flag must not be cleared.
   
### **7. Verification**
   By inspection the SoC will work

### **8. Scheduled Work & Modules**

  Impl/DV
    
    Rx_packet_parser
    DSP
    Output_Tx
    Config/Coeff/Control_reg_bank

    Integraion/Verification/Tapeout Closure
   
   
  
