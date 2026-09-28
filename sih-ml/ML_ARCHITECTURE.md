# ML Architecture — sih-ml

Corridor disruption prediction (Chicken's Neck / Siliguri): per-road-segment-per-day
probability that rainfall-triggered landslide/flood disrupts a road, feeding
risk-aware routing.

## Pipeline overview

```
data2/training_data (raw, read-only)
        │
        ▼
┌─────────────────────────────────────────────────────────────────┐
│ Stage 2  Data pipeline                                          │
│   labels  (4-tier: gold/silver/bronze/negative, case-control)   │
│   panel   (1 row / segment-day, 49 features, rain lagged 1d,    │
│            history lagged 30d)                                  │
│   folds   (spatial-block CV + 5km buffer, LOECO, temporal OOT,  │
│            locked final_test)                                   │
└─────────────────────────────────────────────────────────────────┘
        │  data/processed/{labels_v1,panel_v1,folds_v1}.parquet
        ▼
┌─────────────────────────────────────────────────────────────────┐
│ Stage 3  Baseline model                                         │
│   LightGBM GBDT vs logistic-regression floor vs 5 rule baselines│
└─────────────────────────────────────────────────────────────────┘
        │  models/baseline_v1/
        ▼
┌─────────────────────────────────────────────────────────────────┐
│ Stage 4  Training from scratch                                  │
│   MLflow tracking, crash-resume, determinism, early stopping    │
│   on PR-AUC                                                     │
└─────────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────────┐
│ Stage 5  Evaluation & error analysis                             │
│   never opens locked test; diagnoses ES leakage, slope-quartile │
│   lift                                                           │
└─────────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────────┐
│ Stage 6  Fine-tuning & HPO                                      │
│   event-grouped early stopping fix, Optuna TPE search,          │
│   selection folds {0,1,2} → report folds {3,4}                  │
└─────────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────────┐
│ Stage 7  Accuracy optimization                                  │
│   ~25 arms (data/augmentation/loss/ensemble/calibration),       │
│   paired per-fold deltas + permutation test, config frozen       │
│   → final_test opened once under pre-registration                │
└─────────────────────────────────────────────────────────────────┘
        │  reports/stage7/FINAL_TEST_REPORT.md
        ▼
┌─────────────────────────────────────────────────────────────────┐
│ Stage 8  Final model validation                                 │
│   reproduces frozen config bit-identically; robustness,          │
│   generalization, readiness gates (8/11 pass)                   │
└─────────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────────┐
│ Stage 9  Remediation                                             │
│   fixes locked-split leak (SEG291652), scopes to rain-           │
│   attributable labels, fixes monotonicity → final_v2             │
└─────────────────────────────────────────────────────────────────┘
        │
        ▼
┌─────────────────────────────────────────────────────────────────┐
│ Stage 10  Continuous improvement loop                            │
│   A/A noise floor, one-variable experiments under correctness/   │
│   superiority/simplification rules → final_v3                    │
└─────────────────────────────────────────────────────────────────┘
        │  models/registry.json (current champion)
        ▼
┌─────────────────────────────────────────────────────────────────┐
│ Stage 11  Deployment                                             │
│   daily batch (309k segments, ~1s) + read API on one CPU VM      │
└─────────────────────────────────────────────────────────────────┘
```

## Model

- **Algorithm**: LightGBM GBDT (gradient-boosted decision trees), calibrated,
  compared against a logistic-regression floor and 5 non-learned rules.
- **Grain**: one row per road segment per day, 49 features (rainfall, hydrology,
  terrain/slope, segment static attributes).
- **Target**: rainfall-triggered landslide/flood road disruption (binary,
  weighted by tier-confidence).
- **Headline metric**: ranking quality (precision@k / average precision) on
  spatially-held-out data — not AUC, given only ~115 independent positive
  event clusters.

## Validation design

- **Spatial-block CV** (primary) — 5 km buffer, events pinned to one block so
  they never straddle a split.
- **LOECO** (leave-one-event-cluster-out) and **temporal out-of-time** as
  secondary views.
- **Locked `final_test`** — held out since Stage 2, opened exactly once
  (Stage 7) under pre-registration; `scripts/open_final_test.py` is the only
  code allowed to read it.
- **Leakage firewall**: rainfall lagged 1 day, history lagged 30 days, all
  scaling/encoding fit inside the CV loop, early-stopping split grouped by
  event (not segment) to prevent train/ES overlap.

## Serving

- Daily batch scoring of the full corridor (309,042 segments, ~1s) via a
  numpy feature-store path with bit-identical outputs to the training
  pipeline.
- Read API served with gunicorn on a single CPU VM.
- Inference-side optimizations (tree truncation, Treelite, ONNX, FP16/INT8,
  distillation) were each measured and rejected — none improved cost/accuracy
  enough to justify the added risk on 709 KB / ~1s baseline.

## Current status

8 of 11 deployment gates pass. Not cleared for autonomous deployment;
suitable for a decision-support pilot (ranking-based alerts on the top 1–2%,
human in the loop) — see `FINAL_MODEL.md` and `DEPLOYMENT.md` for the full
rationale and remediation history.

See per-stage docs (`DATA_DECISIONS.md`, `TRAINING_STRATEGY.md`,
`FINETUNING_HPO_STRATEGY.md`, `ACCURACY_OPTIMIZATION.md`, `FINAL_MODEL.md`,
`REMEDIATION.md`, `CONTINUOUS_IMPROVEMENT.md`, `DEPLOYMENT.md`) for full
methodology and measured results.
