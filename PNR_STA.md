# P&R and STA

## Layout utilization

| Metric | Reported value |
| --- | ---: |
| Die area | Approximately 112,783 µm² |
| Core area | Approximately 107,931 µm² |
| Cell area excluding filler | Approximately 100,975 µm² |
| Utilization excluding filler | 93.55% |
| Area occupied by replaceable filler | 6,956.59 µm², approximately 6.45% of the core |
| Total cells including filler and physical support cells | 5,035 |
| Cells excluding filler | 3,572 |
| Cells counted in the usage-category summary | 2,688 |
| Filler cells | 1,463 |
| Tap cells | 705 |
| Endcap cells | 162 |
| Tie cells | 17 |

The 2,688-cell usage summary counts the logic and buffer categories shown in the viewer. Adding filler, tap, endcap and tie cells gives the complete physical instance count:

**2,688 + 1,463 filler + 705 tap + 162 endcap + 17 tie = 5,035 total cells.**


## Placement and routing optimization

OpenROAD automatically resized cells and inserted buffers during implementation.

| Stage | Instances resized | Buffers inserted |
| --- | ---: | ---: |
| Input-port buffering | — | 10 |
| Design repair after global placement | 61 | 237 |
| Design repair after global routing | 123 | 37 |


The final implementation contains 284 cells classified as timing-repair buffers, matching the 10 input buffers, 237 placement-repair buffers and 37 global-routing-repair buffers. It also contains 62 clock buffers and 19 cells classified as clock inverters.

## Timing assumptions and method

The 20 MHz clock has a 50 ns period and nominal 50% duty cycle. DTR captures an upper byte on the rising edge and a lower byte on the falling edge, giving a 25 ns capture interval.

The source-synchronous host model changes DATA halfway between captures, at 12.5 ns and 37.5 ns within each clock period. VALID updates at 37.5 ns and is sampled on the next rising edge.

| Timing parameter | Value |
| --- | ---: |
| Clock uncertainty | 0.25 ns |
| Ideal clock transition setting | 0.15 ns |
| Early timing derate | 0.95 |
| Late timing derate | 1.05 |


## PVT conditions

| Corner | Process characteristics | Temperature | Supply voltage |
| --- | --- | ---: | ---: |
| TT | Typical Typical | 25°C | 3.30 V |
| SS | Slow Slow | 125°C | 3.00 V |
| FF | Fast Fast | −40°C | 3.60 V |


## Post-route STA results

| Input variation | PVT | Worst setup ns | Worst hold ns | Result |
| --- | --- | ---: | ---: | --- |
| Nominal, ±0 ns | TT, 25°C, 3.30 V | +6.4486 | +0.7251 | PASS |
| Nominal, ±0 ns | SS, 125°C, 3.00 V | +0.3992 | +1.7652 | PASS |
| Nominal, ±0 ns | FF, −40°C, 3.60 V | +8.9769 | +0.2968 | PASS |
| ±1 ns | TT, 25°C, 3.30 V | +5.4486 | +0.7251 | PASS |
| ±1 ns | SS, 125°C, 3.00 V | -0.6008 | +1.7652 | Setup failure |
| ±1 ns | FF, −40°C, 3.60 V | +7.9769 | +0.2968 | PASS |
| ±2 ns | TT, 25°C, 3.30 V | +4.4486 | +0.7251 | PASS |
| ±2 ns | SS, 125°C, 3.00 V | -1.6008 | +1.7652 | Setup failure |
| ±2 ns | FF, −40°C, 3.60 V | +6.9769 | +0.2968 | PASS |
| ±4 ns | TT, 25°C, 3.30 V | +2.4486 | +0.7251 | PASS |
| ±4 ns | SS, 125°C, 3.00 V | -3.6008 | +1.7652 | Setup failure |
| ±4 ns | FF, −40°C, 3.60 V | +4.9769 | +0.2968 | PASS |
| ±8 ns | TT, 25°C, 3.30 V | -1.5514 | +0.7251 | Setup failure |
| ±8 ns | SS, 125°C, 3.00 V | -7.6008 | +1.7652 | Setup failure |
| ±8 ns | FF, −40°C, 3.60 V | +0.9769 | +0.2968 | PASS |

Hold passes throughout the sweep. The worst overall setup corner is `max_ss_125C_3v00`; the worst overall hold corner is `min_ff_n40C_3v60`.

### Nominal limiting paths

| Path | Worst slack |
| --- | ---: |
| VALID input -> parser occupancy counter | +0.3992 ns setup |
| DATA bit 3 -> lower-byte FIFO storage | +7.1612 ns setup |
| Internal control register -> FIR sample history | +5.2434 ns setup |
| First reset release register ->second reset release register | +0.2968 ns hold |


## Electrical and physical checks

| Check | Reported count | Worst value | Limit | Magnitude |
|---|---:|---:|---:|---|
| Capacitance | 19 | **0.3212 pF** | 0.2000 pF | **61% above limit** |
| Slew | 760 | **17.8148 ns** | 3.0000 ns | **5.94× the limit** |

Targeted buffer insertion/driver resize could be the potential fix, idk how to do it 
