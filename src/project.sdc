# Source-synchronous host input timing for tt_um_audio_dsp_engine.
# LibreLane/OpenROAD SDC. Copy this file to src/project.sdc and keep
# PNR_SDC_FILE and SIGNOFF_SDC_FILE pointing to dir::project.sdc.
# Assumes CLOCK_PERIOD=50 ns (20 MHz), 50% duty cycle.
#
# EDIT THIS ONE VALUE for separate analysis runs: 0, 1, 2, 4 or 8 ns.
# Use 0 for nominal synthesis/P&R. Reuse the SAME routed netlist and SPEF
# for post-route STA runs with 0, 1, 2, 4 and 8. Do not source five versions
# into one timing session without resetting the constraints.
set host_variation_ns 0.0
#
# DATA min/max at 20 MHz:
#   nominal: 12.5 / 12.5 ns
#   +/-1:    11.5 / 13.5 ns
#   +/-2:    10.5 / 14.5 ns
#   +/-4:     8.5 / 16.5 ns
#   +/-8:     4.5 / 20.5 ns
#
# The variation is an aggregate DATA-to-clock arrival bound at the PROJECT
# PORTS. It includes host scheduling/output variation, bit-to-bit skew,
# board routing and external chip-shell DATA minus CLOCK delay. It is
# not a measured RP2350 guarantee. Internal routed clock/data paths are
# analyzed by STA; do not add their modeled skew to this bound again.
# A range models earliest/latest arrival, not random waveform simulation.
#
# Nominal means zero EXTRA input-arrival spread; finite slew, PVT/RC
# corners, flow derating and CLOCK_UNCERTAINTY_CONSTRAINT stay enabled.
# Do not also add the same +/- range to clock uncertainty.
# This is NOT a complete external timing contract: output/READY timing
# and reset keep the previous provisional baseline. No false paths,
# asynchronous clock groups or multicycle exceptions are introduced.

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

# Non-DTR ports retain the previous provisional baseline.
set generic_io_delay_ns [expr {
    $clock_period_ns * $::env(IO_DELAY_CONSTRAINT) / 100.0
}]
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

# First preserve baseline timing for reset, enable and reserved inputs.
# Then replace the DATA and VALID input delays with the host schedule.
set auxiliary_inputs [list]
set link_ports [get_ports {ui_in[*]}]
set valid_port [get_ports {uio_in[0]}]
if {[llength $link_ports] != 8 || [llength $valid_port] != 1} {
    error {Expected ui_in[7:0] DATA and uio_in[0] VALID ports}
}
foreach port $data_inputs {
    if {$port ni $link_ports && $port ni $valid_port} {
        lappend auxiliary_inputs $port
    }
}
if {[llength $auxiliary_inputs] > 0} {
    set_input_delay -clock $project_clock -min $generic_io_delay_ns $auxiliary_inputs
    set_input_delay -clock $project_clock -max $generic_io_delay_ns \
        -add_delay $auxiliary_inputs
}

# Centered DATA changes at T/4 after BOTH reference clock edges.
# 20 MHz: nominal changes at 12.5 and 37.5 ns; captures at 25 and 50 ns.
# -clock_fall denotes the reference CLOCK edge, not data polarity.
# Omitting -rise/-fall constrains both data transition polarities.
set data_phase_ns [expr {$clock_period_ns / 4.0}]
if {$host_variation_ns < 0 || $host_variation_ns >= $data_phase_ns} {
    error "host_variation_ns must be nonnegative and less than CLOCK_PERIOD/4"
}
set data_min_ns [expr {$data_phase_ns - $host_variation_ns}]
set data_max_ns [expr {$data_phase_ns + $host_variation_ns}]
set_input_delay -clock $project_clock -min $data_min_ns $link_ports
set_input_delay -clock $project_clock -max $data_max_ns -add_delay $link_ports
set_input_delay -clock $project_clock -clock_fall -min $data_min_ns \
    -add_delay $link_ports
set_input_delay -clock $project_clock -clock_fall -max $data_max_ns \
    -add_delay $link_ports

# VALID is SDR: update alongside the upper byte at 3T/4, before the
# following rising-edge acceptance. It is not a second DDR data byte.
# 20 MHz: VALID changes at 37.5 +/- variation ns, accepted at 50 ns.
set valid_phase_ns [expr {3.0 * $clock_period_ns / 4.0}]
set_input_delay -clock $project_clock \
    -min [expr {$valid_phase_ns - $host_variation_ns}] $valid_port
set_input_delay -clock $project_clock \
    -max [expr {$valid_phase_ns + $host_variation_ns}] -add_delay $valid_port

# READY and all other outputs retain the old rising-edge baseline.
# This input sweep does NOT establish host READY sampling or board signoff.
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

puts "\[INFO\] Source-sync input scenario: period=$clock_period_ns ns, phase=$data_phase_ns ns, variation=+/-$host_variation_ns ns, DATA min=$data_min_ns ns max=$data_max_ns ns"
