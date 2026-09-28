"""Phase D backtest: does refitting a calibrator on a region's own EARLY history
improve its calibration on that SAME region's LATER rows, versus the global
(cross-fitted, per-slope) calibrator `final_v2` actually ships today?

Dev blocks only — zero locked-split cost, per project decision — and every spatial
block spans 2007-2025 (verified against folds_v1.parquet: no block is a narrow time
slice), so a chronological split within a block is a real backtest, not a fabrication.

This is NOT evidence that gate G6 passes. G6 needs a real season of OPERATIONAL
history, which this project does not have (see GATE_REMEDIATION_PLAN.md Phase D and
src/sih_ml/serve/local_calibration.py). Every number here answers "how much would this
mechanism help if local history existed", not a release-readiness claim.

    python -m sih_ml.final.local_recalibration [conf/improve_config.yaml]
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pandas as pd

from sih_ml.final import blocks as blk
from sih_ml.improve import candidate as C
from sih_ml.improve.features import LocalRainPercentiles, coverage_mask
from sih_ml.models import calibration as Cal
from sih_ml.models.dataset import load_data
from sih_ml.optimize import calibrate as cal_mod
from sih_ml.utils.common import REPO_ROOT, get_logger, set_seed

log = get_logger("final.local_recalibration")

OUT_DIR = REPO_ROOT / "reports" / "final"
MIN_BLOCK_ROWS, MIN_BLOCK_POS = 100, 10       # too small to simulate a season at all
MIN_N_ISOTONIC, MIN_POS_ISOTONIC = 30, 5      # enough to trust a local isotonic curve
MIN_N_SIMPLE, MIN_POS_SIMPLE = 10, 2          # enough for a simple sigmoid shift only
HISTORY_FRAC = 0.6                            # first 60% of a block's dates = "history"


def _ratio(y: np.ndarray, p: np.ndarray) -> float:
    obs = float(np.mean(y)) if len(y) else float("nan")
    return float(np.mean(p) / obs) if obs > 0 else float("nan")


def local_calibrator(y_hist: np.ndarray, raw_hist: np.ndarray):
    """Tiered fallback, cheapest reliable method first: isotonic when there's enough
    local history to trust a curve, a plain sigmoid (logit-space) shift when there's
    only a little, else None -- too little history to say anything, keep the global
    calibrator. Both classes must be present or sklearn cannot fit either method."""
    n, pos = len(y_hist), int(y_hist.sum())
    if pos == 0 or pos == n:
        return None, None
    if n >= MIN_N_ISOTONIC and pos >= MIN_POS_ISOTONIC:
        pooled, _ = Cal.fit_stratified(y_hist, raw_hist, strata=None)
        return "isotonic", pooled
    if n >= MIN_N_SIMPLE and pos >= MIN_POS_SIMPLE:
        from sih_ml.models.calibration import Calibrator
        return "sigmoid_shift", Calibrator("sigmoid").fit(raw_hist, y_hist,
                                                           float(y_hist.mean()), None)
    return None, None


def backtest_block(y, raw, p_global, dates) -> dict | None:
    order = np.argsort(dates)
    y, raw, p_global, dates = y[order], raw[order], p_global[order], dates[order]
    cut = int(len(y) * HISTORY_FRAC)
    y_h, raw_h = y[:cut], raw[:cut]
    y_t, p_global_t, raw_t = y[cut:], p_global[cut:], raw[cut:]
    row = {"n_history": int(cut), "n_pos_history": int(y_h.sum()),
          "n_target": int(len(y_t)), "n_pos_target": int(y_t.sum()),
          "global_ratio": float("nan"), "local_ratio": float("nan"),
          "method": None, "improved": False}
    if len(y_t) < 20 or y_t.sum() < 2:
        # Every block that clears the OUTER filter (main()'s MIN_BLOCK_ROWS/POS) gets
        # a row here, even when it turns out too sparse to score -- an earlier version
        # returned None and dropped these silently, which understated exactly how
        # positive-starved most blocks are (24/109 scored blocks even reach 10 total
        # positives; a further chronological split then starves many of THOSE too).
        row["method"] = "too_little_target_history"
        return row

    method, cal = local_calibrator(y_h, raw_h)
    row["global_ratio"] = _ratio(y_t, p_global_t)
    row["method"] = method or "too_little_history_for_any_local_fit"
    if cal is None:
        return row
    p_local_t = cal.transform(raw_t)
    row["local_ratio"] = _ratio(y_t, p_local_t)
    row["improved"] = (np.isfinite(row["local_ratio"]) and np.isfinite(row["global_ratio"])
                       and abs(row["local_ratio"] - 1) < abs(row["global_ratio"] - 1))
    return row


def main(config_path: str | None = None) -> None:
    cfg_path = Path(config_path) if config_path else REPO_ROOT / "conf" / "improve_config.yaml"
    data, cfg = load_data(cfg_path)
    set_seed(cfg.seed)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    ic = cfg.improve
    folds, seeds, bins = list(ic.folds), list(ic.seeds), list(ic.calibration_bins)

    v2_state = json.loads((REPO_ROOT / "models" / "registry.json").read_text())
    v2_state = next(v["state"] for v in v2_state["versions"] if v["version"] == "final_v2")
    coverage = coverage_mask(data, cfg)
    pctl = LocalRainPercentiles(cfg)
    cand = C.build_candidate(v2_state, "final_v2_backtest", data, cfg,
                             coverage=coverage, pctl=pctl)
    res = C.run(cand, folds, seeds, keep_models=False)
    log.info("final_v2 dev mean AP %.4f (reproducing the release champion for this backtest)",
             res["mean_AP"])

    raw = res["oof"][seeds[0]]
    fold_of = res["fold_of"]
    strata = cal_mod.slope_stratum(cand.data, bins)
    scored = np.isfinite(raw)
    p_global = cal_mod.cross_fitted_calibration(cand.data, raw, fold_of, folds, strata)

    block_of = blk.block_of_row(cand.data, cfg)
    dates = pd.to_datetime(cand.data.panel["date"]).to_numpy()
    y = cand.data.y

    rows = []
    n_blocks_scored = 0
    for b in pd.unique(block_of[scored]):
        m = scored & (block_of == b)
        if m.sum() < MIN_BLOCK_ROWS or y[m].sum() < MIN_BLOCK_POS:
            continue
        n_blocks_scored += 1
        rows.append({"block": b, **backtest_block(y[m], raw[m], p_global[m], dates[m])})

    df = pd.DataFrame(rows)
    df.to_csv(OUT_DIR / "local_recalibration_backtest.csv", index=False)

    fitted = df[df.method.isin(["isotonic", "sigmoid_shift"])]
    n_improved = int(fitted.improved.sum())
    summary = {
        "n_blocks_with_ge_100_rows_and_ge_10_positives": n_blocks_scored,
        "n_blocks_too_sparse_for_a_target_season": int((df.method == "too_little_target_history").sum()),
        "n_blocks_with_target_but_too_little_history_to_fit": int(
            (df.method == "too_little_history_for_any_local_fit").sum()),
        "n_blocks_a_local_calibrator_was_actually_fitted_for": int(len(fitted)),
        "n_blocks_improved": n_improved,
        "frac_improved_of_fitted": float(n_improved / len(fitted)) if len(fitted) else float("nan"),
        "median_abs_dev_from_1_global_all_scored_blocks": float((df.global_ratio - 1).abs().median()),
        "median_abs_dev_from_1_local_where_fitted": float((fitted.local_ratio - 1).abs().median()) if len(fitted) else float("nan"),
        "caveat": (f"BACKTEST on dev blocks' own early-vs-late history, not operational "
                  f"data. {n_blocks_scored - len(fitted)}/{n_blocks_scored} scored blocks "
                  "have too few positives, or too few in the later chronological slice, "
                  "to even attempt local recalibration -- read as evidence about data "
                  "sparsity, not just the mechanism. Does not change gate G6, which "
                  "remains failing pending a real season of operational history -- see "
                  "GATE_REMEDIATION_PLAN.md Phase D."),
    }
    (OUT_DIR / "local_recalibration_summary.json").write_text(json.dumps(summary, indent=2))
    log.info("=" * 78)
    log.info("%d/%d blocks with a local calibrator actually fitted improved "
             "(%d too sparse for a target season, %d had a target but too little "
             "history to fit)", n_improved, len(fitted),
             summary["n_blocks_too_sparse_for_a_target_season"],
             summary["n_blocks_with_target_but_too_little_history_to_fit"])
    log.info("median |ratio-1| across ALL scored blocks: global %.3f | "
             "median |ratio-1| where a local fit was actually tried: local %.3f",
             summary["median_abs_dev_from_1_global_all_scored_blocks"],
             summary["median_abs_dev_from_1_local_where_fitted"])
    log.info("=" * 78)


if __name__ == "__main__":
    import sys
    main(sys.argv[1] if len(sys.argv) > 1 else None)
