# Adaptive Timing Search  —  Usage Guide
### `adaptive_timing_search.tcl`  v5.0

---

## What this does

Finds the true **maximum operating frequency (Fmax)** of your RTL design on Vivado, without guessing.

It runs three phases automatically:

| Phase | Method | RERUN_SYNTH | Purpose |
|-------|--------|-------------|---------|
| **Coarse** | Direct estimation (Newton step) | Off (fast) | Find the approximate frequency range in 2-3 iterations |
| **Fine** | Binary search | Off (fast) | Bracket the exact pass/fail boundary to +-0.025 ns |
| **Validate** | Fixed period x N placer directives | On (accurate) | Confirm the result is not a lucky route |

---

## Why not just use `Tc + WNS`?

`Tc + WNS` estimates the critical path **from one specific implementation**. But when you change the clock period, Vivado's place-and-route takes different paths, different routing resources, and potentially retimes logic differently. The actual achievable frequency can differ by 5–15% from the estimate.

The only correct approach is to **re-run implementation at each period** and read the true WNS. That is what this script does.

---

## Prerequisites

1. Vivado project (`.xpr`) with synthesis already run at least once.
2. Your base XDC must contain a direct `create_clock` line:
   ```xdc
   create_clock -name clk_172m -period 5.800000 [get_ports clk_i]
   ```
   The clock name (`clk_172m`) is **auto-detected** — you do not set it in the script.
3. The original `create_clock` can stay in your XDC (no need to comment it out).
   The script generates its own XDC with `PROCESSING_ORDER LATE`, which overrides it.

---

## Quick start

**Step 1 — Edit one line in the script:**
```tcl
set CFG_CLK_PORT  "clk_i"   ;# change to your clock port name
```

**Step 2 — Open your project in Vivado, then in the Tcl Console:**
```tcl
cd D:/path/to/script/folder
source adaptive_timing_search.tcl
```

**Step 3 — Wait.** The script prints progress for every iteration. Results go to
`./adaptive_timing_search_out/`.

---

## All usage modes

### Console — full pipeline (recommended)
```tcl
source adaptive_timing_search.tcl
```
Runs coarse → fine → validate automatically.

### Console — fine only (when you already know the approximate range)
```tcl
set SWEEP_MODE fine
set FINE_PERIOD_START 5.200   ;# start just above where you expect it to pass
source adaptive_timing_search.tcl
```

### Console — coarse only (quick exploration, no precision)
```tcl
set SWEEP_MODE coarse
source adaptive_timing_search.tcl
```

### Batch — full pipeline
```powershell
vivado -mode batch -source adaptive_timing_search.tcl `
       -tclargs C:/path/to/project.xpr
```

### Batch — fine only from a known start
```powershell
vivado -mode batch -source adaptive_timing_search.tcl `
       -tclargs C:/path/to/project.xpr -fine 5.200
```

### Resume after crash
Just run the same command again. The script detects
`adaptive_timing_search_out/checkpoint.tcl` and resumes from the last
completed iteration.

---

## Output files

All files go into `./adaptive_timing_search_out/` (configurable via `CFG_OUT_DIR`).

| File | Description |
|------|-------------|
| `adaptive_summary.csv` | One row per iteration — period, freq, WNS, WHS, utilization, decision |
| `adaptive_clock.xdc` | Auto-generated clock constraint (overwritten each iteration) |
| `checkpoint.tcl` | Resume state — auto-managed, do not edit |
| `timing_<tag>.rpt` | Full timing summary for each iteration |
| `util_<tag>.rpt` | Utilization report for each iteration |
| `clocks_<tag>.rpt` | Clock report — use this to verify the right clock was applied |
| `check_timing_<tag>.rpt` | Vivado's constraint coverage check |

---

## Understanding the CSV

```
phase, iter, period_ns, freq_mhz, wns_ns, whs_ns, lut, ff, bram18, bram36, dsp, seed, status, decision
```

Note: the `seed` column carries the placer **directive name** in validate rows
(historical column name kept for CSV compatibility).

```
```

| Column | Meaning |
|--------|---------|
| `phase` | `coarse`, `fine`, `fine_verify`, `fine_hi_verify`, `validate` |
| `wns_ns` | Worst Negative Slack — **positive = timing met**, negative = violation |
| `whs_ns` | Worst Hold Slack — should stay positive |
| `decision` | `PASS_try_faster`, `FAIL_try_slower`, `COARSE_DONE`, `PASS`, `FAIL` |
| `seed` | Placer directive used (0 outside validate; directive name in validate rows) |

The **fine phase** binary search narrows `lo` (fail) and `hi` (pass) until the gap is
less than `F_MIN_STEP` (0.025 ns). The last `hi` value is your Fmax.

---

## Interpreting the result

**Fmax from fine phase** (`best_f`):
- The tightest period at which Vivado's router achieves WNS >= 0.
- Boundary verified: the next step tighter fails.
- Represents a **single implementation** result -- validation confirms it holds across placer directives.

**Validation WNS range**:
- If `min WNS >= 0` across all directives: the result is robust. Report this frequency.
- If `min WNS < 0` on at least one directive: you are at the edge of routability.
  The true conservative Fmax is slightly slower -- try fine phase with
  `FINE_PERIOD_START` set to `best_f + 0.2`.

**For a paper**, report:
```
Fmax = 240.3 MHz  (period = 4.162 ns)
Timing met: WNS = +0.141 ns
Boundary verified: fails at 4.142 ns (WNS = -0.105 ns), resolution +-0.020 ns
Validated across 3 placer directives (Default, Explore, ExtraNetDelay_high)
```

---

## Why WNS at convergence is not near zero

A common expectation is that the final WNS should be close to 0.050 ns or smaller,
meaning the design is "right at the limit." Binary search does not guarantee this,
and it does not need to.

Binary search only asks **pass or fail** at each period -- it has no knowledge of
WNS magnitude. It narrows the gap between the last failing and last passing period
until the gap is below `F_MIN_STEP`. The WNS at the passing boundary is whatever
the router happens to give at that period.

Example from a real run:
```
fine 5:  4.162 ns  WNS = +0.141 ns  PASS  (hi = 4.162)
fine 6:  4.142 ns  WNS = -0.105 ns  FAIL  (lo = 4.142)
gap = 0.020 ns  <  F_MIN_STEP = 0.025 ns  --> stop
```

WNS = 0.141 ns does not mean there is untapped headroom. It means the router found
a solution at 4.162 ns with 0.141 ns to spare, and the very next testable point
(4.142 ns) fails hard. This is a routing cliff -- common in FPGAs where one routing
resource allocation change causes a large WNS jump. There is no period between
4.142 and 4.162 ns that gives WNS near zero; it simply does not exist for this
routing solution.

**What WNS near zero would mean:** in the old gradient-based approach, the algorithm
targeted a specific WNS value. This felt satisfying but told you less -- you knew
the design passed at that period but not how close you were to the true limit.
Binary search gives you stronger information: the exact boundary, to within
`F_MIN_STEP` resolution.

---

## Why F_MIN_STEP = 0.025 ns

This is a **frequency resolution** choice, not a WNS target. At typical Artix-7
frequencies:

```
At 200 MHz (5.000 ns):  0.025 / 5.000 = 0.5% resolution  --> +-1.0 MHz
At 240 MHz (4.162 ns):  0.025 / 4.162 = 0.6% resolution  --> +-1.4 MHz
At 300 MHz (3.333 ns):  0.025 / 3.333 = 0.75% resolution --> +-2.3 MHz
```

Sub-1% frequency resolution is well within P&R variability across directives (typically
2-5%), so refining further adds no useful information. The 0.025 ns value was
chosen to balance resolution against iteration count -- halving it to 0.0125 ns
would add one extra binary search iteration for no practical gain.

If you want tighter resolution for a specific reason, lower `F_MIN_STEP`:
```tcl
set F_MIN_STEP  0.010   ;# ~0.25% resolution, one extra iteration
```

---

## Parameter reference

| Variable | Default | Description |
|----------|---------|-------------|
| `CFG_CLK_PORT` | `"clk_i"` | **Must match your XDC** |
| `CFG_JOBS` | `8` | Parallel jobs -- set to physical core count |
| `CFG_PERIOD_MIN` | `2.000` | Fastest bound in ns (below this = not tested) |
| `CFG_PERIOD_MAX` | `12.000` | Slowest absolute ceiling in ns |
| `CFG_COARSE_PERIOD_START` | `""` | Where coarse phase begins. `""` = use `PERIOD_MAX`. Set this if you already have a rough idea of the frequency range (see tip below). |
| `CFG_VALIDATION_DIRECTIVES` | `{Default Explore ExtraNetDelay_high}` | Placer directives for validation; `{Default}` = single run |
| `CFG_STOP_ON_NEGATIVE_WHS` | `0` | `1` = abort if hold slack goes negative |
| `SWEEP_MODE` | `"full"` | `"full"` / `"coarse"` / `"fine"` |
| `FINE_PERIOD_START` | `""` | Required only for `SWEEP_MODE fine` |

### Tip: cutting coarse runtime with `CFG_COARSE_PERIOD_START`

By default coarse starts at `PERIOD_MAX` (12 ns = 83 MHz) and steps toward the
limit. If you already have a rough idea of where your design sits, starting
closer saves 2-4 iterations (~20-40 min).

```tcl
# You know from a previous run the design is around 170-200 MHz
set CFG_COARSE_PERIOD_START  6.000   ;# 167 MHz -- starts there instead of 83 MHz

# No idea at all -- leave empty, start safe
set CFG_COARSE_PERIOD_START  ""
```

> **Important:** `CFG_COARSE_PERIOD_START` should be a period you are reasonably
> confident **passes** (WNS >= 0). If you set it too aggressively and it fails,
> the Newton step will still recover -- but you lose the safety margin of starting
> from a guaranteed pass. When in doubt, pick 1-2 ns slower than your estimate.

---

## Runtime estimate

| Phase | Iterations | Per iteration | Total |
|-------|-----------|---------------|-------|
| Coarse (no synth) | 2-3 typical | ~5-10 min | ~10-30 min |
| Fine (no synth) | <= 14 | ~5-10 min | ~70-140 min |
| Validate (with synth, 3 directives) | 3 | ~20-30 min | ~60-90 min |
| **Full pipeline** | -- | -- | **~2-4 hours** |

> Artix-7 xc7a100t estimates for a design the size of HQC-192 (Karatsuba multiplier).
> Smaller designs will be faster.

### Why coarse is now 2-3 iterations

The coarse step is a pure Newton step -- no margin added:

```
next_period = current_period - WNS
```

`current_period - WNS` is the estimated critical path delay. Jumping directly
to it is the fastest possible move. For a design running at ~172 MHz starting
from 12 ns:

```
Iter 1: period=12.0 ns, WNS=6.2 ns  ->  next = 12.0 - 6.2 = 5.8 ns
Iter 2: period=5.8 ns,  WNS~0.0 ns  ->  converged, hand off to fine
```

The old design added a 0.2 ns buffer to the step (`period - WNS + 0.2`), which
caused one unnecessary extra iteration every time. It also previously clamped
the step to 1.5 ns max, which alone caused 5+ iterations for large WNS gaps.
Both are removed. The fine binary search handles all precision afterwards --
coarse only needs to get close.

---

## Why directives instead of seeds

Quartus and ISE have placement seeds -- run the same design N times with different
seeds and get N different results. **Vivado does not.** Vivado P&R is fully
deterministic: identical inputs always produce bit-identical outputs. There is no
`-seed` switch on `place_design`. Running the same period three times gives three
identical rows in the CSV -- zero information gained.

The legitimate Vivado mechanism for implementation diversity is the **placer
directive** (`place_design -directive <name>`). Each directive uses a genuinely
different placement strategy:

| Directive | Strategy |
|-----------|----------|
| `Default` | Balanced placement |
| `Explore` | Higher effort, multiple placement passes |
| `ExtraNetDelay_high` | Pessimistic net delay estimation, more conservative placement |

If the design meets timing at the same period under all three strategies, the Fmax
claim is robust -- it does not depend on one lucky placement. This is the standard
methodology for FPGA results in papers.

Other useful directives for wider sweeps: `ExtraPostPlacementOpt`,
`AltSpreadLogic_high`, `ExtraTimingOpt`.

---

## Troubleshooting

### `WNS is NA` — search stops immediately
- The adaptive XDC was not applied. Check `clocks_*.rpt`:
  - Is `clk_172m` (or your clock name) listed?
  - Is `adaptive_clock.xdc` in the constraint file list with `[LATE]`?
- Verify your CLK_PORT name matches the XDC exactly (case-sensitive).

### `Cannot detect clock name`
- Your XDC's `create_clock` line doesn't match the expected pattern.
- Required format: `create_clock -name <name> -period <p> [get_ports clk_i]`
- The `-name` argument must appear explicitly.

### `Hi bound fails` warning at start of fine phase
- Only occurs with a manual `FINE_PERIOD_START` (when hi comes from coarse it
  is already a verified pass and is not re-verified). Your guess was too fast:
  ```tcl
  set FINE_PERIOD_START 6.000   ;# try a slower starting point
  ```

### Negative WNS in validation but not in fine search
- You are at the edge of routability. The fine result was a lucky route.
- Set `FINE_PERIOD_START` to `best_f + 0.200` and re-run fine.

### `Checkpoint found` but wrong mode
- Delete `adaptive_timing_search_out/checkpoint.tcl` to force a fresh run.

---

## Design decisions

**Why binary search for fine, not gradient for both?**  
Gradient descent estimates the next period from `period - WNS`. This is correct on
average but P&R is non-deterministic — WNS can jump by ±0.1 ns between runs at the
same period. Binary search is immune to this: it only cares whether a point passes
or fails, not how much. It also guarantees convergence in `log2(range / resolution)`
steps regardless of noise.

**Why RERUN_SYNTH off for coarse and fine?**  
In the search phases, the goal is to map the pass/fail boundary efficiently. Synthesis
barely changes the critical path within a narrow frequency range — routing dominates.
Turning synthesis on would 3× the runtime with little gain in accuracy.

**Why RERUN_SYNTH on for validation?**  
The validation results are what you report. Each directive run should be a fully independent,
synthesis-aware implementation. This ensures the reported Fmax is not an artifact of
a particular synthesis run.
