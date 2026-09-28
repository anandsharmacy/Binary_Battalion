# GATE REMEDIATION PLAN — clearing the 4 failing gates on `final_v2`

Target: the four deployment gates that `final_v2` (config `5aed65f3f8729060`) fails.
Companion to `CONTINUOUS_IMPROVEMENT.md` §7, which this plan **refines and reorders**
— it does not replace the roadmap, it makes P1–P4 executable and inserts one step
(Phase A) that the roadmap missed.

Status of record: `reports/stage9/deployment_gates.csv`. **8 of 12 pass.**

> **Read `FINAL_MODEL.md` §7 with care.** It says "8 of 11" and names three failing
> gates. That is `final_v1`, which Stage 9 found was leaked. The current failure set
> is different — `precision@100` now fails too. Work the table below, not that one.

---

## Work completed so far

| item | status |
|---|---|
| CHIRPS 0.05° availability confirmed upstream | **done** — native resolution, 0.25° is the coarsened variant |
| Tie-group numbers verified against the **real** CHIRPS cell table | **done** — 132 cells, 114 carry panel segments, steep median 152/cell |
| `nearest_cell_map` OOM at a fine grid | **fixed** — `src/sih_ml/utils/geo.py`, chunked over segments |
| Regression test for the chunking | **added** — `tests/test_geo.py` |
| `data2/` located and wired up | **done** — symlink `NER/data2 -> SIH/data/data2`; full suite 177 passed, 5 skipped |
| 0.05° acquisition without a 23.7 GB download | **solved** — `10b_chirps_p05.py`, IRIDL server-side subset, ~100 MB |
| P0 fabricated dry negatives, fixed at the source | **done** — temporal gate now bounded by the rainfall record |
| CHIRPS 0.05° corridor fetched | **done** — 24.85M rows, 3,240 cells, 2005-01-01..2025-12-31, `corridor_chirps_daily_p05.csv.gz`, 163.7 MB |
| COOLR endpoint dead, re-pointed and validated | **done** — see below |
| Panel rebuild at 0.05° + P0 | **done** — 102,581 rows, leakage gate clean, snapshotted first |
| **Phase A verdict: FAILS its pre-registered criterion** | **controlled A/B run** — steep ROC +0.0013, inside every floor; see below |
| Stage 10 campaigns on both panels | **done** — `final_v4` on 0.05°, champion kept |
| **Locked test set block membership shifted (1 of 5)** | **disclosed, not a bug** — `BLK_006_008 -> BLK_006_007`, mechanical consequence of P0; see below |
| Retrain champion on new panel, rebundle for serving | **next** — 4 tests correctly red until then |

### CHIRPS 0.05° fetch: complete and validated

24,850,800 rows, 60×54 = 3,240 cells at exactly 0.0500° step, full 2005–2025 record,
zero NaNs, precip range 0–329 mm/day (plausible). Corridor-mean daily rainfall
correlates **0.999996** with the existing 0.25° file over Jan 2005 — same underlying
signal at finer spatial detail, not a different product.

### The COOLR endpoint was dead, and a second "broken pull" turned out not to be

Two things were checked, one really was broken:

- **ReliefWeb: false alarm.** I tested `api.reliefweb.int/v1`, found it decommissioned
  (410), and reported it as broken. It isn't — `02_pull_apis.py::sec_reliefweb` never
  calls that host; it scrapes `reliefweb.int/updates/rss.xml`, confirmed live. No
  change made. (Moot for gates either way — `reliefweb_events` is out of scope per
  Stage 9 §B.)
- **COOLR: genuinely dead.** `maps.nccs.nasa.gov` no longer resolves in DNS. COOLR
  moved to an ArcGIS Enterprise portal at `gis.earthdata.nasa.gov`, found via its
  public search API. `COOLR_SERVICES` in `02_pull_apis.py` updated from 3 dead URLs to
  4 live ones (the old separate `landslide_reporter` service is gone; its records are
  now folded into `Reports_Points`/`Reports_Polygons`, tagged
  `event_import_source = 'LRC'` vs `'GLC'`). Ran `python 02_pull_apis.py coolr` for
  real against the fix: 217 corridor points, 1 corridor polygon, layer discovery and
  the geojson dump path all functioning.

**Important, and not yet acted on: no script converts the COOLR pull into the training
CSV.** `glc_chickens_neck_bbox.csv` (what `load_glc()` actually reads) was produced
outside these checked-in scripts — `raw/events/coolr_*.geojson` is fetched but nothing
downstream turns it into that file. Fixing the endpoint makes fresh COOLR data
*reachable* again; it does not by itself refresh what the model trains on. That
conversion is scoped to **Phase C** (see below), not this fix.

**What the fresh data actually contains, checked directly against the live
service:** GLC-tagged events did not stop in 2017 — they thinned sharply (1,089 in
2017, 838 in 2018, then 39 / 15 / 4 / 1 / 7 / 2 / 5 for 2019–2025) but never reached
zero. In the corridor bbox specifically, 13 GLC events exist past the local file's
cutoff (2017-07-10), all dated through **2018-09-17**; none in-bbox after that. So
Phase C has ~14 months of genuine backlog to recover, not a live daily feed — the
post-2018 trickle exists globally but has not hit this corridor.

### P0 root cause: it was never a negative-sampling bug

`build_negatives` draws negative dates from the **positives'** year span
(`build_labels.py:313`, `years = rng.integers(yr_lo, yr_hi + 1)`). `max_event_date` is
`2026-09-11`, past the CHIRPS record end of `2025-12-31`, so 60 positives dated 2026
were admitted — and those 60 pushed `yr_hi` to 2026, which let **4,853 negatives** be
sampled across a year with no rainfall to read. `win_sum` then snapped each one's
window back to 2025-12-31, turning monsoon rows into dry ones.

So patching the sampler would have left the 60 rainfall-less positives behind and
fixed only the symptom. The guard belongs at the temporal gate in `filter_events`,
which every event passes through, and is derived from the record rather than
configured so it cannot drift when CHIRPS is extended:

```python
hi = min(pd.Timestamp(lc.max_event_date), record_end(resolve(cfg, cfg.paths.chirps_csv)))
```

Verified on the real event table: 9 out-of-record events dropped, filtered range ends
`2025-09-12`, and the year span driving negative sampling is now **2007..2025**.
`test_no_leakage.py::test_temporal_gate` gained the upper bound, so the invariant is
enforced rather than re-analysed later — the failure mode Stage 9 A called out.

**This test is red until the rebuild**, by design: it correctly reports that the
*current* `labels_v1` still holds rows dated to 2026-12-28. It going green is the
acceptance check for the rebuild.

### Panel rebuild: done, and one consequence disclosed here in full

`make panel && make splits` (via `run_stage2.py`, config repointed to
`corridor_chirps_daily_p05.csv.gz`) ran clean: labels 10.2s, panel 38.3s, splits 71.3s
(leakage gate: 0 shared segments/events/blocks), qa 0.6s. `data/processed/{labels,panel,folds}_v1.parquet`
and `data/interim/` were snapshotted to `data/_snapshots/pre_p05_rebuild/` first, so
the pre-rebuild state is recoverable without relying on re-run determinism.

Positives: 9,387 → **9,327** (the 60 out-of-record rows gone). Negatives scaled with
them at the fixed 10:1 ratio (−600). Total rows 103,246 → **102,581**, exactly
accounting for both. `test_no_leakage.py::test_temporal_gate` — the P0 acceptance
check — now **passes**.

**Disclosed side effect: the locked test set's block membership shifted by one
block.** `_final_test`'s held-out blocks are drawn by `rng.choice` over
`df[df.target==1].spatial_block_id.value_counts()` (`make_splits.py:159-170`) — a
seeded draw, but one that indexes into a list built from the **current** positive
rows. P0 removing 60 positives changed that list's composition, so the *same* seed 42
call now lands on different indices:

| | held-out blocks |
|---|---|
| `final_v1`/`final_v2` (`reports/stage9/PREREGISTRATION_V2.json`) | `BLK_004_006, BLK_004_007, BLK_005_004, BLK_006_008, BLK_009_005` |
| post-rebuild | `BLK_004_006, BLK_004_007, BLK_005_004, **BLK_006_007**, BLK_009_005` |

Checked directly: `BLK_006_007` and `BLK_006_008` are **separate, single-block
components** (`_block_components`, verified via a direct query) — not the same region
under a different label, and not merged by the union-find expansion either time. This
is a genuine shift in which 4-of-114 blocks are locked away, not a cosmetic one.

**This is not the re-draw Rule 2 forbids, and it is not cherry-picking.** Nothing in
this rebuild touched `_final_test`, the RNG call, the seed, or the block-selection
code — the shift is a mechanical, foreseeable consequence of a legitimate upstream
correctness fix (P0) changing the positive-row composition that feeds an otherwise
untouched, deterministic draw. But the practical effect is the same as a re-draw: the
locked test region `final_v1`/`final_v2` were scored against **no longer exists** in
`folds_v1.parquet`. Anyone comparing a new model's locked-test number to
`final_v2`'s 2.65×/0.290/0.630/1.43× is comparing across two different held-out
regions unless this is accounted for.

**What this means in practice, stated plainly:**
- It does not touch Phase A's dev-CV experiments — those never read the locked split.
- It does not compromise the leakage gate — 0 shared segments/events/blocks held on
  the new draw too, checked above.
- It **does** mean `final_v2`'s exact test numbers cannot be reproduced by rebuilding
  the panel and re-scoring the old model — the champion must be retrained on the new
  panel before any locked-split comparison is meaningful, which is what the Stage 10
  campaign-skip rule already requires when the data fingerprint changes. State this
  explicitly in whatever supersedes `PREREGISTRATION_V2.json`, the way Stage 9
  disclosed the leak: cause, evidence, consequence, in one place.
- It is why 4 tests now fail (see below) — they are not a regression, they are the
  correct, designed reaction to `folds_v1.parquet` and `oof_predictions.parquet` /
  `deploy/bundles/` no longer describing the same locked-test region.

### Four expected post-rebuild test failures — stale artifacts, not new bugs

`test_oof_predictions_no_label_leak`, `test_error_analysis_excludes_locked_final_test`,
`test_feature_parity_with_panel`, `test_predictions_bit_identical_to_training_path`
now fail. All four compare a **saved artifact from before the rebuild** —
`models/*/oof_predictions.parquet` (trained on the old panel/split) or
`deploy/bundles/*` (built from the old CHIRPS 0.25° features) — against the **new**
`folds_v1.parquet` / `panel_v1.parquet`. That mismatch is exactly what each test is
built to catch, and catching it is correct: those artifacts are stale until the
champion is retrained (Stage 10) and rebundled (`make bundle`), which is out of scope
for a panel rebuild. **Do not patch these tests to pass** — they should stay red until
the retrain actually happens, and go green as a real consequence of it, not an edit.

### The `nearest_cell_map` defect, and why it mattered

`geo.py` built one full `n_segments x n_cells` haversine matrix, with the comment
*"small grids (~132 cells) -> full distance matrix is fine"*. At 0.25° that is 1 GB
and fine. At 0.05° it is **309,042 x ~9,600 = 23.7 GB**, and the process is
OOM-killed (verified: exit 137). **Phase A could not have run at all** until this was
fixed, and the failure would have surfaced only after the data re-pull.

The fix chunks over segments so peak memory is ~32 MB at any grid spacing. It is
behaviour-preserving, not an approximation — verified bit-identical at 0.25°
(`cell_id` identical for all 309,042 segments, max distance difference `0.000e+00 m`),
and 0.05° now completes in 28 s. `tests/test_geo.py` pins that chunk boundaries cannot
change an assignment.

Test suite after the change, with `data2/` wired up: **177 passed, 5 skipped**.

### Phase A verdict: the hypothesis is refuted, and something else showed up

**Success criterion, pre-registered above:** *steep OOF ROC gain clears the A/A floor on
≥4/5 folds and all 3 seeds.* **It does not. Phase A fails.**

The comparison is properly controlled. Because `record_end` is `2025-12-31` for both
CHIRPS files, the P0-bounded temporal gate admits **identical positives**, so
`pos_blocks`, the seeded `rng.choice` and therefore the folds come out the same. Verified
before measuring: **all 13 fold columns byte-identical**, same 102,581 rows, same held-out
blocks, same 9,327 positives. Rainfall values are the only difference between the arms.
Both started from `final_v3`; the registry was reset to it so the arms were symmetric.

| metric (`final_v3`, identical folds) | 0.25°+P0 | 0.05°+P0 | |
|---|---|---|---|
| **steep ROC (OOF)** | 0.7265 | 0.7278 | **+0.0013 — nil** |
| steep lift@10% | 2.4348 | 2.7443 | +0.31 |
| non-steep ROC | 0.8447 | 0.8702 | +0.025 |
| in-sample/OOF ratio | 1.8759 | 1.8408 | less memorisation |
| worst terrain calibration × | 1.1684 | 1.0695 | −0.099 |
| worst fold AP | 0.1536 | 0.1388 | **−0.015 worse** |
| FN share on a dry day | 0.500 | 0.635 | **+0.135 worse** |

+0.0013 is about an eighth of the steep-ROC A/A floor. **The 9.5× tie-group reduction
did not convert into steep-terrain discrimination.** §1's arithmetic was right about the
tie-group and wrong about it being the binding constraint.

**An earlier reading in this file was wrong and is corrected here.** The first
(uncontrolled) comparison showed steep ROC 0.7508 → 0.7278 and was nearly written up as
"0.05° made it worse". The control shows that drop was the **P0 target change**, not
resolution:

| panel | mean AP |
|---|---|
| 0.25°, no P0 | 0.4011 |
| 0.25° + P0 | 0.3826 |
| 0.05° + P0 | 0.3909 |

P0 costs −0.019 (it deletes fabricated-easy rows, so the target is honestly harder) and
resolution gains +0.008. Bundling P0 into the resolution rebuild broke Rule 1 and cost a
whole extra campaign to untangle — the instruction to "fold in P0 while the panel is
rebuilding" was a mistake and is struck.

**What 0.05° actually bought — the A/A noise floors, on identical folds:**

| floor | 0.25°+P0 | 0.05°+P0 | |
|---|---|---|---|
| AP (`delta_floor`) | 0.0164 | 0.0106 | −35% |
| worst fold | 0.1177 | 0.0451 | −62% |
| steep ROC | 0.0198 | 0.0109 | −45% |
| terrain calibration | 0.6505 | 0.0237 | **−96%** |

Finer rainfall did not make the model much better; it made it far more **stable**, and
the loop a far more sensitive instrument. Physically consistent: 152 steep segments
sharing one rainfall vector makes the fit hostage to a handful of cells; 16 per cell is
closer to independent information. The visible cost is daily zero-inflation — at 5.5 km
many cells read 0 mm on the trigger day where a 28 km average did not, which is what
drives FN-share-on-dry-days 0.500 → 0.635.

**0.05° is kept — for stability, not accuracy.** The tighter floors compound into every
future experiment (X3's region harm is *detected* at 0.05° and invisible at 0.25°, where
the worst-fold floor is 0.1177), and worst-terrain calibration 1.1684 → 1.0695 moves
toward failing gate G6. It does **not** rescue Phase A, and the steep gates are untouched.

**One clean causal result.** `S3_uniform_weights` reverses under control: removing the
label-confidence weights costs **−0.0286 at 0.25° (REJECT)** but only **−0.0045 at 0.05°
(ACCEPT)**. Better rainfall data makes a hand-tuned heuristic redundant. `final_v4` =
D1 + S3 on 0.05°; the 0.25° arm produced its own D1-only `final_v4`, recorded in the
ledger as `campaign_not_adopted` so its presence at the ledger tail is not mistaken for
the champion's provenance.

**Carry forward:** `X4_seed_bag_3` posted 5/5 folds, 3/3 seeds, p=0.062 on **both**
panels independently, blocked only by the noise floor (+0.0066 vs 0.0106; +0.0094 vs
0.0164). Replication across independent data is the strongest signal in the backlog, and
at 0.05° the floor is now close to resolving it. It no longer breaches the calibration
guardrail that rejected it on the old panel. More seeds would settle it.

### The acquisition problem, and how it was avoided

`10_chirps.sh` fetches **global** yearly netCDFs from CHC and subsets them locally.
That is 74 MB/yr at 0.25° (1.5 GB total, what is on disk now) but **1.13 GB/yr at
0.05° — 23.7 GB** to keep a 3.0° × 2.7° box. Confirmed by `HEAD` against CHC: the
0.05° file exists and is `content-length: 1129741271`.

`10b_chirps_p05.py` fetches the same product from the **IRI Data Library**, which
subsets server-side, so only the corridor crosses the wire — **~100 MB instead of
23.7 GB**, a 235× reduction, and no change to the 63 GB of free disk.

**It is the same data, not a substitute.** Validated by running the new fetcher at
0.25° and diffing against the existing CHC-derived `corridor_chirps_daily.csv.gz` for
2005: **48,180 rows, all matched, `max |diff| = 0.000000 mm`, zero rows differing by
more than 0.001 mm**, on the identical 132-cell grid. The output schema is
byte-compatible with `03_build_corridor.py::stage_chirps`, so the only downstream
change is `conf/config.yaml: paths.chirps_csv`.

---

## 0. The four gates, and what each one actually needs

| # | gate | threshold | `final_v2` | fixable from | phase |
|---|---|---|---|---|---|
| G2 | top-of-ranking precision | `precision@100 >= 0.50` | **0.290** | policy (capacity), then ranking | **E**, then A/B |
| G4 | steep-terrain discrimination | `steep ROC-AUC >= 0.70` | **0.630** | data resolution | **A → B** |
| G5 | steep-terrain lift | `>= 2.0x` | **1.43x** | same as G4 — one finding, two expressions | **A → B** |
| G6 | calibration transfers | worst terrain stratum `<= 1.5x` | **2.65x** | local history only | **D** |

G4 and G5 are **one failure**, not two. G6 is **not fixable from dev at all** and no
amount of modelling will move it. G2's threshold has a provenance defect (§E).

### Why the model-side is closed

Do not re-open these. Each was measured, not argued:

| ruled out | where | result |
|---|---|---|
| steep terrain under-represented | Stage 9 D1 | it is 41% of dev rows, 89.3% of dev positives — it *is* the population |
| no signal inside steep terrain | Stage 9 D2 | `api_mm` ROC 0.727 *inside* steep vs 0.669 overall — rainfall is **stronger** there |
| model under-fits steep terrain | Stage 9 D3 | OOF steep ROC 0.751 / 0.763 / 0.756, beating the best single feature |
| a dedicated steep-only model | Stage 9 D4 | -0.0232 / -0.0916 / -0.0621 across 3 seeds |
| climate-relative rainfall (the transfer fix) | Stage 10 X3 | -0.0028, 1/5 folds, p=0.562 — **not demonstrated** |
| finer calibration bins | Stage 9 D | worst-stratum transfer got *worse* (1.24x vs 1.04x) |
| focal loss, seed bagging, coarse static bins, HPO, architectures | Stages 6, 7, 10 | null or guardrail-breaking |

Dev CV cannot resolve an effect below the **A/A noise floor of 0.0130 AP**
(worst-fold floor 0.0442) with 115 positive clusters. Every experiment above landed
inside it. **The ceiling is information, not modelling.**

---

## 1. Root cause, quantified

Stage 9 D concluded "~25 km daily rainfall cannot resolve valley-scale triggering."
Measured from `data/processed/panel_v1.parquet`, here is that statement as numbers:

| | value |
|---|---|
| corridor segments in the panel | 61,872 |
| distinct CHIRPS cells covering them | **114** |
| steep segments (`slope_mean_deg >= 10`) | 18,146 |
| distinct cells holding them | **60** |
| **steep segments sharing one identical rainfall vector** | **median 152** (p90 810, max 1,534) |
| segment → cell-centre distance | median **10,323 m**, p95 15,792 m, max 18,567 m |

*Measured with the project's own `nearest_cell_map` against a reconstructed CHIRPS
0.25° grid. The reconstruction is exact, not approximate: it reproduces the
`cell_dist_m` recorded in `panel_v1` to **median |diff| = 0 m, corr = 1.00000**, so
these are the real cells the panel was built on.*

**Within a cell, every steep segment is rainfall-identical to the model on a given
day.** The only remaining discriminator is static terrain — measured inside the steep
band at `slope_mean_deg` ROC **0.511** and `elevation_mean` **0.498** (Stage 9 D2),
i.e. nothing. The model is asked to rank ~135 mutually indistinguishable segments and
returns 0.63.

That is the bound. It is arithmetic, not a training failure — which is exactly why
five model-side attacks all returned null.

---

## Phase A — CHIRPS 0.05°: the cheap decisive test

**The roadmap's P2 jumps straight to GPM IMERG. There is a much cheaper test first.**

`DATA_DECISIONS.md:165` states "CHIRPS is ~25 km & daily" as a property of the
product. It is a property of the **variant we downloaded**. CHIRPS v2.0 ships
natively at **0.05° (~5.5 km)**; the 0.25° file is a coarsened convenience product.
Same provider (UCSB Climate Hazards Center), same 1981–present record, same daily
cadence, same CSV shape, free.

### Projected effect (measured, not estimated)

Both columns computed with `nearest_cell_map` over the 61,872 panel segments:

| | 0.25° (now) | 0.05° | change |
|---|---|---|---|
| cells over the panel segments | 114 | **2,048** | 18.0x |
| cells holding steep segments | 60 | **757** | 12.6x |
| **median steep segments per cell** | **152** | **16** | **9.5x smaller tie-group** |
| p90 steep segments per cell | 810 | 56 | 14.5x |
| max steep segments per cell | 1,534 | 234 | 6.6x |
| segment → cell-centre distance (median) | 10,323 m | **2,083 m** | 5.0x |

**Confirmed upstream:** CHIRPS v2.0's native daily product is 0.05°, 1981–present,
50°S–50°N; the 0.25° file is the coarsened variant
([CHC](https://www.chc.ucsb.edu/data), [Earth Engine catalog](https://developers.google.com/earth-engine/datasets/catalog/UCSB-CHG_CHIRPS_DAILY)).

### Why this before IMERG

IMERG is a different provider (NASA Earthdata auth), a different format (HDF5), a
different volume (half-hourly), and a new ingestion pipeline. Phase A is a **path
change and a re-pull**. It tests the same hypothesis — *is spatial resolution the
binding constraint?* — at a fraction of the cost, and its result decides whether
Phase B is worth funding:

- **steep ROC moves** → resolution confirmed as the lever; fund Phase B.
- **steep ROC does not move** → spatial resolution is **not** the lever. The surviving
  hypotheses are sub-daily intensity specifically (Phase B, narrower justification)
  and label quality (P3). Money saved.

Either outcome is informative. That is what makes it worth doing first.

### Changes

1. **Acquisition** — `data2/other_files/scripts/10b_chirps_p05.py` (written, validated):

   ```
   data2/other_files/venv/bin/python data2/other_files/scripts/10b_chirps_p05.py
   ```

   Writes `rainfall_chirps/corridor_chirps_daily_p05.csv.gz` in the existing schema.
   Year-by-year with retries and an on-disk cache, so an interrupted run resumes. It
   **does not touch the 0.25° file** — the champion must stay reconstructible.
2. **`conf/config.yaml:13`** — point `paths.chirps_csv` at the new file.
3. **`src/sih_ml/features/rainfall.py` needs no change** — `build_cell_series` pivots
   on `cell_id` and is agnostic to grid spacing.
   **`nearest_cell_map` did need one, and it is already applied** (see *Work
   completed*). An earlier draft of this plan claimed no code change at all was
   required; that was wrong, and trying it is what found the defect.
4. `make panel && make splits` → `panel_v2`.

   > **Struck.** This step used to read "fold the P0 fix in at the same time so the panel
   > is rebuilt once, not twice." That broke Rule 1: P0 and the resolution change landed
   > together, the resulting steep-ROC drop was misattributed to resolution, and a second
   > full campaign was needed to separate them. Change **one** thing per rebuild. The
   > controlled arm is the template: because both CHIRPS files end 2025-12-31, applying
   > P0 to both arms leaves the folds byte-identical and isolates rainfall cleanly.

### Fold in P0 while the panel is rebuilding

`CONTINUOUS_IMPROVEMENT.md` P0: `panel_v1` carries 4,913 rows dated beyond the CHIRPS
record (4,455 of them in dev, all negatives), snapped back to the record's last day —
fabricated dry negatives. Stage 10 D1 masks them at evaluation time; the **builder must stop
producing them**. Clamp negative-sampling dates to the rainfall record in
`build_panel`. **Done** — see *P0 root cause* and *Panel rebuild* below;
`test_panel_v1_defect_is_pinned_and_masked` is retired (renamed
`test_panel_v1_has_no_rows_beyond_the_rainfall_record`, asserts 0 such rows instead of
pinning their presence).

### Watch for

- **Station sparsity.** CHIRPS gains sub-grid detail from IR + station blending, and
  NE India is station-sparse. Effective resolution will be coarser than the nominal
  grid; the gain is real but **bounded**, and may be well under the 8.4x the
  tie-group arithmetic suggests. State this in the report whatever the result.
- **Spatial-block CV is built on a 0.25° grid** (`DATA_DECISIONS.md` §8, 96 blocks).
  **Do not re-cut the blocks to 0.05°.** Blocks exist to defeat spatial
  autocorrelation and are unrelated to rainfall grid spacing; re-cutting them changes
  the evaluation and the inputs in one step, and nothing downstream would be
  comparable to the champion.
- **Cells with no station support** may carry interpolation artifacts at 0.05°. Check
  the per-cell record for constant runs and zero-inflation before trusting it.

### Success criterion

Run as a Stage 10 experiment, same rules, no exceptions:

```yaml
- id: "D2_chirps_005"
  round: 0                    # data-layer correctness/resolution change
  kind: "superiority"
  layer: "data"
  bottleneck: "steep"
  change: {chirps_grid: "p05"}
  hypothesis: >-
    Steep-terrain discrimination is bounded by rainfall tie-groups: a median of 135
    steep segments share one identical rainfall vector at 0.25 deg. CHIRPS native
    0.05 deg cuts that to 16. If resolution is the binding constraint, steep ROC
    rises above the A/A floor; if it does not, spatial resolution is not the lever.
  evidence: "GATE_REMEDIATION_PLAN.md Phase A; Stage 9 D; Stage 10 X3 null"
```

Requires a new `chirps_grid` key in `CHANGE_KEYS` / `KNOWN_KEYS`
(`src/sih_ml/improve/candidate.py:38`) and a branch in the candidate builder
alongside the `rain_local_percentile` handling at `candidate.py:125`.

**Pass:** steep OOF ROC gain clears the A/A floor (0.0130) on >= 4/5 folds and all 3
seeds, with every existing guardrail held (`conf/improve_config.yaml: guardrails`).
**Note the campaign skip rule fires automatically** — the data fingerprint changes, so
every decided question re-opens by design. Re-run the full round-1 backlog on the new
data; X1 and X4 are explicitly queued for this (roadmap P6).

**Effort:** small. Re-pull + config + panel rebuild + one campaign. The unknown is the
acquisition pipeline, which is outside this repo.

---

## Phase B — sub-daily intensity (GPM IMERG)

Conditional on Phase A. **Reframe the roadmap's P2: its value is temporal, not
spatial.** IMERG's 0.1° (~11 km) is *coarser* than CHIRPS 0.05° (~5.5 km). What IMERG
uniquely provides is **half-hourly** rainfall — and that fixes a defect Phase A cannot
touch.

**Phase A's result strengthens this, and narrows it.** Spatial resolution is now
measured, not assumed: 5× finer cells moved steep ROC +0.0013. Spatial is spent. The one
thing the controlled arm made *worse* is the temporal axis — FN-share-on-dry-days rose
0.500 → 0.635 because finer daily cells are zero-inflated on the trigger day. The model
is missing positives it reads as dry, at exactly the time resolution IMERG would replace.
So Phase B is no longer "more resolution, in the other axis"; it is the **only remaining
rainfall axis**, aimed at a measured failure rather than a predicted one. If sub-daily
intensity also lands inside the floor, rainfall as an input is exhausted and the decision
moves to labels (P3) or gauges.

### The intensity–duration feature is currently degenerate

`src/sih_ml/features/rainfall.py:13-36`:

```python
# NE-Himalaya intensity-duration threshold  I = c * D^(-b)   (I mm/hr, D hr)
ID_C, ID_B = 5.8294, 0.4141

def _id_ratio(total_mm, duration_days):
    dur_hr = duration_days * 24.0
    i_obs = total_mm / dur_hr
```

The published curve is TRMM-derived (2007–2016) and calibrated where cloudbursts live:
**D ≈ 3–6 hr**. Daily CHIRPS floors `D` at 24 hr, so `i_obs` is a 24-hour *average*.

**100 mm in 4 hours (I = 25 mm/hr, far over threshold) and 100 mm spread evenly over
24 hours (I = 4.2 mm/hr, under it) produce the identical feature value.** The physics
the feature encodes — burst intensity — is averaged away before the model sees it, and
the curve is evaluated two orders of magnitude outside its calibration domain.
`max_1d_in_3d` is a daily-granularity proxy for the same quantity and hits the same
floor.

This is a stronger argument for IMERG than resolution, and it is the one to put in the
acquisition request.

### IMERG is blocked on credentials — and a better-controlled probe exists

**Measured, not assumed.** GES DISC serves IMERG *metadata* publicly — `.dds` returns 200
and confirms the structure (`precipitation[time][lon=3600][lat=1800]`, 0.1° global, one
granule per 30 min) — but a **data** request returns **HTTP 401, Earthdata login
required**. No credentials exist anywhere in this workspace. IRIDL redirects GPM to its
`dlauth` page too, so the auth-free trick that saved Phase A 23.7 GB does not transfer.
Separately, 2005–2025 is **~368,000 half-hourly granules**; even with an account that
needs a subsetting service, not granule-by-granule fetching.

**So Phase B is probed with ERA5 hourly first — and this is not merely a fallback, it is
the better-controlled experiment.** Open-Meteo's ERA5 archive needs no auth, is already
this pipeline's rainfall provider (`02_pull_apis.py::sec_rainfall`), and returns 21 years
of hourly data for a point in one request. Swapping CHIRPS-daily for IMERG-half-hourly
would change product, spatial resolution *and* temporal resolution at once — the exact
confound that cost Phase A an extra campaign. Here both arms come from one hourly file:

| experiment | change | isolates |
|---|---|---|
| `X5_era5_daily` | ERA5 summed to daily 1/3/7 d totals | "a second rainfall product helps" |
| `X6_era5_subdaily` | worst 1/3/6/12 h bursts in the preceding 24 h and 72 h | **X6 − X5 = sub-daily information** |

Two one-change experiments, Rule 1 compliant. `id_ratio` columns are deliberately not
emitted: for a fixed duration they are a constant rescaling of the corresponding maximum,
and a tree is invariant to monotone transforms of a single feature — interpretability,
not information.

**Caveat recorded before any result.** ERA5 is reanalysis at ~0.25° and is documented in
this repo's own `10_chirps.sh` to under-represent extreme orographic Himalayan rain — the
precise signal being tested. **A null is therefore ambiguous**: sub-daily may add nothing,
or ERA5 may not resolve the bursts. **A positive is strong**, and is what justifies asking
the user to create a (free) Earthdata account and acquiring IMERG properly.

Built for this: `data2/other_files/scripts/22_era5_hourly.py` (resumable, cached,
backs off — it survived a 300 s stall and a DNS failure mid-pull),
`src/sih_ml/improve/subdaily.py` (wired into `build_candidate`, new columns registered in
`monotone_rainfall_features` — the escape that caused the Stage 9 bug), and
`tests/test_subdaily.py`, which pins the premise directly: two days with **identical
48 mm daily totals** give max-1h of **2.0 vs 28.0**.

### Phase B verdict on ERA5: sub-daily adds nothing, and the isolation held

Campaign `c20260922T135017Z`, from champion `final_v4`, A/A floor **0.0084**:

| experiment | Δ AP | folds | worst fold | decision |
|---|---|---|---|---|
| `X5_era5_daily` (control) | +0.0061 | 3/5 | −0.0785 | **REJECT** — region guardrail (floor −0.0296) |
| `X6_era5_subdaily` | +0.0046 | 4/5 | −0.0837 | **REJECT** — region guardrail **and** terrain calibration 1.08× → **1.74×** |

**Isolated sub-daily effect = X6 − X5 = −0.0015**, against a floor of 0.0084. Sub-daily
burst structure adds **nothing** beyond the same product's daily totals. The control did
its job: without X5 the +0.0046 on X6 would have looked like a small sub-daily gain;
against X5 it is visibly the product, not the granularity — and even that is inside the
floor.

**The pre-registered caveat stands and limits the claim.** ERA5 is reanalysis at 0.25°
and under-represents orographic extremes, so this does **not** prove sub-daily intensity
is worthless — it proves *ERA5's* sub-daily structure carries no information its own
daily totals lack. IMERG could still differ. But the cheap probe has now been run, and it
does not support funding the IMERG acquisition on the strength of an expected gain.

**Unexpected and more interesting: every rainfall-feature experiment breaks region
transfer.** Three independent instances now, all breaching the same guardrail:

| experiment | what it adds | worst fold |
|---|---|---|
| `X3_rain_local_percentile` | climate-normalised rainfall | −0.0826 |
| `X5_era5_daily` | a second rainfall product, daily | −0.0785 |
| `X6_era5_subdaily` | the same product, sub-daily | −0.0837 |

Every attempt to give the model *more rainfall information* costs cross-region
generalisation by roughly the same amount, while the guardrail floor is −0.0296. The
consistent reading is that extra rainfall detail lets the model fit region-specific
rainfall-response relationships that do not travel between valleys — which is the very
failure (region transfer) that Stage 9 D named as the root cause of the steep gates. This
reframes the roadmap: **the constraint is not rainfall information, it is that
rainfall-response is region-specific.** More or finer rainfall makes that worse, not
better. P2's premise — that better rainfall unlocks the steep gates — is now contradicted
from three directions.

That points the remaining effort at labels (P3), local recalibration (Phase D), and
region-invariant modelling — not at another rainfall acquisition.

### PHASE B FINAL VERDICT — IMERG acquired, both arms run

IMERG was acquired for real: 363,744 half-hourly granules (2005-01-01 .. 2025-09-30,
complete 30-min grid, zero gaps), reduced once to a 6.8M-row per-cell-day table by
`data2/other_files/scripts/24_imerg_consolidate.py`. Campaign `c20260923T115449Z`,
A/A floor 0.0084:

| experiment | delta AP | folds | seeds | decision |
|---|---|---|---|---|
| `X5_era5_daily` (control) | +0.0061 | 3/5 | 2/3 | REJECT |
| `X6_era5_subdaily` | +0.0046 | 4/5 | 2/3 | REJECT |
| `X7_imerg_daily` (control) | **+0.0408** | **5/5** | **3/3** | **ACCEPT** |
| `X8_imerg_subdaily` | +0.0329 | 4/5 | 3/3 | REJECT |

**Sub-daily intensity adds nothing, from two independent products:**
ERA5 `X6 - X5 = -0.0015`; IMERG `X8 - X7 = -0.0079`. Both inside the 0.0084 floor, both
negative. **The pre-registered caveat is resolved rather than left hanging:** ERA5's null
was NOT an artifact of reanalysis missing extremes. IMERG demonstrably sees more of them
(1 h burst p99 16.65 mm vs ERA5's 12.90) and still adds nothing sub-daily. The
intensity-duration argument for Phase B -- `_id_ratio` degenerate at D=24 h, burst
structure averaged away -- does not survive contact with the data from either product.

**The control arm is the real finding.** `X7_imerg_daily` is the **first superiority
ACCEPT in this project's history**: +0.0408 AP, ~5x the floor, every fold and every seed,
no guardrail breached. That is IMERG *daily totals* beating CHIRPS daily totals. The win
is the **product**, not the granularity -- a different axis from the one Phase B set out
to test, and a different axis from Phase A's spatial-resolution work.

**And it moved steep terrain, which Phase A could not.** Seed-averaged steep ROC
**0.7300 -> 0.7594 (+0.0294, 2.9x the 0.0101 steep floor)**. Phase A's whole 0.05 deg
programme moved the same metric +0.0013. What finally moved steep-terrain discrimination
was neither finer spatial resolution nor sub-daily intensity, but a better product.

This partly revises the Phase A / Phase B meta-finding recorded above. The earlier
conclusion -- "every rainfall-feature experiment breaks region transfer, so the constraint
is that rainfall-response is region-specific" -- held for X3/X5/X6 but **not** for X7:
IMERG daily improved worst-fold AP (0.1391 -> 0.1534) and worst-region calibration
(3.1340 -> 3.0596) rather than degrading them. Better rainfall *data* helps; more rainfall
*derived features* from a weak product does not. Those are different claims and the
earlier text conflated them.

**Costs, stated plainly.** Fold AP spread widened (0.4233 -> 0.4785) and worst-terrain
calibration worsened (seed-avg 1.0783 -> 1.1782). The latter is within tolerance (rule:
ratio <= 1.5, increase <= 0.25; actual 1.178, +0.100) which is why X7 passed where X8 --
pushing the same metric to 1.60 -- did not. But gate **G6 is calibration transfer**, so
this is movement in the wrong direction on an already-failing gate, bought for a large AP
and steep-ROC gain. Phase D (local recalibration) is now more important, not less.

**A replicated failure mode:** sub-daily burst features damage terrain calibration in both
products -- 1.08 -> 1.60 (IMERG X8), 1.08 -> 1.74 (ERA5 X6).

New champion **`final_v6` = D1_rainfall_coverage + X7_imerg_daily**; A/A floor tightened
0.0084 -> 0.0073. `X4_seed_bag_3` replicated a **fourth** time (+0.0068, 5/5, 3/3,
p=0.062) and now sits essentially at the tightened resolution threshold.

### Changes (once IMERG credentials exist)

1. Ingest IMERG Final Run (half-hourly, 0.1°) for the corridor bbox and date range.
   **Keep CHIRPS.** They are complementary — CHIRPS for the long antecedent windows
   (finer spatially, longer record back to 1981), IMERG for short-duration intensity.
   Do not replace one with the other.
2. `rainfall.py`: add short-duration windows (`D = 1, 3, 6, 12 hr`) and compute
   `_id_ratio` at each, where the published curve is actually valid. Keep the existing
   1/3/7/15/30-day antecedent features unchanged.
3. Add peak-intensity features: max 1 hr, max 3 hr, max 6 hr within the preceding 24 h
   and 72 h.
4. **Preserve the leakage firewall.** `FORECAST_HORIZON_DAYS = 1` means the cutoff is
   `date - 1 day`. Sub-daily features must respect the same cutoff — the temptation to
   use same-day sub-daily rainfall is a leak, and a decisive one.
5. **Register every new rainfall column in `monotone_rainfall_features`.** This is the
   exact bug Stage 9 C fixed: `id_exceed_1d/3d/7d` were derived from constrained
   features but absent from the constraint set, and 77 violations resulted. New
   `id_ratio` / exceedance columns will reproduce it if not registered. Gate 12 is the
   regression test — it must stay at 0 violations with flags recomputed.

### Success criterion

Steep-terrain ROC on spatial CV clears the A/A floor over the Phase A champion; then
the fresh holdout (Phase C). Same decision rule, no exceptions.

**Effort:** large. New provider, auth, format, volume, plus feature work. **Do not
start before Phase A reports.**

---

## Phase C — fresh holdout (do this BEFORE A and B are scored)

**Sequencing is the point of this phase.** The locked split has now been read for two
decisions (Stage 8 opening, Stage 9 remediation). `REMEDIATION.md` states the bias
plainly: the v2 test number is "a strong check, not a virgin estimate." There is no
clean arbiter left, and Phases A and B will need one.

Freeze all events after the current data window **before any Phase A result is seen**.
Pre-register the opening the way `reports/stage9/PREREGISTRATION_V2.json` does:
config hash, threshold, metrics, and the decision rule, all committed in advance.

If Phase A is measured first and the holdout is cut afterwards, the same
test-informed contamination that compromised v1→v2 repeats, and the result will not
be defensible. **Cut the holdout first.** Dev spatial CV remains the arbiter for the
experiments themselves; the holdout is opened once, at the end.

### What "freeze after the current window" turned out to mean

`max_event_date` is `2026-09-11`; today is `2026-09-22`. Checked directly against the
live COOLR service (its endpoint was dead and is now fixed — see *Work completed*
above): the in-scope source (`coolr_glc`) is **not a live daily feed**. Its bulk-era
volume ended in 2018 (1,089 events in 2017, 838 in 2018) and thinned to single digits
per year afterward, but never reached zero — 39 / 15 / 4 / 1 / 7 / 2 / 5 events/year
globally, 2019 through 2025. In the corridor bbox specifically: **13 GLC events sit
past the local extract's cutoff (2017-07-10), the newest dated 2018-09-17, and none
after that.**

So "freeze events after the current window" does not describe an existing gap waiting
to be cut — the corridor has been quiet, in this source, since 2018. Phase C is a
**recovery task**, not a freeze:

1. Pull the live corridor extract (`coolr_reports_points`/`polygons`, `f=geojson`,
   corridor bbox — the fixed pull in *Work completed* already does this) and convert
   it to `load_glc()`'s CSV schema. **No script currently does this conversion** —
   `glc_chickens_neck_bbox.csv` was hand-built outside `data2/other_files/scripts/`.
   Write one, diff against the existing file by `event_id`, and add only rows not
   already present — do not wholesale-replace a file whose provenance for the
   existing 200 rows is otherwise undocumented.
2. The 13 recovered events extend the *labelled* record to 2018-09-17. That is 7 years
   short of "today," not a fresh holdout by itself.
3. A holdout with any statistical power needs either (a) a wait — GLC's own reporting
   lag means "recent" will keep meaning 2018 until NASA's citizen-science pipeline
   produces more in-corridor events, or (b) admitting `event_import_source='LRC'`
   (citizen-science reports) as a second in-scope population, **with the same
   rainfall-signal probe Stage 9 ran on the news sources** (ROC-by-antecedent-window,
   trigger-field variance, location-accuracy check) run on LRC *before* trusting it.
   LRC is a different provenance from GLC and Stage 9 §B's whole finding was that an
   unchecked provenance mix hides a confound inside an aggregate.

**Until one of those is done, Phase C stays paused — not blocking Phase A.** The panel
rebuild and dev-CV experiments in Phase A do not need a fresh holdout; only the final
open of the locked-split successor does.

### Resolution: the fresh-holdout plan is void; re-scoped and answered — 2026-09-23

**A fresh holdout never materialised, and by the time Phases A and B were actually
scored the reason to want one had also disappeared.** Re-verified against current
post-rebuild data before re-scoping, not assumed: `coolr_glc` still ends 2017-07-10;
every 2019+ row (1,020 positives, 17 events) is 100% `corridor_landslides` /
`reliefweb_events`, both out of scope under `scope_to_rain_attributable` — 0% in-scope,
so the temporal block cannot produce an AP or ROC under this project's own scoping
rule. IMERG does not help either: `record_end()` reads CHIRPS, so the label window is
unchanged. The 13 GLC / 2 LRC recovery events (§ above) would land inside the existing
**val** block (2016-01-01→2018-12-28), not past any holdout boundary — real
data-correctness work, still open, but it does not produce a holdout either.

**What replaced the question:** by 2026-09-23, Phases A and B were both scored, so
"give them a clean arbiter before scoring" no longer applied to anything. What did
apply: `final_v6` (`D1_rainfall_coverage` + `X7_imerg_daily`, Phase B's IMERG result)
was the project's first superiority ACCEPT — +0.0408 dev AP, 5/5 folds, 3/3 seeds, ~5×
the A/A floor — and had never been scored on the locked split. The registry recorded
`"locked_split": "NOT opened — release requires pre-registration"` for v3 through v6
alike. Phase C became: **open the locked split once, under pre-registration, and find
out whether that gain is real.**

**The trap this required watching for:** the P0 rebuild that fixed Phase A's target
leak also swapped block `BLK_006_008` out of the locked split for `BLK_006_007` —
confirmed by diffing `reports/stage8/group_performance.csv`'s block list against the
current split. That raised the split's base rate from Stage 9's 0.0966 (7,674 rows) to
the current 0.150 (8,533 rows) — a 55% shift, on gates (`AP/base>2.0`, `precision@100`)
that move mechanically with base rate. Comparing `final_v6` against Stage 9's *recorded*
gate numbers would have measured the rebuild, not the model. **So the opening scored
two models, not one**: `final_v6` and `final_v2` (the release champion), both
**retrained fresh** on the current dev panel in the same run, both calibrated on their
own dev out-of-fold scores, both scored on the identical current-split population.
(`final_v2`'s saved artifact was rejected as a baseline for the same reason its
registry numbers were: fit 2026-09-12, fingerprint `45c695ea5427d643`, before the
rebuild — reusing it would have scored it partly on rows it had since been excluded
from training on.)

Pre-registered in `reports/stage10/PREREGISTRATION_V3.json`, **before** the split was
read: success = candidate beats baseline on in-scope AP; on failure, **the baseline
stays release champion, decided in advance, not renegotiated after the number came
back.**

**Result — `final_v6` did not beat `final_v2`. `final_v2` stays the release champion.**

| | `final_v2` (baseline) | `final_v6` (candidate) | Δ |
|---|---|---|---|
| in-scope AP (full split, n=8,353) | **0.3138** | 0.3048 | **−0.0090** |
| precision@100 | 0.510 | 0.500 | −0.010 |
| recall @ own dev threshold | 0.879 | 0.969 | +0.090 |
| steep ROC-AUC | 0.6252 | 0.6085 | −0.0167 |
| worst terrain calibration ratio | 1.93x | 1.78x | (both fail G6) |
| deployment gates passing | **9/12** | 8/12 | −1 |

The dev-side gain — +0.0408 AP, +0.0294 steep ROC, 5/5 folds, 3/3 seeds — **did not
transfer.** On the one slice that is genuinely never-scored by any prior model
(`BLK_006_007`, 1,556 rows / 909 positives, swapped in by the rebuild), the same
direction holds: `final_v2` 0.7169 AP vs `final_v6` 0.6760. Not uniform, though —
on the four blocks shared with the v1/v2-era split, `final_v6` wins clearly (0.2429 vs
0.1725), so the reversal is population-dependent, not a wholesale contradiction of the
dev result. One gate result is worth flagging on its own: `final_v6` **fails** "rainfall
is actually driving the prediction" (25.1%, threshold ≥30%) where `final_v2` passes
(42.6%) — a model built around a *better* rainfall product relying *less* on rainfall
by this counterfactual-zero-rain test on this population, the opposite of what adding
IMERG was meant to buy.

Full breakdown, gates CSVs, and the calibration table are in
`reports/stage10/PHASE_C_FINAL_TEST.md`. The opening is the locked split's 8th
(`reports/stage7/TEST_SET_LEDGER.json`); `models/registry.json` now separates
`champion` (still `final_v6`, the best *dev* candidate — this result doesn't change
that) from `release_champion` (`final_v2`).

**Net effect on the original gate count:** none of the four still-failing gates from
the top of this document flip on the CURRENT split, under either model — G2, G4, G5,
G6 (precision@100, steep ROC, steep lift, calibration transfer) all still fail. The
project's honest status is unchanged: 8 of 12 gates pass, `final_v2` remains what
would ship if a release decision were forced today, and Phase B's real headline is
methodological rather than a shipped improvement — IMERG *daily totals* beat CHIRPS
*daily totals* on dev (the product matters more than temporal granularity, matching
Phase A's spatial-resolution null), but that gain has not yet been shown to survive
contact with held-out data.

---

## Phase D — local recalibration (the only fix for G6)

G6 (2.65x vs 1.5x) is **not fixable from dev, and no experiment should try.** Stage 9
tested finer bins and made it worse. The gate asks probabilities to transfer to a
region with no local history — which deployment will never actually face.

Build the seasonal recalibration loop (roadmap P4): refit per-slope calibrators on
operational history each season, on local data, using the coarse bins Stage 9 kept
(`calibration_bins: [0.0, 2.5, 10.0, 20.0, 90.0]`).

**Do not move the 1.5x threshold to make this pass.** The honest posture: G6 stays
failing on the locked split, and Phase D is measured on **next season's operational
data** — worst terrain stratum <= 1.5x after local refit. Until that number exists,
`DEPLOYMENT.md`'s rule stands: **ship the ranking, not the probability**, and
`W = dist*(1 + lambda*P)` does not consume `P` on unseen terrain.

### Built, and backtested — 2026-09-23. Result: does not clearly help, and probably can't yet

**"Next season's operational data" does not exist** — no live deployment, and
`serve/monitor.py` confirmed to log input drift and Prometheus metrics only, nothing
about eventual outcomes. What was built instead:

1. **The mechanism.** `fit_stratified`/`apply_stratified`
   ([models/calibration.py](src/sih_ml/models/calibration.py)) — extracted from four
   places that each hand-rolled the same pooled+per-stratum-with-fallback fit
   (`run_improve.py`, `run_remediate.py`, `final_test.py`, `final_test_v3.py`), now one
   function all four call.
2. **A backtest** ([final/local_recalibration.py](src/sih_ml/final/local_recalibration.py)):
   every dev spatial block spans 2007–2025, so splitting a block's own rows
   chronologically (60% early = simulated "local history", 40% late = simulated "next
   season") and asking whether refitting on the early years improves calibration on the
   late years of the *same* block is a real test, not a fabrication. Tiered fallback —
   isotonic when a block's history clears 30 rows/5 positives, a plain sigmoid shift
   when it clears 10/2, else the block is left on the global calibrator.
3. **A dormant serving hook** ([serve/local_calibration.py](src/sih_ml/serve/local_calibration.py)):
   `LocalCalibration`, loaded optionally by `Bundle` and consulted by `Predictor.score`
   only when a `segment_id` is given and a fitted local calibrator exists for its
   region — strictly additive, bit-identical to today's output otherwise (verified:
   `tests/test_local_calibration.py`, and the *existing* `deploy/bundles/current` still
   loads and scores unchanged). Dormant because there is nothing to feed it yet;
   `scripts/run_recalibrate.py` documents the proposed operational-log schema for
   whoever wires real logging.

**Backtest result, `final_v2`, 109 dev blocks scored:**

| | |
|---|---|
| blocks with ≥100 rows and ≥10 positives at all | 24 |
| too few positives in the *later* 40% to even measure against | 15 |
| enough to measure against, too little history to fit anything | 1 |
| a local calibrator actually fitted | **8** |
| of those, local beat global | **2 / 8** |
| median \|ratio−1\| across all 24 scored blocks, global | 0.705 |
| median \|ratio−1\| where a local fit was tried, local | **1.675 — worse** |

**Local recalibration made calibration worse more often than it helped, on the data
available to test it with.** Root cause, checked directly rather than assumed: **23 of
24 blocks have a LOWER positive rate in the later slice than the earlier one** —
not a scattering of unlucky blocks, a near-universal pattern. This matches something
already documented in this project (Phase C's investigation): `coolr_glc`'s own
reporting volume collapsed after 2018 (1,089 events in 2017, 838 in 2018, then single
digits per year) — a **label-reporting-density artifact**, not evidence that the
corridor became safer. A calibrator fit on an earlier, more densely-reported period and
applied to a later, more sparsely-reported one will systematically over-predict
relative to the falling positive rate, which is exactly the failure mode measured
(`BLK_005_005`: history ratio 0.39 → local 1.57; `BLK_000_007`: 11.9 → 32.1).

**This means the backtest's negative result is ambiguous, not a clean refutation of the
mechanism.** "History predicts the future" fails here specifically because the
*history* comes from a period the label source reported more completely, not
necessarily because same-region recalibration is unsound. A REAL seasonal loop, fed by
consistent operational monitoring rather than retrospective label-source density that
changes over time, is not shown to fail by this — it is simply untested, which is where
this phase started.

**Standing conclusions, unchanged:**
- **G6 stays failing.** No threshold moved. This backtest is explicitly not treated as
  evidence G6 passes, in either direction.
- **`DEPLOYMENT.md`'s rule stands**: ship the ranking, not the probability, until a real
  season of operational history exists to refit against.
- The mechanism and its serving hook are real, tested, and ready — genuinely dormant,
  not vaporware — for whenever that data exists. What is NOT claimed is that it will
  work; the one thing tested here suggests the naive version needs a data source whose
  reporting completeness does not drift under it, which retrospective landslide
  inventories in this corridor do not offer.

Full per-block numbers: `reports/final/local_recalibration_backtest.csv` and
`local_recalibration_summary.json`.

---

## Phase E — re-derive G2's threshold from capacity, not from a leaked number

`precision@100 >= 0.50` was set when v1 measured 0.810. **That 0.810 was leak-
inflated** — `_final_test` lifted 3 gold rows out of a block whose other 4,421 rows,
including 15 positives of the same segment, stayed in training. Removing the news
positives alone took it to 0.450; scoped training took it to 0.320.

The threshold has a **provenance defect that is independent of the current result**:
it was calibrated against a measurement now known to be invalid. That is a legitimate
reason to re-derive it. It is **not** a licence to lower it because it fails.

Re-derive from operational capacity (roadmap P5): Stage 11 measures 3.5k alerts +
21k reviews/day at the dev threshold. Settle with MDoNER what the actual daily review
capacity is, set `k` from that, and set the precision bar from
`reports/stage9/dev_cost_curve.csv` **on dev**, before the holdout is opened.

Also settle FN:FP here. Stage 7 measured 10 as strictly dominating the Stage 3
placeholder of 20 (1 point of recall for 1,341 fewer false alarms). It remains
unvalidated with the actual operator.

**Record the re-derivation and its justification in the pre-registration, before any
new number is measured.** A threshold changed after seeing a result is post-hoc
selection whatever the reasoning.

### Built — 2026-09-24. FN:FP settled; the capacity half needed more than the text asked for

**FN:FP, with current numbers, not the 2026-09-11 ones already in this document.**
Re-verified on `reports/stage10/dev_cost_curve.csv` (`final_v6`'s own curve, already on
disk): FN:FP=10 gives recall 0.871 at 24,831 false positives; FN:FP=20 gives recall
0.933 at 30,769 — **+0.062 recall for +5,938 more false alarms.** Direction still holds
(10 dominates 20), but the specific "1,341 fewer false alarms" figure above is stale
(Stage 7's v1-era curve) — cite the current numbers instead.

**This surfaced a live drift, documented and left alone, not fixed:** `final_v2` — the
actual release champion per Phase C — still ships its ORIGINAL frozen threshold
(0.0271), derived under FN:FP=20 back when it was frozen. `conf/improve_config.yaml`
and every champion since Stage 10 (`cost_fn_over_fp: 10`, `dev_operating_threshold_fn_fp_10`
in the registry) has assumed FN:FP=10 ever since, but nobody updated `final_v2` itself.
`final_v2` is the model actually treated as deployable, so this plan does not change
what it ships — the drift is stated here so it is visible, not silently inherited.

**The capacity half required more than "read `dev_cost_curve.csv` on dev."**
Investigating it found the dev/test panel is case-control constructed and does not
represent real-world prevalence: dev base rate is 8.56% (94,048 rows, 8,046 positives),
while the REAL corridor base rate — estimated directly from actual event counts (172
events over 18.4 years, 309,042 segments) — is **~8.27×10⁻⁸ per segment-day, roughly a
million times lower.** Presenting a `precision@k` or coverage-fraction number from dev
as "what MDoNER would see" would be actively misleading, not just imprecise. There is
no cheap reweighting fix either: checked directly in
`labels/build_labels.py::build_negatives`, neither `case_control_negative` (easy,
low-susceptibility, far from any hazard) nor `hard_negative_matched` (a terrain-matched
donut around events) is a random sample of the true negative population — both are
deliberately stratified in opposite directions.

**So the capacity table joins two populations, never blends them.** New:
`src/sih_ml/final/capacity.py`. Alert VOLUME is measured on the REAL, full
309,042-segment corridor — `final_v2` retrained fresh (not the stale saved artifact,
not the stale `deploy/bundles/current` built from `final_v3`), scored via the actual
serving path (`FeatureStore`/`Predictor`, reusing `build_bundle`/`Bundle.load` rather
than hand-rolling schema construction) on 3 REAL historical dates picked from the
corridor's own 7-day-rainfall 10th/50th/90th percentiles (2009-03-08 dry,
2012-05-03 moderate monsoon, 2023-09-25 heavy monsoon) — no case-control sampling
anywhere in this path. PRECISION/RECALL at the same thresholds still comes from
`final_v2`'s dev OOF, labeled plainly as curated-population, not real-world.

**The result changes the shape of the question.** At `final_v2`'s own current frozen
threshold (0.0271):

| day | alerts/day | reviews/day | reviews as % of all 24,073 steep segments |
|---|---|---|---|
| dry | 0 | 1 | 0.004% |
| moderate monsoon | 278 | 3,747 | 15.6% |
| heavy monsoon | 18,048 | 18,091 | **75.2%** |

**One fixed threshold cannot serve both ends of this range.** On a heavy monsoon day
three-quarters of every steep segment in the corridor clears the bar at once — not a
prioritized queue, "review nearly everything" — while the same threshold alerts on
almost nothing on a dry day. This is expected given G5 (rainfall genuinely drives the
score) but it means a single re-derived precision bar was never going to be the right
shape of answer. `serve/batch.py` already has the better mechanism half-built:
`tier_rank` (rank within tier, independent of the probability threshold) exists
precisely so a consumer can take "top N of today's ranking" instead of trusting a
fixed cutoff — nothing currently sets N from a real capacity number, which is the
actual open question, not the threshold.

**G2's status is unchanged.** Its threshold's provenance defect stays documented as
above; the new table (`reports/final/PHASE_E_CAPACITY_THRESHOLD.csv` and `.md`) is
offered as what to read once a real daily capacity or a real precision pilot exists —
a superseding reference, not a claim that G2 now passes or that its number is
trustworthy. `CONTINUOUS_IMPROVEMENT.md`'s P5 line ("3.5k alerts + 21k reviews/day")
predates this and should be read as superseded by the per-weather-condition numbers
above, which vary by four orders of magnitude depending on the day.

---

## Order of work

```
Phase C  freeze fresh holdout            <-- FIRST, before anything is measured
   |
Phase A  CHIRPS 0.05 deg + P0 panel fix  <-- cheap, decisive, gates Phase B
   |
   +-- moves steep ROC? ---- yes ----> Phase B  IMERG sub-daily intensity
   |                                       |
   +-- no --> spatial resolution is not the lever;
              re-scope B to intensity only, or go to P3 (label date audit)
   |
Phase E  G2 threshold from MDoNER capacity   (parallel, policy work)
Phase D  seasonal local recalibration        (parallel, post-processing)
   |
open the fresh holdout, once, pre-registered
```

Phases D and E are **parallel** — neither depends on A or B, and both are blocked on
an external party (MDoNER), so start the conversations now.

### What clears what

| phase | gates it can move |
|---|---|
| A → B | G4, G5, and G2 indirectly (better ranking raises `precision@k`) |
| D | G6 — but only measurable on next season's data |
| E | G2's threshold, re-derived from capacity rather than inherited |

**Honest expectation: A and B are not guaranteed to clear G4.** They address the
measured binding constraint, which is the best available reason to expect movement —
but Stage 9 D's conclusion is a *generalization* ceiling, and finer inputs narrow the
tie-group without guaranteeing the relationships transfer between valleys. If Phase B
also lands inside the A/A floor, the conclusion is that this product cannot clear G4
on satellite rainfall, and the decision moves to gauge data, a different label
strategy (P3), or accepting the decision-support pilot as the permanent scope.

---

## Rules this plan does not get to break

1. **One change per experiment.** Enforced in `apply_change`
   (`src/sih_ml/improve/candidate.py:48`). Phase A changes the data fingerprint, so
   the backlog re-runs — it does not get bundled with feature work.
2. **The locked split is not re-drawn.** Not to fix a gate, not to improve a number.
3. **No gate threshold moves to make a gate pass.** Phase E moves one threshold, for
   a documented provenance defect, pre-registered before measurement.
4. **Every guardrail in `conf/improve_config.yaml` holds.** Stage 10 X4 posted the
   campaign's only positive AP delta and was rejected for shipping 1.41x
   miscalibration. That rule stands.
5. **Effects inside the A/A floor are not results.** 0.0130 AP; worst-fold 0.0442.
6. **`final_v1` and `final_v2` stay reconstructible.** Keep the 0.25° CHIRPS file.

---

## Open questions

- ~~Is the `data2/` acquisition pipeline able to re-pull CHIRPS at 0.05°?~~
  **Answered: yes.** `10_chirps.sh` was hardcoded to `p25` and would have cost 23.7 GB
  at `p05`; `10b_chirps_p05.py` replaces it with a validated IRIDL subset at ~100 MB,
  fetched and validated: 24.85M rows, 2005–2025, corr 0.999996 against the 0.25° file.
- ~~Is there enough fresh data for Phase C to be a real holdout?~~ **Answered: no, not
  yet.** Checked directly against the (now-fixed) live COOLR service: the in-scope
  source has 13 unrecovered corridor events, newest dated **2018-09-17**, and nothing
  in-corridor since. Phase C is a label-recovery task with a provenance check (LRC vs
  GLC), not a freeze-and-cut — see Phase C for the revised plan. It does not block
  Phase A.
- Does IMERG Final Run cover the full label window back to 2005-07-01? (IMERG begins
  2000-06; the GPM era is well covered, but confirm the Final Run product, not Early.)
- What is MDoNER's actual daily review capacity? Blocks E, and therefore blocks the
  definition of "top-of-ranking precision" the product is really held to.
