# ==============================================================================
# adaptive_timing_search.tcl  --  Vivado Maximum Frequency Finder  v5.0
# ==============================================================================
#
# PURPOSE
#   Finds the true Fmax of your RTL design by running a two-phase search:
#
#   PHASE 1  COARSE   Gradient descent from a slow clock.
#                     Fast, RERUN_SYNTH off. Finds the approximate range.
#
#   PHASE 2  FINE     Binary search within the coarse bracket.
#                     Precise to 0.025 ns. RERUN_SYNTH off for speed.
#
#   VALIDATE          Reruns the best period across multiple P&R seeds.
#                     RERUN_SYNTH on. This is the number for your paper.
#
#   The phases hand off automatically (full pipeline).
#   Checkpoint is saved after every iteration -- crash-safe.
#
# USAGE
#   Console -- full pipeline (recommended for first run):
#     source adaptive_timing_search.tcl
#
#   Console -- fine only, with known start point:
#     set SWEEP_MODE fine
#     set FINE_PERIOD_START 5.200
#     source adaptive_timing_search.tcl
#
#   Console -- coarse only:
#     set SWEEP_MODE coarse
#     source adaptive_timing_search.tcl
#
#   Batch -- full pipeline:
#     vivado -mode batch -source adaptive_timing_search.tcl \
#            -tclargs C:/path/to/project.xpr
#
#   Batch -- fine only from a known start:
#     vivado -mode batch -source adaptive_timing_search.tcl \
#            -tclargs C:/path/to/project.xpr -fine 5.200
#
#   Resume after crash (checkpoint auto-detected):
#     source adaptive_timing_search.tcl
#
# PREREQUISITES
#   Your base XDC must contain a direct create_clock line, e.g.:
#     create_clock -name clk_172m -period 5.8 [get_ports clk_i]
#   The clock name is auto-detected -- you do NOT set it here.
#   The original create_clock can stay in your XDC; the script
#   overrides it via PROCESSING_ORDER LATE on the generated XDC.
# ==============================================================================


# ==============================================================================
# USER SETTINGS  <-  only edit this section
# ==============================================================================

# Top-level clock input port name (must match your XDC get_ports line).
set CFG_CLK_PORT  "clk_i"

# Vivado run names.
set CFG_SYNTH_RUN "synth_1"
set CFG_IMPL_RUN  "impl_1"

# Parallel jobs -- set to your physical core count.
set CFG_JOBS 8

# Search bounds (ns).
#   PERIOD_MIN: fastest you'd ever expect (Artix-7 practical limit ~3 ns).
#   PERIOD_MAX: absolute slowest bound -- used as the clamp ceiling.
#   COARSE_PERIOD_START: where coarse phase actually begins.
#     Set this if you already have a rough idea of the range.
#     E.g. if you know the design runs around 150-200 MHz, set 8.000.
#     Default (empty string) = start from PERIOD_MAX (safest, slowest).
set CFG_PERIOD_MIN           2.000
set CFG_PERIOD_MAX           12.000
set CFG_COARSE_PERIOD_START  ""     ;# ns, or "" to use PERIOD_MAX

# Validation directives.
# Vivado has NO placement seed (P&R is deterministic) -- running the same
# period N times gives bit-identical results. The legitimate way to test
# implementation diversity is different placer directives:
#   {Default}                              = single run, no diversity check
#   {Default Explore ExtraNetDelay_high}   = recommended for paper results
set CFG_VALIDATION_DIRECTIVES {Default Explore ExtraNetDelay_high}

# Stop the search if hold slack (WHS) goes negative.
# Usually leave as 0 -- hold violations are fixable separately.
set CFG_STOP_ON_NEGATIVE_WHS 0

# Output directory (relative to Vivado working directory).
set CFG_OUT_DIR [file normalize "./adaptive_timing_search_out"]

# ==============================================================================
# END OF USER SETTINGS
# ==============================================================================


# ==============================================================================
# PHASE PRESETS  --  tuned, no need to change for normal use
# ==============================================================================

# COARSE  --  pure Newton step, fast, synthesis not rerun
# Pure Newton: next = period - WNS  (direct jump to estimated critical path)
# No margin added -- the fine binary search handles precision afterwards.
# C_CONVERGE_WNS: if WNS lands in [0, C_CONVERGE_WNS] we are close enough,
#   stop coarse early and hand off to fine.
set C_CONVERGE_WNS 0.300   ;# ns -- coarse "close enough" tolerance
set C_MAX_ITER     6       ;# Newton converges in 2-3, 6 is generous
set C_MIN_STEP     0.050   ;# minimum step to prevent micro-oscillation
set C_RERUN_SYNTH  0

# FINE  --  binary search, synthesis not rerun (speed)
# Convergence is gap-based: stops when hi - lo < F_MIN_STEP.
# WNS magnitude at the boundary is whatever the router gives -- not controlled.
set F_MAX_ITER        14    ;# log2(10 ns / 0.025 ns) ~ 9; 14 for safety
set F_MIN_STEP        0.025 ;# resolution limit (ns)
set F_RERUN_SYNTH     0

# VALIDATION  --  fixed period, synthesis always rerun for clean result
set V_RERUN_SYNTH  1


# ==============================================================================
# MODE & ARGUMENT PARSING
# ==============================================================================

# SWEEP_MODE: "full" | "coarse" | "fine"
# Set before sourcing (console) or via -tclargs (batch).
if {![info exists SWEEP_MODE]}        { set SWEEP_MODE "full" }
if {![info exists FINE_PERIOD_START]} { set FINE_PERIOD_START "" }

set _proj_arg ""
if {[info exists argv] && [llength $argv] > 0} {
    set _i 0
    while {$_i < [llength $argv]} {
        set _a [lindex $argv $_i]
        switch -- $_a {
            -coarse { set SWEEP_MODE "coarse" }
            -fine   {
                set SWEEP_MODE "fine"
                set _nx [lindex $argv [expr {$_i + 1}]]
                if {[string is double -strict $_nx]} {
                    set FINE_PERIOD_START $_nx
                    incr _i
                }
            }
            -full   { set SWEEP_MODE "full" }
            default {
                if {![string match "-*" $_a] && $_proj_arg eq ""} {
                    set _proj_arg $_a
                }
            }
        }
        incr _i
    }
    unset -nocomplain _i _a _nx
}


# ==============================================================================
# HELPER PROCEDURES
# ==============================================================================

proc ats_num {x} {
    if {$x eq "" || $x eq "NA"} { return 0 }
    return [string is double -strict $x]
}

proc ats_fmt {x} {
    if {![ats_num $x]} { return "NA" }
    return [format "%.3f" $x]
}

proc ats_clamp {x lo hi} {
    if {$x < $lo} { return $lo }
    if {$x > $hi} { return $hi }
    return $x
}

proc ats_abs {x} { expr {$x < 0 ? -($x) : $x} }

proc ats_median {lst} {
    if {[llength $lst] == 0} { return "NA" }
    set s [lsort -real $lst]
    set n [llength $s]
    set m [expr {$n / 2}]
    if {$n % 2} { return [lindex $s $m] }
    return [expr {([lindex $s [expr {$m - 1}]] + [lindex $s $m]) / 2.0}]
}

proc ats_csv_escape {s} {
    return "\"[string map {"\"" "\"\""} $s]\""
}

proc ats_write_file {path text} {
    set fp [open $path w]
    puts $fp $text
    close $fp
}

proc ats_count_cells {pat} {
    return [llength [get_cells -hierarchical -quiet -filter "REF_NAME =~ $pat"]]
}

proc ats_get_slack {delay_type} {
    set paths [get_timing_paths -quiet -delay_type $delay_type -max_paths 1]
    if {[llength $paths] == 0} { return "NA" }
    set s [get_property SLACK [lindex $paths 0]]
    if {$s eq "" || ![string is double -strict $s]} { return "NA" }
    return $s
}

proc ats_banner {msg} {
    set bar [string repeat "=" 62]
    puts ""
    puts $bar
    puts $msg
    puts $bar
}

# Auto-detect clock name from XDC files in the constraint set.
# Skips skip_file (the adaptive_clock.xdc itself).
proc ats_detect_clk_name {constrset clk_port skip_file} {
    # Normalize skip_file once for safe comparison later.
    set skip_norm [file normalize $skip_file]

    # Escape any regex-special characters in clk_port before embedding it
    # in a pattern -- e.g. a port named clk_i[0] would break regexp otherwise.
    regsub -all {[\\^$.|?*+()\[\]{}]} $clk_port {\\&} clk_port_esc

    foreach f [get_files -quiet -of_objects $constrset] {
        # Only process XDC files.
        if {![string match -nocase "*.xdc" $f]} { continue }

        # Skip the adaptive XDC we generate ourselves.
        # Use string equal on normalized paths -- NOT string match,
        # which would treat $skip_file as a glob pattern and error on
        # any path containing [ or ].
        if {[string equal -nocase [file normalize $f] $skip_norm]} { continue }

        # Try to open the file; skip silently if it fails.
        if {[catch {set fp [open $f r]}]} { continue }
        set txt [read $fp]
        close $fp

        foreach line [split $txt "\n"] {
            # Skip comment lines.
            if {[regexp {^\s*#} $line]} { continue }

            # Line must reference our port AND be a create_clock.
            if {![string match "*create_clock*" $line]}   { continue }
            if {![string match "*get_ports*"    $line]}   { continue }
            if {![regexp "$clk_port_esc" $line]}          { continue }

            # Extract the -name argument.
            # Note: -- is required because the pattern starts with -,
            # otherwise Tcl's regexp tries to parse it as a flag.
            if {[regexp -- {-name\s+(\S+)} $line -> nm]} {
                puts "CLK_NAME auto-detected: \"$nm\"  (from [file tail $f])"
                return $nm
            }
        }
    }
    return ""
}

# Write the adaptive clock XDC for the given period.
proc ats_write_xdc {path port name period} {
    set half [expr {$period / 2.0}]
    set fp [open $path w]
    puts $fp "# adaptive_timing_search.tcl -- auto-generated, do not edit"
    puts $fp "# [ats_fmt $period] ns  /  [format %.3f [expr {1000.0/$period}]] MHz"
    puts $fp ""
    puts $fp "set _p \[get_ports -quiet {$port}\]"
    puts $fp "if {\[llength \$_p\] == 0} { error \"Port '$port' not found.\" }"
    puts $fp "foreach _c \[get_clocks -quiet -of_objects \$_p\] { delete_clocks \$_c }"
    puts $fp "foreach _c \[get_clocks -quiet {$name}\]          { delete_clocks \$_c }"
    puts $fp "create_clock -period $period -name {$name} \\"
    puts $fp "             -waveform {0.000 $half} \$_p"
    puts $fp "unset -nocomplain _p _c"
    close $fp
}

# Save checkpoint as a sourced TCL file.
# Usage: ats_save_ckpt $path key1 val1 key2 val2 ...
proc ats_save_ckpt {path args} {
    set fp [open $path w]
    puts $fp "# adaptive_timing_search checkpoint -- do not edit manually"
    foreach {k v} $args {
        puts $fp "set CKPT_${k} [list $v]"
    }
    close $fp
}

# Write one CSV row.
proc ats_csv_row {csv phase iter period wns whs lut ff b18 b36 dsp seed status decision} {
    set freq [expr {[ats_num $period] ? [format "%.3f" [expr {1000.0/$period}]] : "NA"}]
    set row [join [list \
        [ats_csv_escape $phase] \
        $iter \
        [ats_fmt $period] \
        $freq \
        [ats_fmt $wns] \
        [ats_fmt $whs] \
        $lut $ff $b18 $b36 $dsp $seed \
        [ats_csv_escape $status] \
        [ats_csv_escape $decision] \
    ] ","]
    if {[catch {
        set fp [open $csv a]
        puts $fp $row
        close $fp
    } err]} {
        puts "WARNING: Could not write to CSV (file locked?): $err"
        puts "  Row was: $row"
    }
}

# Run synthesis (optional) + implementation.
# Returns a dict-style list: {ok 0|1  status <string>}
proc ats_run_impl {synth_run impl_run jobs do_synth} {
    catch {update_compile_order -fileset sources_1}
    if {$do_synth} {
        puts "  Resetting synthesis..."
        reset_run $synth_run
        puts "  Launching synthesis..."
        launch_runs $synth_run -jobs $jobs
        wait_on_run $synth_run
        set ss [get_property STATUS [get_runs $synth_run]]
        puts "  Synthesis: $ss"
        if {[string first "ERROR" [string toupper $ss]] >= 0} {
            return [list ok 0 status $ss]
        }
    }
    puts "  Resetting implementation..."
    reset_run $impl_run
    puts "  Launching implementation (to route_design)..."
    launch_runs $impl_run -to_step route_design -jobs $jobs
    wait_on_run $impl_run
    set is [get_property STATUS [get_runs $impl_run]]
    puts "  Implementation: $is"
    return [list ok 1 status $is]
}

# Open the implemented run and collect timing + utilization.
# Returns a dict-style list with keys:
#   ok wns whs pass lut ff b18 b36 dsp status
proc ats_collect {impl_run out_dir tag} {
    catch {close_design}
    if {[catch {open_run $impl_run} err]} {
        puts "  ERROR: Cannot open run: $err"
        return [list ok 0 wns NA whs NA pass 0 \
                     lut 0 ff 0 b18 0 b36 0 dsp 0 status "open_run_failed"]
    }
    if {[llength [get_clocks -quiet *]] == 0} {
        puts "  WARNING: No clocks found after open_run."
        puts "           adaptive_clock.xdc may not be applied."
    }

    # Write reports.
    set t_rpt [file join $out_dir "timing_${tag}.rpt"]
    set u_rpt [file join $out_dir "util_${tag}.rpt"]
    set k_rpt [file join $out_dir "clocks_${tag}.rpt"]
    set c_rpt [file join $out_dir "check_timing_${tag}.rpt"]

    if {[catch {set txt [report_timing_summary -return_string]}]} {
        catch {report_timing_summary -file $t_rpt}
    } else {
        ats_write_file $t_rpt $txt
    }
    catch {report_utilization  -file $u_rpt}
    catch {report_clocks        -file $k_rpt}
    catch {check_timing -verbose -file $c_rpt}

    set wns  [ats_get_slack max]
    set whs  [ats_get_slack min]
    set pass [expr {[ats_num $wns] && $wns >= 0.0}]
    set st   [get_property STATUS [get_runs $impl_run]]

    return [list ok 1 wns $wns whs $whs pass $pass \
                 lut [ats_count_cells LUT*]    ff  [ats_count_cells FD*] \
                 b18 [ats_count_cells RAMB18*] b36 [ats_count_cells RAMB36*] \
                 dsp [ats_count_cells DSP*]    status $st]
}

# Set placer directive on implementation run (Vivado's legitimate way to
# get implementation diversity -- there is NO placement seed in Vivado,
# P&R is deterministic given identical inputs).
proc ats_set_directive {impl_run directive} {
    if {[catch {
        set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE $directive [get_runs $impl_run]
    } err]} {
        puts "  WARNING: Could not set place directive '$directive': $err"
        return 0
    }
    return 1
}
proc ats_clear_directive {impl_run} {
    catch {
        set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE Default [get_runs $impl_run]
    }
}

# Safe freq string for banners.
proc ats_mhz {period} {
    if {![ats_num $period]} { return "NA MHz" }
    return "[format %.2f [expr {1000.0/$period}]] MHz"
}


# ==============================================================================
# MAIN SCRIPT
# ==============================================================================

file mkdir $CFG_OUT_DIR
ats_banner "Vivado Adaptive Timing Search  v5.0"

# --- Open project (batch mode) ---
if {$_proj_arg ne ""} {
    puts "Opening project: $_proj_arg"
    open_project $_proj_arg
}

# --- Project sanity check ---
if {[catch {current_project} _pe]} {
    error "No Vivado project is open.\
           \nConsole: open your .xpr first.\
           \nBatch:   -tclargs /path/to/project.xpr"
}

puts ""
puts "Project  : [get_property NAME [current_project]]"
puts "Part     : [get_property PART [current_project]]"
puts "Mode     : $SWEEP_MODE"
puts "CLK_PORT : $CFG_CLK_PORT"
puts "OUT_DIR  : $CFG_OUT_DIR"

# --- Resolve active constraint set ---
set _cs_name ""
catch {set _cs_name [get_property CONSTRSET [get_runs $CFG_IMPL_RUN]]}
if {$_cs_name eq "" || [llength [get_filesets -quiet $_cs_name]] == 0} {
    set _cs_name [get_property NAME [current_fileset -constrset]]
}
set _cs [get_filesets $_cs_name]
catch {set_property CONSTRSET $_cs_name [get_runs $CFG_SYNTH_RUN]}
catch {set_property CONSTRSET $_cs_name [get_runs $CFG_IMPL_RUN]}
puts "Constrset: $_cs_name"

# --- Adaptive XDC path ---
set XDC_FILE [file join $CFG_OUT_DIR "adaptive_clock.xdc"]

# --- Auto-detect clock name ---
set CLK_NAME [ats_detect_clk_name $_cs $CFG_CLK_PORT $XDC_FILE]
if {$CLK_NAME eq ""} {
    error "Cannot detect clock name for port '$CFG_CLK_PORT'.\
           \nYour XDC must contain:\
           \n  create_clock -name <name> -period <p> \[get_ports $CFG_CLK_PORT\]"
}

# --- Register adaptive XDC with constraint set ---
ats_write_xdc $XDC_FILE $CFG_CLK_PORT $CLK_NAME $CFG_PERIOD_MAX

if {[llength [get_files -quiet -of_objects $_cs $XDC_FILE]] == 0} {
    add_files -fileset $_cs -norecurse $XDC_FILE
}
set _xdc [get_files -of_objects $_cs $XDC_FILE]
set_property USED_IN_SYNTHESIS      true $_xdc
set_property USED_IN_IMPLEMENTATION true $_xdc
catch {set_property PROCESSING_ORDER LATE $_xdc}

puts ""
puts "Adaptive XDC : [file tail $XDC_FILE]  \[LATE\]"
puts "Constraint files in '$_cs_name':"
foreach _f [get_files -quiet -of_objects $_cs] {
    if {[string match -nocase "*.xdc" $_f]} {
        set _po ""
        catch {set _po [get_property PROCESSING_ORDER [get_files $_f]]}
        puts "  [file tail $_f]  \[$_po\]"
    }
}

# --- CSV init ---
set CSV [file join $CFG_OUT_DIR "adaptive_summary.csv"]

# --- Checkpoint state variables (defaults for fresh run) ---
set CKPT_coarse_done     0
set CKPT_best_coarse     "NA"
set CKPT_best_coarse_wns "NA"
set CKPT_fine_lo         $CFG_PERIOD_MIN
set CKPT_fine_hi         "NA"
set CKPT_best_fine       "NA"
set CKPT_lo_verified     0
set CKPT_val_done_seeds  {}
set CKPT_val_wns_list    {}
set CKPT_val_pass_list   {}
set CKPT_phase           "start"

set CKPT_FILE [file join $CFG_OUT_DIR "checkpoint.tcl"]
set _resumed 0

if {[file exists $CKPT_FILE]} {
    puts ""
    puts "Checkpoint found -- attempting resume..."
    if {![catch {source $CKPT_FILE}]} {
        # Checkpoint sets CKPT_* variables via the sourced file.
        puts "Resumed: phase=$CKPT_phase  best_coarse=[ats_fmt $CKPT_best_coarse]  best_fine=[ats_fmt $CKPT_best_fine]"
        set _resumed 1
    } else {
        puts "WARNING: Checkpoint unreadable -- starting fresh."
    }
}

if {!$_resumed} {
    # Fresh run: initialise CSV.
    set fp [open $CSV w]
    puts $fp "phase,iter,period_ns,freq_mhz,wns_ns,whs_ns,lut,ff,bram18,bram36,dsp,seed,status,decision"
    close $fp
}


# ==============================================================================
# PHASE 1  --  COARSE  (gradient descent)
# ==============================================================================

if {($SWEEP_MODE eq "full" || $SWEEP_MODE eq "coarse") && !$CKPT_coarse_done} {

    ats_banner "PHASE 1  --  COARSE  (gradient descent)"
    set _coarse_start [expr {$CFG_COARSE_PERIOD_START ne "" ? $CFG_COARSE_PERIOD_START : $CFG_PERIOD_MAX}]
    puts "Start     : [ats_fmt $_coarse_start] ns  ([ats_mhz $_coarse_start])"
    puts "Converge  : WNS in 0.000 ~ $C_CONVERGE_WNS ns"
    puts "Max iters : $C_MAX_ITER"

    set period    [expr {$CFG_COARSE_PERIOD_START ne "" ? $CFG_COARSE_PERIOD_START : $CFG_PERIOD_MAX}]
    set best_c     "NA"
    set best_c_wns "NA"

    for {set iter 1} {$iter <= $C_MAX_ITER} {incr iter} {

        puts ""
        puts "-- Coarse $iter/$C_MAX_ITER  |  [ats_fmt $period] ns  ([ats_mhz $period])"

        ats_write_xdc $XDC_FILE $CFG_CLK_PORT $CLK_NAME $period

        set rr [ats_run_impl $CFG_SYNTH_RUN $CFG_IMPL_RUN $CFG_JOBS $C_RERUN_SYNTH]
        if {![dict get $rr ok]} {
            puts "  Run error -- aborting coarse phase."
            break
        }

        set tag [format "coarse_i%02d_%s" $iter [regsub -all {[^0-9]} [ats_fmt $period] "_"]]
        set res [ats_collect $CFG_IMPL_RUN $CFG_OUT_DIR $tag]
        set wns  [dict get $res wns]
        set whs  [dict get $res whs]
        set pass [dict get $res pass]
        set st   [dict get $res status]

        puts "  WNS=[ats_fmt $wns]  WHS=[ats_fmt $whs]  PASS=$pass"

        # Track best passing result and its WNS.
        if {$pass && ($best_c eq "NA" || $period < $best_c)} {
            set best_c     $period
            set best_c_wns $wns
        }

        # Abort if WNS is unmeasurable (constraint problem).
        if {![ats_num $wns]} {
            ats_csv_row $CSV coarse $iter $period $wns $whs \
                [dict get $res lut] [dict get $res ff] \
                [dict get $res b18] [dict get $res b36] [dict get $res dsp] \
                0 $st "STOP_WNS_NA"
            puts "  ERROR: WNS is NA -- check clock constraints and reports."
            break
        }

        if {$CFG_STOP_ON_NEGATIVE_WHS && [ats_num $whs] && $whs < 0} {
            ats_csv_row $CSV coarse $iter $period $wns $whs \
                [dict get $res lut] [dict get $res ff] \
                [dict get $res b18] [dict get $res b36] [dict get $res dsp] \
                0 $st "STOP_negative_WHS"
            puts "  Stopping: negative hold slack."
            break
        }

        # Check convergence: WNS small positive means we are close enough.
        # Fine binary search will find the exact boundary from here.
        if {$wns >= 0.0 && $wns <= $C_CONVERGE_WNS} {
            ats_csv_row $CSV coarse $iter $period $wns $whs \
                [dict get $res lut] [dict get $res ff] \
                [dict get $res b18] [dict get $res b36] [dict get $res dsp] \
                0 $st "COARSE_DONE"
            puts "  WNS in convergence range -- handing off to fine."
            break
        }

        # Pure Newton step: jump directly to estimated critical path.
        #   next = period - WNS
        #   No margin, no clamp -- a large WNS means a large jump is correct.
        #   MIN_STEP only to prevent micro-oscillation when already very close.
        set next_p [expr {$period - $wns}]
        set delta  [expr {$next_p - $period}]
        if {[ats_abs $delta] < $C_MIN_STEP} {
            set next_p [expr {$period + ($wns > 0 ? -$C_MIN_STEP : $C_MIN_STEP)}]
        }
        set next_p [ats_clamp $next_p $CFG_PERIOD_MIN $CFG_PERIOD_MAX]
        set dec    [expr {$wns > 0 ? "try_faster" : "try_slower"}]

        ats_csv_row $CSV coarse $iter $period $wns $whs \
            [dict get $res lut] [dict get $res ff] \
            [dict get $res b18] [dict get $res b36] [dict get $res dsp] \
            0 $st $dec

        puts "  -> $dec  next=[ats_fmt $next_p] ns  ([ats_mhz $next_p])"

        if {$next_p == $period} {
            puts "  Period unchanged -- stopping coarse."
            break
        }
        set period $next_p

        ats_save_ckpt $CKPT_FILE \
            coarse_done 0  best_coarse $best_c  best_coarse_wns $best_c_wns \
            fine_lo $CFG_PERIOD_MIN  fine_hi NA  best_fine NA \
            phase coarse
    }

    set CKPT_coarse_done   1
    set CKPT_best_coarse   $best_c
    set CKPT_best_coarse_wns $best_c_wns

    ats_save_ckpt $CKPT_FILE \
        coarse_done 1  best_coarse $CKPT_best_coarse \
        best_coarse_wns $CKPT_best_coarse_wns \
        fine_lo $CFG_PERIOD_MIN  fine_hi NA  best_fine NA \
        phase coarse_done

    puts ""
    puts "Coarse best: [ats_fmt $best_c] ns  ([ats_mhz $best_c])  WNS=[ats_fmt $best_c_wns] ns"
}


# ==============================================================================
# PHASE 2  --  FINE  (binary search)
# ==============================================================================

set best_f "NA"

if {$SWEEP_MODE eq "full" || $SWEEP_MODE eq "fine"} {

    # --- Determine the initial hi bound ---
    set fine_hi_start ""

    if {$FINE_PERIOD_START ne ""} {
        set fine_hi_start $FINE_PERIOD_START
        puts "\nFine start: FINE_PERIOD_START = $fine_hi_start ns (manual)"
    } elseif {$CKPT_best_coarse ne "NA"} {
        # Buffer above coarse result to guarantee a pass at hi.
        set fine_hi_start [expr {$CKPT_best_coarse + 0.500}]
        set fine_hi_start [ats_clamp $fine_hi_start $CFG_PERIOD_MIN $CFG_PERIOD_MAX]
        puts "\nFine start: coarse_best + 0.5 ns = [ats_fmt $fine_hi_start] ns"
    } else {
        error "Fine phase needs a starting period.\
               \nOption A: run full pipeline (SWEEP_MODE full).\
               \nOption B: set FINE_PERIOD_START 5.200 before sourcing."
    }

    ats_banner "PHASE 2  --  FINE  (binary search)"

    # lo_verified: 1 once any real FAIL has established the lower bound.
    # Restored from checkpoint on resume so a completed fine phase is not
    # re-extended and re-run.
    set lo_verified $CKPT_lo_verified

    # If fine already completed (resume into validation), skip the loop.
    set fine_already_done [expr {$_resumed && \
        ($CKPT_phase eq "fine_done" || $CKPT_phase eq "validate") && \
        $CKPT_best_fine ne "NA"}]

    # Restore fine bounds from checkpoint if resuming.
    if {$_resumed && $CKPT_fine_hi ne "NA"} {
        set fine_lo $CKPT_fine_lo
        set fine_hi $CKPT_fine_hi
        set best_f  $CKPT_best_fine
        puts "Resumed: lo=[ats_fmt $fine_lo]  hi=[ats_fmt $fine_hi]  best=[ats_fmt $best_f]"
        if {$fine_already_done} {
            puts "Fine phase already completed -- skipping straight to validation."
        }
    } else {
        set fine_hi $fine_hi_start

        # Compute fine_lo from coarse result if available.
        # Estimated critical path = best_coarse - best_coarse_wns.
        # Subtract a 0.5 ns safety buffer for P&R variability across periods.
        # This tightens the binary search bracket vs a fixed -4.0 ns offset,
        # saving ~1-2 iterations.
        if {$CKPT_best_coarse_wns ne "NA" && [ats_num $CKPT_best_coarse_wns]} {
            set _est_crit [expr {$CKPT_best_coarse - $CKPT_best_coarse_wns}]
            set fine_lo   [ats_clamp \
                [expr {$_est_crit - 0.500}] \
                $CFG_PERIOD_MIN \
                [expr {$fine_hi - $F_MIN_STEP}]]
            puts "fine_lo from coarse estimate: [ats_fmt $_est_crit] - 0.5 = [ats_fmt $fine_lo] ns"
        } else {
            set fine_lo [ats_clamp \
                [expr {$fine_hi_start - 4.000}] \
                $CFG_PERIOD_MIN \
                [expr {$fine_hi - $F_MIN_STEP}]]
            puts "fine_lo fallback (no coarse WNS): [ats_fmt $fine_lo] ns"
        }

        set best_f "NA"

        # Verify that fine_hi actually passes before binary search starts.
        puts "Verifying hi bound: [ats_fmt $fine_hi] ns  ([ats_mhz $fine_hi])"
        ats_write_xdc $XDC_FILE $CFG_CLK_PORT $CLK_NAME $fine_hi
        set rr [ats_run_impl $CFG_SYNTH_RUN $CFG_IMPL_RUN $CFG_JOBS $F_RERUN_SYNTH]

        if {[dict get $rr ok]} {
            set vtag [format "fine_hi_verify_%s" [regsub -all {[^0-9]} [ats_fmt $fine_hi] "_"]]
            set vres [ats_collect $CFG_IMPL_RUN $CFG_OUT_DIR $vtag]
            set vwns [dict get $vres wns]
            set vpass [dict get $vres pass]
            puts "  WNS=[ats_fmt $vwns]  PASS=$vpass"

            ats_csv_row $CSV fine_verify 0 $fine_hi $vwns [dict get $vres whs] \
                [dict get $vres lut] [dict get $vres ff] \
                [dict get $vres b18] [dict get $vres b36] [dict get $vres dsp] \
                0 [dict get $vres status] "verify_hi"

            if {$vpass} {
                set best_f $fine_hi
            } else {
                # Hi bound doesn't pass -- this is a REAL verified fail,
                # so the new lo is confirmed.
                puts "  WARNING: Hi bound fails."
                puts "  Try a larger FINE_PERIOD_START, e.g. [ats_fmt [expr {$fine_hi + 1.0}]] ns"
                set fine_lo $fine_hi
                set lo_verified 1
                set fine_hi [ats_clamp [expr {$fine_hi + 1.500}] $CFG_PERIOD_MIN $CFG_PERIOD_MAX]
                puts "  Expanded hi to [ats_fmt $fine_hi] ns -- continuing..."
            }
        }
    }

    puts ""
    puts "Bounds    : lo=[ats_fmt $fine_lo] ns  hi=[ats_fmt $fine_hi] ns"
    puts "Resolution: $F_MIN_STEP ns"
    puts "Max iters : $F_MAX_ITER"

    for {set iter 1} {$iter <= $F_MAX_ITER && !$fine_already_done} {incr iter} {

        set gap [expr {$fine_hi - $fine_lo}]

        # If gap is small but lo was never verified as a real fail,
        # extend lo downward and keep searching rather than stopping early.
        if {$gap < $F_MIN_STEP} {
            if {!$lo_verified} {
                # Extension floor of 0.250 ns: 4*gap alone is tiny when gap
                # has already converged (<0.1 ns), and intermediate passes
                # shrink it again -- without a floor, crossing a mis-bracketed
                # region of 0.5 ns could exhaust F_MAX_ITER.
                set _ext [expr {max(4.0 * $gap, 0.250)}]
                set new_lo [ats_clamp \
                    [expr {$fine_lo - $_ext}] \
                    $CFG_PERIOD_MIN \
                    [expr {$fine_lo - $F_MIN_STEP}]]
                if {$new_lo <= $CFG_PERIOD_MIN} {
                    puts "\nGap converged but lo never verified -- hit PERIOD_MIN floor."
                    puts "Reported Fmax may be conservative. Lower CFG_PERIOD_MIN to search faster."
                    break
                }
                puts "\nGap [ats_fmt $gap] ns < $F_MIN_STEP ns but lo never failed."
                puts "Extending lo to [ats_fmt $new_lo] ns to find true lower bound..."
                set fine_lo $new_lo
            } else {
                puts "\nGap [ats_fmt $gap] ns < $F_MIN_STEP ns -- converged."
                break
            }
        }

        set mid [expr {($fine_lo + $fine_hi) / 2.0}]
        set mid [ats_clamp $mid $CFG_PERIOD_MIN $CFG_PERIOD_MAX]

        puts ""
        puts "-- Fine $iter/$F_MAX_ITER  |  [ats_fmt $mid] ns  ([ats_mhz $mid])"
        puts "   lo=[ats_fmt $fine_lo]  ..  mid=[ats_fmt $mid]  ..  hi=[ats_fmt $fine_hi]   gap=[ats_fmt $gap] ns"

        ats_write_xdc $XDC_FILE $CFG_CLK_PORT $CLK_NAME $mid

        set rr [ats_run_impl $CFG_SYNTH_RUN $CFG_IMPL_RUN $CFG_JOBS $F_RERUN_SYNTH]
        if {![dict get $rr ok]} {
            puts "  Run error -- treating as fail, moving lo up."
            set fine_lo $mid
            set lo_verified 1
            continue
        }

        set tag [format "fine_i%02d_%s" $iter [regsub -all {[^0-9]} [ats_fmt $mid] "_"]]
        set res [ats_collect $CFG_IMPL_RUN $CFG_OUT_DIR $tag]
        set wns  [dict get $res wns]
        set whs  [dict get $res whs]
        set pass [dict get $res pass]
        set st   [dict get $res status]

        puts "  WNS=[ats_fmt $wns]  WHS=[ats_fmt $whs]  PASS=$pass"

        if {$CFG_STOP_ON_NEGATIVE_WHS && [ats_num $whs] && $whs < 0} {
            ats_csv_row $CSV fine $iter $mid $wns $whs \
                [dict get $res lut] [dict get $res ff] \
                [dict get $res b18] [dict get $res b36] [dict get $res dsp] \
                0 $st "STOP_negative_WHS"
            puts "  Stopping: negative hold slack."
            break
        }

        if {$pass} {
            set fine_hi $mid
            if {$best_f eq "NA" || $mid < $best_f} { set best_f $mid }
            set dec "PASS_try_faster"
        } else {
            set fine_lo $mid
            set lo_verified 1
            set dec "FAIL_try_slower"
        }

        puts "  -> $dec  \[new lo=[ats_fmt $fine_lo]  hi=[ats_fmt $fine_hi]\]"

        ats_csv_row $CSV fine $iter $mid $wns $whs \
            [dict get $res lut] [dict get $res ff] \
            [dict get $res b18] [dict get $res b36] [dict get $res dsp] \
            0 $st $dec

        ats_save_ckpt $CKPT_FILE \
            coarse_done $CKPT_coarse_done  best_coarse $CKPT_best_coarse \
            best_coarse_wns $CKPT_best_coarse_wns \
            fine_lo $fine_lo  fine_hi $fine_hi  best_fine $best_f \
            lo_verified $lo_verified \
            phase fine
    }

    set CKPT_best_fine $best_f
    ats_save_ckpt $CKPT_FILE \
        coarse_done $CKPT_coarse_done  best_coarse $CKPT_best_coarse \
        best_coarse_wns $CKPT_best_coarse_wns \
        fine_lo $fine_lo  fine_hi $fine_hi  best_fine $best_f \
        lo_verified $lo_verified \
        phase fine_done

    puts ""
    ats_banner "Fine result: [ats_fmt $best_f] ns  ([ats_mhz $best_f])"


    # ============================================================================
    # VALIDATION  --  multi-seed at best period
    # ============================================================================

    if {$best_f ne "NA" && [llength $CFG_VALIDATION_DIRECTIVES] > 0} {

        ats_banner "VALIDATION  --  [ats_fmt $best_f] ns  ([ats_mhz $best_f])  x[llength $CFG_VALIDATION_DIRECTIVES] directives"
        puts "Directives: $CFG_VALIDATION_DIRECTIVES"
        puts "RERUN_SYNTH: $V_RERUN_SYNTH"

        # Restore accumulated results from checkpoint (resume case).
        set val_wns  $CKPT_val_wns_list
        set val_pass $CKPT_val_pass_list

        if {[llength $CKPT_val_done_seeds] > 0} {
            puts "Resuming validation -- already done: $CKPT_val_done_seeds"
        }

        set _dir_idx 0
        foreach directive $CFG_VALIDATION_DIRECTIVES {
            incr _dir_idx

            # Skip directives already completed in a previous run.
            if {[lsearch -exact $CKPT_val_done_seeds $directive] >= 0} {
                puts ""
                puts "-- Directive '$directive'  (already done, skipping)"
                continue
            }

            puts ""
            puts "-- Directive '$directive'"
            ats_set_directive $CFG_IMPL_RUN $directive
            ats_write_xdc $XDC_FILE $CFG_CLK_PORT $CLK_NAME $best_f

            set rr [ats_run_impl $CFG_SYNTH_RUN $CFG_IMPL_RUN $CFG_JOBS $V_RERUN_SYNTH]
            if {![dict get $rr ok]} {
                puts "  Run error on directive '$directive' -- skipping."
                continue
            }

            set tag [format "val_d%02d_%s" $_dir_idx [regsub -all {[^0-9]} [ats_fmt $best_f] "_"]]
            set res [ats_collect $CFG_IMPL_RUN $CFG_OUT_DIR $tag]
            set wns  [dict get $res wns]
            set pass [dict get $res pass]
            set st   [dict get $res status]

            puts "  WNS=[ats_fmt $wns]  PASS=$pass"

            ats_csv_row $CSV validate $_dir_idx $best_f $wns [dict get $res whs] \
                [dict get $res lut] [dict get $res ff] \
                [dict get $res b18] [dict get $res b36] [dict get $res dsp] \
                $directive $st [expr {$pass ? "PASS" : "FAIL"}]

            if {[ats_num $wns]} {
                lappend val_wns  $wns
                lappend val_pass $pass
            }

            # Save after each directive so a crash here doesn't lose progress.
            lappend CKPT_val_done_seeds $directive
            set _vlo [expr {[info exists fine_lo] ? $fine_lo : $CKPT_fine_lo}]
            set _vhi [expr {[info exists fine_hi] ? $fine_hi : $CKPT_fine_hi}]
            ats_save_ckpt $CKPT_FILE \
                coarse_done $CKPT_coarse_done \
                best_coarse $CKPT_best_coarse \
                best_coarse_wns $CKPT_best_coarse_wns \
                fine_lo $_vlo  fine_hi $_vhi \
                best_fine $best_f \
                lo_verified 1 \
                val_done_seeds $CKPT_val_done_seeds \
                val_wns_list  $val_wns \
                val_pass_list $val_pass \
                phase validate
        }

        ats_clear_directive $CFG_IMPL_RUN

        if {[llength $val_wns] > 0} {
            set v_min    [lindex [lsort -real $val_wns] 0]
            set v_max    [lindex [lsort -real $val_wns] end]
            set v_med    [ats_median $val_wns]
            set v_passes [llength [lsearch -all $val_pass 1]]
            set v_total  [llength $val_pass]

            puts ""
            puts "Validation WNS: min=[ats_fmt $v_min]  median=[ats_fmt $v_med]  max=[ats_fmt $v_max]"
            puts "Pass rate     : $v_passes / $v_total  directives"

            if {$v_min < 0.0} {
                puts ""
                puts "NOTE: At least one directive failed timing. The Fmax holds only for"
                puts "      specific placer directives. For a conservative claim, report the"
                puts "      result with the directive that passed, or rerun fine with a"
                puts "      slightly higher FINE_PERIOD_START."
            }
        }
    }
}


# ==============================================================================
# FINAL SUMMARY
# ==============================================================================

ats_banner "FINAL SUMMARY"
puts "CSV     : $CSV"
puts "Reports : $CFG_OUT_DIR"
puts ""

set _report_period "NA"
set _report_src    ""

if {[info exists best_f] && $best_f ne "NA"} {
    set _report_period $best_f
    set _report_src    "fine phase + validation"
} elseif {$CKPT_best_coarse ne "NA"} {
    set _report_period $CKPT_best_coarse
    set _report_src    "coarse phase only (run fine for precision)"
}

if {$_report_period ne "NA"} {
    puts "  Fmax  :  [ats_fmt $_report_period] ns  /  [ats_mhz $_report_period]"
    puts "  Source:  $_report_src"
    if {[info exists v_min]} {
        puts "  Validation WNS range: [ats_fmt $v_min] ~ [ats_fmt $v_max] ns  (median [ats_fmt $v_med] ns)"
    }
    # Clean up the checkpoint only when the fine phase completed -- after a
    # coarse-only run the checkpoint carries the coarse result into the next
    # fine run and must be kept.
    if {[info exists best_f] && $best_f ne "NA"} {
        if {[file exists $CKPT_FILE]} {
            catch {file delete $CKPT_FILE}
            puts "  Checkpoint cleared -- next run starts fresh."
        }
    } else {
        puts "  Checkpoint kept (coarse result) for the next fine run: $CKPT_FILE"
    }
} else {
    puts "  No passing result found."
    puts "  Check: $CFG_OUT_DIR/clocks_*.rpt and check_timing_*.rpt"
    puts "  Checkpoint kept for resume: $CKPT_FILE"
}

puts ""
puts "Done."
