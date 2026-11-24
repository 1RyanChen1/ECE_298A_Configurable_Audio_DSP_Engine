# Architecture Overview

Below can be found the general block diagram overview of our FIR Engine DSP design.

<img width="922" height="359" alt="Overview drawio" src="https://github.com/user-attachments/assets/9f94bf34-aa0a-43e7-8f6b-122d78f5ba03" />

Starting on the left side, an external microcontroller sends clock and data streams into the Packet Parser, which decodes and routes incoming payloads into three distinct paths: raw audio samples (pcm_data, pcm_valid), filter weights (coeff), and operational settings (config). 

New filter weights are staged safely in a double-buffered Coefficient Bank (Active + Shadow) for glitch-free updates, while Config & Status Flags supplies runtime parameters like tap count , saturation, and bit-shifting. 

At the core of the design flow, the FIR Engine processes incoming audio using ready/valid handshaking (pcm_ready) and reports its current states (dsp_busy, sample_done) back to the microcontroller. 

Finally, the filtered digital signal is converted by a Sigma-Delta PWM Output stage to drive real-time playback through the tiny tapeout pmod.

## Parser

## Coefficient Bank

<img width="1022" height="681" alt="activeshadwo drawio (1)" src="https://github.com/user-attachments/assets/a9d6bc00-424c-4969-bcec-f6b7e574e5f6" />


Incoming coefficients arrive one tap at a time from the packet parser and get written into the shadow bank, which holds up to 8 filter weights without touching the live filter. Each valid write uses the tap index to pick one 16-bit slot in the shadow bank and stores the new weight while the FIR engine keeps right on running.

When a commit control command comes in, it waits until any active coefficient write is done and the FIR engine is no longer busy. If the filter is still mid-calculation, the commit sits pending until that sample finishes, and the top level holds off new PCM samples so nothing gets out of sync.

Once the filter is idle, all 8 weights copy over from the shadow bank into the active bank at once and raise the updated flag. The shadow bank keeps its values instead of clearing or swapping, so a later packet that only updates a few taps still has the rest ready to go.

As the FIR engine steps through its taps, it reads each active weight off the active bank's bus and multiplies it with the matching sample history entry. A global reset wipes both banks back to zero, while a filter reset only clears the FIR's sample history and state and leaves the stored weights alone.


## FIR Engine


<img width="1200" height="482" alt="FIR Engine" src="https://github.com/user-attachments/assets/d9475376-fa7b-4c97-8441-750d6f01a1c0" />

A sample comes in and gets stored in the sample history, which keeps the last 8. Then the FSM works through the taps one at a time. For each tap, tap_idx picks one coefficient and one old sample, and they wait in Current Coefficient and Current Sample.

The multiply happens one bit at a time. The B mux feeds the adder the sample (only when the current coefficient bit is 1), and the A mux feeds it the partial product so far. The sum goes back into the Shift and Add register, which shifts right. After 16 rounds you have one finished product.

Then add_hi flips both muxes, and the adder folds the product's top half into the running total. That finishes one tap. The FSM bumps tap_idx and repeats until the last tap is done.

When all taps are finished, the total is shifted down to the right size and clipped if it's too big. The output mux then sends it out, or passes the raw input straight through if the filter is set to zero taps.

<img width="1424" height="1144" alt="image" src="https://github.com/user-attachments/assets/66acd456-df47-4d03-825e-a49a20351efc" />





<img width="904" height="129" alt="image" src="https://github.com/user-attachments/assets/b3fc4099-5d4b-4f21-9ad0-32afb65e48ae" />


in this waveform we can see the engine working through one sample with a 3-tap filter, and the signals line up with the flow in the block diagram. At the start the engine is idle (state = 0, dsp_busy low), and out_data is still showing the previous result, 0x1400. 

Once a new sample is accepted, state jumps to 1 (Load), dsp_busy goes high, tap_idx resets to 0, and fir_acc clears to 0 on the same clock edge. From there the FSM repeats the same Load, Mult, Add pattern (state 1, 2, 3) once per tap, and we can see tap_idx count up 0, 1, 2 as each tap finishes. The accumulator reflects that work: fir_acc changes once per tap as each product gets added to the running total. 

After the first tap it's 0x7FC000000 (a negative value), after the second tap it's back to 0, and after the third it settles at 0x002000000, which is the final filter sum. Then state goes to 4 (Scale) for a cycle and back to 0, and that's when out_valid pulses and out_data updates from 0x1400 to 0x0400. That final value is just the sum shifted right by 15 (2²⁵ / 2¹⁵ = 1024), which brings the result back down to the input's scale. 

dsp_busy stays high the whole time and drops when the engine returns to idle, so we can see the full Load, Mult, Add, Scale flow from the diagram happening in real time.

## Audio Output

## 2D Overview

<img width="557" height="521" alt="image" src="https://github.com/user-attachments/assets/e90d41ef-db99-4bd4-bddb-03cc2859c0ca" />

