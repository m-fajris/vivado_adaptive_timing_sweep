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
| **Validate** | Fixed period x N seeds | On (accurate) | Confirm the result is not a lucky route |

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

| Column | Meaning |
|--------|---------|
| `phase` | `coarse`, `fine`, `fine_verify`, `fine_hi_verify`, `validate` |
| `wns_ns` | Worst Negative Slack — **positive = timing met**, negative = violation |
| `whs_ns` | Worst Hold Slack — should stay positive |
| `decision` | `PASS_try_faster`, `FAIL_try_slower`, `COARSE_DONE`, `PASS`, `FAIL` |
| `seed` | P&R seed used (0 = default seed, only matters in validate phase) |

The **fine phase** binary search narrows `lo` (fail) and `hi` (pass) until the gap is
less than `F_MIN_STEP` (0.025 ns). The last `hi` value is your Fmax.

---

## Interpreting the result

**Fmax from fine phase** (`best_f`):
- The tightest period at which Vivado's router achieves WNS ≥ 0.
- Precise to ±0.025 ns.
- Represents a **single seed** result.

**Validation WNS range**:
- If `min WNS ≥ 0` across all seeds: the result is robust. Report this frequency.
- If `min WNS < 0` on at least one seed: you are at the edge of routability.
  The true conservative Fmax is slightly slower — try fine phase with
  `FINE_PERIOD_START` set to `best_f + 0.2`.

**For a paper**, report:
```
Fmax = 1 / best_f  (or 1 / fine_hi at convergence)
Validated across N seeds, worst-case WNS = X ns
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
| `CFG_VALIDATION_SEEDS` | `{1 2 3}` | `{1}` = skip, `{1 2 3}` = 3-seed, `{1 2 3 4 5}` = 5-seed |
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
| Validate (with synth, 3 seeds) | 3 | ~20-30 min | ~60-90 min |
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
- The coarse result was optimistic. Increase the buffer:
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
The validation results are what you report. Each seed should be a fully independent,
synthesis-aware implementation. This ensures the reported Fmax is not an artifact of
a particular synthesis run.
