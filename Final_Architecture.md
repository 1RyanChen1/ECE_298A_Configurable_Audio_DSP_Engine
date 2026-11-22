# Architecture Overview

Parser

Coefficient Bank

## FIR Engine

<img width="1200" height="482" alt="FIR Engine" src="https://github.com/user-attachments/assets/d9475376-fa7b-4c97-8441-750d6f01a1c0" />

A sample comes in and gets stored in the sample history, which keeps the last 8. Then the FSM works through the taps one at a time. For each tap, tap_idx picks one coefficient and one old sample, and they wait in Current Coefficient and Current Sample.

The multiply happens one bit at a time. The B mux feeds the adder the sample (only when the current coefficient bit is 1), and the A mux feeds it the partial product so far. The sum goes back into the Shift and Add register, which shifts right. After 16 rounds you have one finished product.

Then add_hi flips both muxes, and the adder folds the product's top half into the running total. That finishes one tap. The FSM bumps tap_idx and repeats until the last tap is done.

When all taps are finished, the total is shifted down to the right size and clipped if it's too big. The output mux then sends it out, or passes the raw input straight through if the filter is set to zero taps.

<img width="904" height="129" alt="image" src="https://github.com/user-attachments/assets/b3fc4099-5d4b-4f21-9ad0-32afb65e48ae" />

in this waveform we can see the engine working through one sample with a 3-tap filter, and the signals line up with the flow in our block diagram. At the start the engine is idle (state = 0, dsp_busy low), and out_data is still showing the previous result, 0x1400. Once a new sample is accepted, state jumps to 1 (Load), dsp_busy goes high, tap_idx resets to 0, and fir_acc clears to 0 on the same clock edge. From there the FSM repeats the same Load, Mult, Add pattern (state 1, 2, 3) once per tap, and we can see tap_idx count up 0, 1, 2 as each tap finishes. The accumulator reflects that work: fir_acc changes once per tap as each product gets added to the running total. After the first tap it's 0x7FC000000 (a negative value), after the second tap it's back to 0, and after the third it settles at 0x002000000, which is the final filter sum. Then state goes to 4 (Scale) for a cycle and back to 0, and that's when out_valid pulses and out_data updates from 0x1400 to 0x0400. That final value is just the sum shifted right by 15 (2²⁵ / 2¹⁵ = 1024), which brings the result back down to the input's scale. dsp_busy stays high the whole time and drops when the engine returns to idle, so we can see the full Load, Mult, Add, Scale flow from the diagram happening in real time.

# Audio Output

<img width="557" height="521" alt="image" src="https://github.com/user-attachments/assets/e90d41ef-db99-4bd4-bddb-03cc2859c0ca" />

