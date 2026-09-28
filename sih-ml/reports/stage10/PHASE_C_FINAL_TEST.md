# Phase C — locked-split validation of `final_v6` vs `final_v2`

Opening #8 of `reports/stage7/TEST_SET_LEDGER.json`, under
`reports/stage10/PREREGISTRATION_V3.json`, run via `scripts/run_final_test_v3.py`
(`src/sih_ml/train/final_test_v3.py`). See `GATE_REMEDIATION_PLAN.md`'s Phase C section
for why this opening exists instead of the originally planned fresh holdout.

## Why two models, not one

The locked split changed shape between Stage 9 and now: the P0 rebuild that fixed
Phase A's target leak swapped block `BLK_006_008` out for `BLK_006_007`, raising the
split's base rate from Stage 9's 0.0966 (7,674 rows) to the current 0.150 (8,533 rows).
Gates keyed to base rate move with that change regardless of the model, so `final_v6`
was scored against `final_v2` — **retrained fresh on the current dev panel, in the same
run** — rather than against Stage 9's recorded numbers.

## Pre-registered rule

Candidate (`final_v6`) beats baseline (`final_v2`) on in-scope AP → promote. Otherwise →
baseline stays release champion, decided before the split was read.

## Result

**`final_v6` did not beat `final_v2`. `final_v2` remains the release champion.**

| population | n | model | AP | P@100 | recall | steep ROC |
|---|---|---|---|---|---|---|
| full in-scope | 8,353 | final_v2 | **0.3138** | 0.510 | 0.879 | 0.6252 |
| full in-scope | 8,353 | final_v6 | 0.3048 | 0.500 | 0.969 | 0.6085 |
| `BLK_006_007` only (never scored before) | 1,556 | final_v2 | **0.7169** | 0.890 | 0.923 | 0.6333 |
| `BLK_006_007` only (never scored before) | 1,556 | final_v6 | 0.6760 | 0.820 | 0.977 | 0.5937 |
| 4 shared v1/v2 blocks, in-scope | 6,977 | final_v2 | 0.1725 | 0.290 | 0.831 | 0.7575 |
| 4 shared v1/v2 blocks, in-scope | 6,977 | final_v6 | **0.2429** | 0.390 | 0.965 | 0.8123 |

Delta (candidate − baseline), full in-scope: **−0.0090 AP**. Not uniform: `final_v6`
loses on the full split and on the fresh block, but wins clearly on the four blocks it
shares with the v1/v2-era split — the dev gain partially transfers, direction depends
on which part of the corridor is being scored.

`BLK_006_007` is 58% positive (909/1,556) — read AP/ROC there, not precision@k.

41 of 8,533 test rows (0.48%, all negatives, dated after IMERG's 2025-09-30 record end)
carry NaN IMERG features for `final_v6`; LightGBM handles this natively.

## Deployment gates, same population, same run

| gate | final_v2 | final_v6 |
|---|---|---|
| beats chance (AP/base>2.0) | 2.38x ✓ | 2.31x ✓ |
| precision@100 ≥0.50 | 0.510 ✓ | 0.500 ✓ |
| recall ≥0.80 | 0.879 ✓ | 0.969 ✓ |
| steep ROC ≥0.70 | 0.625 ✗ | 0.608 ✗ |
| steep lift ≥2.0x | 1.61x ✗ | 1.51x ✗ |
| calibration transfer ≤1.5x | 1.93x ✗ | 1.78x ✗ |
| survives forecast error ≥80% | 96.2% ✓ | 98.3% ✓ |
| rainfall drives prediction ≥30% | 42.6% ✓ | **25.1% ✗** |
| batch window <300s | 1.15s ✓ | 0.36s ✓ |
| artifact <50MB | 0.67MB ✓ | 0.24MB ✓ |
| reproducible | bit-identical ✓ | bit-identical ✓ |
| monotonicity, 0 violations | ✓ | ✓ |
| **total** | **9/12** | **8/12** |

`final_v6` newly fails "rainfall is actually driving the prediction" — a model built
around IMERG relying *less* on rainfall by the zero-rainfall counterfactual than the
CHIRPS-only baseline does, on this population. Worth a closer look before any future
attempt to promote a rainfall-product change; not investigated further here.

## Calibration (predicted / observed, by slope stratum)

| slope | final_v2 | final_v6 |
|---|---|---|
| [0, 2.5) | 0.67x | 1.01x |
| [2.5, 10) | 0.52x | 0.56x |
| [10, 15) | 0.73x | 0.71x |
| [15, 20) | 0.68x | 0.69x |
| [20, 25) | 0.81x | 0.82x |
| [25, 30) | 1.25x | 1.31x |
| [30, 40) | 1.35x | 1.48x |

Both models under-predict on gentle slopes and over-predict on the steepest — `final_v6`
is uniformly a little further from 1.0x at the steep end, consistent with its worse
steep-terrain gates above.

## What this settles and what it doesn't

- **Settles**: `final_v6` is not release-ready as-is. `final_v2` stays deployed if a
  decision were forced today. Neither model clears steep ROC, steep lift, or
  calibration transfer on the current split — the same three gates that were failing
  before this opening still fail after it, under both models.
- **Does not settle**: whether IMERG *as a rainfall product* is worth carrying forward.
  The dev-side result (product beats resolution and sub-daily granularity, Phase A/B's
  real methodological finding) is unaffected by this — what failed to transfer is this
  *specific* recipe's composition, not necessarily the underlying data source.
- **Raises a new question**: the rainfall-driving-the-prediction gate regression is
  unexplained and not investigated here — flagged for whoever picks this back up.

## Reproduce

```
python scripts/run_final_test_v3.py
```

Refuses to run a second time meaningfully — the split is already open; a second
invocation appends another ledger entry and both scores are unaffected (both models are
deterministic given seed 42), but it should not be run again without a reason recorded
in `PREREGISTRATION_V3.json`'s successor, if one is ever needed.
