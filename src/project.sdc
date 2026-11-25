# Baseline constraints for tt_um_audio_dsp_engine.
# Mirrors the generic timing assumptions in the supplied LibreLane run.
# These are provisional macro-boundary assumptions, NOT measured RP2350/FPGA
# timings. See docs/timing_constraints.md before using this for board signoff.
# No reset exceptions or multicycle paths are introduced here.

if {![info exists ::env(CLOCK_PORT)] || $::env(CLOCK_PORT) ne "clk"} {
    error "project.sdc expects the single clock port clk"
}
set clock_period_ns $::env(CLOCK_PERIOD)
if {$clock_period_ns <= 0} {
    error "CLOCK_PERIOD must be positive"
}
set clock_input [get_ports clk]
create_clock -name clk -period $clock_period_ns \
    -waveform [list 0 [expr {$clock_period_ns / 2.0}]] $clock_input
set project_clock [get_clocks clk]

# Keep both earliest and latest I/O delays equal to the previous fallback
# value for a comparable baseline: 20% of 40 ns = 8 ns in the supplied run.
# In particular, the input MINIMUM of 8 ns is an unverified assumption.
# Replace these independently using host + board + TT mux timing budgets.
set generic_io_delay_ns [expr {
    $clock_period_ns * $::env(IO_DELAY_CONSTRAINT) / 100.0
}]
set input_delay_min_ns  $generic_io_delay_ns
set input_delay_max_ns  $generic_io_delay_ns
set output_delay_min_ns $generic_io_delay_ns
set output_delay_max_ns $generic_io_delay_ns

# Constrain every input except clk, including reset and reserved pins, just
# as the fallback did. Do not hide the reported reset path with a false path.
set data_inputs [list]
foreach port [all_inputs] {
    if {$port ni $clock_input} {
        lappend data_inputs $port
    }
}
set data_outputs [all_outputs]

# These references are to the RISING clock edge, matching the fallback.
# RTL falling-edge registers still receive half-cycle internal checks.
# External DTR arrivals relative to the FALLING edge require additional
# constraints based on the chosen host phase; they are not inferred here.
set_input_delay -clock $project_clock -min $input_delay_min_ns $data_inputs
set_input_delay -clock $project_clock -max $input_delay_max_ns \
    -add_delay $data_inputs
set_output_delay -clock $project_clock -min $output_delay_min_ns $data_outputs
set_output_delay -clock $project_clock -max $output_delay_max_ns \
    -add_delay $data_outputs

# Preserve the flow's electrical constraints, input-drive model, and load.
set_max_fanout $::env(MAX_FANOUT_CONSTRAINT) [current_design]
if {[info exists ::env(MAX_TRANSITION_CONSTRAINT)]} {
    set_max_transition $::env(MAX_TRANSITION_CONSTRAINT) [current_design]
}
if {[info exists ::env(MAX_CAPACITANCE_CONSTRAINT)]} {
    set_max_capacitance $::env(MAX_CAPACITANCE_CONSTRAINT) [current_design]
}

set data_driver [split $::env(SYNTH_DRIVING_CELL) "/"]
set_driving_cell -lib_cell [lindex $data_driver 0] \
    -pin [lindex $data_driver 1] $data_inputs
set clock_driver $data_driver
if {[info exists ::env(SYNTH_CLK_DRIVING_CELL)]} {
    set clock_driver [split $::env(SYNTH_CLK_DRIVING_CELL) "/"]
}
set_driving_cell -lib_cell [lindex $clock_driver 0] \
    -pin [lindex $clock_driver 1] $clock_input

# OUTPUT_CAP_LOAD is in fF in the flow; convert to the library's pF unit.
set_load [expr {$::env(OUTPUT_CAP_LOAD) / 1000.0}] $data_outputs
set_clock_uncertainty $::env(CLOCK_UNCERTAINTY_CONSTRAINT) $project_clock
set_clock_transition $::env(CLOCK_TRANSITION_CONSTRAINT) $project_clock
set_timing_derate -early [expr {
    1.0 - $::env(TIME_DERATING_CONSTRAINT) / 100.0
}]
set_timing_derate -late [expr {
    1.0 + $::env(TIME_DERATING_CONSTRAINT) / 100.0
}]

# Follow LibreLane's stage-specific ideal/propagated clock handling.
if {[info exists ::env(OPENLANE_SDC_IDEAL_CLOCKS)] &&
    $::env(OPENLANE_SDC_IDEAL_CLOCKS)} {
    unset_propagated_clock [all_clocks]
} else {
    set_propagated_clock [all_clocks]
}

puts "\[INFO\] Loaded project.sdc: provisional baseline, period=$clock_period_ns ns"
