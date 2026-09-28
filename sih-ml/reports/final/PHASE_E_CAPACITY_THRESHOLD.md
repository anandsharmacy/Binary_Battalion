# Phase E — capacity-vs-threshold lookup

Full numbers: [PHASE_E_CAPACITY_THRESHOLD.csv](PHASE_E_CAPACITY_THRESHOLD.csv), produced by
`python -m sih_ml.final.capacity` (`src/sih_ml/final/capacity.py`). See
`GATE_REMEDIATION_PLAN.md`'s Phase E section for why this exists instead of a single
re-derived precision bar.

**Two columns, two different populations, never blended:**
- `alerts_per_day_*` / `reviews_per_day_*` — the REAL, full 309,042-segment corridor,
  scored on 3 actual historical dates (dry / moderate-monsoon / heavy-monsoon, picked
  from the corridor's own real 7-day-rainfall 10th/50th/90th percentiles: 2009-03-08,
  2012-05-03, 2023-09-25). No case-control sampling anywhere in this path.
- `dev_precision` / `dev_recall` — `final_v2`'s dev out-of-fold scores, the same
  population every other gate in this project reads. **Curated-evaluation-population
  numbers, not real-world.** Dev base rate is 8.56%; the real corridor's estimated
  base rate (172 events / 18.4 years / 309,042 segments) is ~8.27×10⁻⁸ — about a
  million times lower. Neither `case_control_negative` nor `hard_negative_matched` is
  a random sample of the true negative population (both are deliberately stratified —
  `labels/build_labels.py::build_negatives`), so there is no cheap reweighting fix.
  Read `dev_precision` as "precision on this curated test, ranking candidate
  thresholds relative to each other" — not as "1 in 5 alerts will be real."

## The finding this table exists to surface

At `final_v2`'s own currently-shipping frozen threshold (0.0271):

| day | alerts/day (non-steep) | reviews/day (steep) | reviews as % of all 24,073 steep segments |
|---|---|---|---|
| dry (2009-03-08) | 0 | 1 | 0.004% |
| moderate monsoon (2012-05-03) | 278 | 3,747 | 15.6% |
| heavy monsoon (2023-09-25) | 18,048 | 18,091 | **75.2%** |

**A single fixed threshold cannot serve both ends of this range.** On a heavy monsoon
day, three-quarters of every steep segment in the corridor clears the bar
simultaneously — that is not a prioritized review queue, it is "review nearly
everything," which defeats the purpose of ranking at all. On a dry day the same
threshold alerts on almost nothing. This is not a modeling defect — rainfall genuinely
drives the score, which is gate G5's own requirement — but it does mean **daily
capacity cannot be satisfied by one number picked once.** Any real deployment needs
either a weather-conditioned threshold (tighten it automatically as forecast rainfall
rises) or an explicit "top-N of today's ranking" policy
(`serve/batch.py`'s `tier_rank` column already supports exactly this — pick N,
independent of the probability threshold — but nothing currently sets N from a real
capacity number).

## What to do once a real number exists

Given an agreed daily capacity `N`:
1. Read this table (or a finer re-run of `capacity.py` with a denser threshold grid)
   for the threshold whose **moderate-monsoon** alert count is closest to `N` — dry
   days will always under-alert and heavy days will always over-alert relative to any
   fixed threshold; moderate is the representative planning case.
2. Or skip the threshold entirely and set `tier_rank <= N` directly in
   `serve/batch.py`'s daily output, which sidesteps this whole problem — it always
   returns exactly `N` per tier per day, at whatever score cutoff that implies that
   day. This is very likely the better operational answer.
3. `dev_precision` at the chosen threshold gives a *relative* sense of how much
   ranking quality is being traded for volume — not an absolute real-world rate.

**G2's status is unchanged by this table.** `precision@100 >= 0.50`'s threshold still
carries its original provenance defect (calibrated against a leak-inflated 0.810); this
table does not re-derive it into a new pass/fail, only makes the tradeoff space
inspectable once a real capacity number or a real precision pilot exists.
