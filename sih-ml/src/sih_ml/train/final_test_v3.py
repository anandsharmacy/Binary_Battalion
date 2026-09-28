"""Phase C — paired opening of the locked split under PREREGISTRATION_V3.

Scores TWO models on the CURRENT locked split in ONE opening: the release
champion `final_v2` and the dev candidate `final_v6` (D1_rainfall_coverage +
X7_imerg_daily). Both are RETRAINED from their registry `state` on the current
dev panel — the saved `models/final_v2/` artifact was fit on the pre-rebuild
panel (fingerprint 45c695ea5427d643, 2026-09-12) when `BLK_006_007` was still a
dev block; reusing it here would score v2 on rows it has already seen.

Why this exists (see GATE_REMEDIATION_PLAN.md Phase C): the split's base rate
moved 0.0966 -> 0.150 between Stage 9 and now (the P0 rebuild swapped
BLK_006_007 in for BLK_006_008), so Stage 9's recorded gate numbers are not a
valid baseline for v6 — comparing against them would measure the rebuild, not
the model. The only valid comparison is both models scored on the SAME
population, in the SAME run, which is what this module does.

Protocol mirrors final_test.py: pre-registration required (PREREGISTRATION_V3),
one call to `final_test_index` (recorded in the SAME ledger every other opening
uses — this is still the one physical split), metrics frozen before the split
is read. Success rule, pre-registered in PREREGISTRATION_V3.json: v6 must beat
v2 on in-scope AP, or v2 stays the release champion — decided now, not after
the number is known.
"""
from __future__ import annotations

import json
import time
from pathlib import Path

import numpy as np
import pandas as pd
from sklearn.metrics import average_precision_score, roc_auc_score

from sih_ml.eval.metrics import ranking_report
from sih_ml.final import blocks as blk
from sih_ml.final import readiness as rd, robustness
from sih_ml.improve import candidate as C
from sih_ml.improve import diagnose as Dg
from sih_ml.improve.features import LocalRainPercentiles, coverage_mask
from sih_ml.models import calibration as Cal
from sih_ml.models.dataset import load_data
from sih_ml.optimize import calibrate as cal_mod
from sih_ml.optimize import runtime as rt
from sih_ml.optimize import threshold as thr_mod
from sih_ml.utils.common import REPO_ROOT, get_logger, git_sha, set_seed

log = get_logger("stage10.final_v3")

PREREG_PATH = REPO_ROOT / "reports" / "stage10" / "PREREGISTRATION_V3.json"
OUT_DIR = REPO_ROOT / "reports" / "stage10" / "final_v3"


def _load_state(version: str) -> dict:
    reg = json.loads((REPO_ROOT / "models" / "registry.json").read_text())
    v = next((x for x in reg["versions"] if x["version"] == version), None)
    if v is None:
        raise SystemExit(f"{version} not found in models/registry.json")
    return v["state"]


def _fit_and_calibrate(name: str, state: dict, data, cfg, coverage, pctl,
                       folds: list[int], seeds: list[int], bins: list[float],
                       fn_over_fp: float) -> dict:
    """Cross-validated dev OOF (for the operating threshold and diagnostics), then the
    final model trained on ALL dev rows, calibrated on that same OOF — the Stage 9 rule
    (fit on out-of-fold, not on training predictions)."""
    cand = C.build_candidate(state, name, data, cfg, coverage=coverage, pctl=pctl)
    res = C.run(cand, folds, seeds, keep_models=False)
    log.info("  %-10s dev mean AP %.4f (per-seed %s)", name, res["mean_AP"],
             {s: round(float(np.mean(list(res["ap"][s].values()))), 4) for s in seeds})

    p_cal = Dg.calibrated_oof(cand, res, folds, bins)
    m = np.isfinite(p_cal)
    cc = thr_mod.cost_curve(cand.data.y[m], p_cal[m], [fn_over_fp],
                            float(cfg.optimize.threshold.fbeta))
    threshold = float(cc.iloc[0].threshold)

    dev = np.where(data.dev_mask() & cand.train_mask)[0]
    members = [C._fit_member(cand, dev, 0, int(cfg.seed), j)[0]
              for j in range(int(state["bag"]))]
    model = members[0] if len(members) == 1 else C.BaggedModel(members)

    oof = res["oof"][seeds[0]]
    strata = cal_mod.slope_stratum(cand.data, bins)
    mo = np.isfinite(oof)
    y_dev = cand.data.y
    pooled, per = Cal.fit_stratified(y_dev[mo], oof[mo], strata[mo])
    return {"name": name, "cand": cand, "model": model, "pooled": pooled, "per": per,
            "dev_threshold": threshold, "dev_mean_AP": res["mean_AP"], "strata_bins": bins}


def _apply_calibrator(raw, strata, pooled, per):
    return Cal.apply_stratified(raw, strata, pooled, per)


def _score_population(y, p, thr, steep_mask) -> dict:
    rep = ranking_report(y, p)
    yhat = (p >= thr).astype(int)
    tp = int(((yhat == 1) & (y == 1)).sum()); fp = int(((yhat == 1) & (y == 0)).sum())
    fn = int(((yhat == 0) & (y == 1)).sum())
    prec = tp / max(1, tp + fp); rec = tp / max(1, tp + fn)
    rep.update({"threshold": thr, "tp": tp, "fp": fp, "fn": fn,
               "precision": prec, "recall": rec,
               "f1": 2 * prec * rec / max(1e-9, prec + rec)})
    if steep_mask.sum() and y[steep_mask].sum():
        base = float(y[steep_mask].mean())
        rep["steep_base_rate"] = base
        rep["steep_AP"] = float(average_precision_score(y[steep_mask], p[steep_mask]))
        rep["steep_roc_auc"] = (float(roc_auc_score(y[steep_mask], p[steep_mask]))
                                if 0 < y[steep_mask].sum() < steep_mask.sum() else float("nan"))
    return rep


def main(config_path: str | None = None) -> None:
    cfg_path = Path(config_path) if config_path else REPO_ROOT / "conf" / "improve_config.yaml"
    data, cfg = load_data(cfg_path)
    set_seed(cfg.seed)
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    if not PREREG_PATH.exists():
        raise SystemExit(
            f"REFUSING to open the locked test set: {PREREG_PATH} does not exist.\n"
            "Write PREREGISTRATION_V3.json first -- it pins the two model states, the "
            "success rule, and the metric list BEFORE any test row is read.")
    prereg = json.loads(PREREG_PATH.read_text())

    ic = cfg.improve
    folds, seeds, bins = list(ic.folds), list(ic.seeds), list(ic.calibration_bins)
    coverage = coverage_mask(data, cfg)
    pctl = LocalRainPercentiles(cfg)

    fits = {}
    for entry in prereg["models"]:
        state = _load_state(entry["registry_version"]) if entry.get("registry_version") \
            else entry["state"]
        fits[entry["name"]] = _fit_and_calibrate(
            entry["name"], state, data, cfg, coverage, pctl, folds, seeds, bins,
            float(prereg.get("cost_fn_over_fp", 20)))

    # ------------------------------------------------- OPEN THE LOCKED SPLIT (once)
    # improve_config.yaml inherits final_test.preregistration from optimize_config.yaml
    # (unset -> DEFAULT_PREREG, Stage 7's v1 file) since every OTHER caller of this
    # chokepoint is revalidating a v1/v2-era model. This opening is pre-registered
    # under PREREGISTRATION_V3 instead, so it must point there explicitly -- editing
    # the shared yaml would silently redirect every other caller too.
    data.prereg_path_ = PREREG_PATH
    te = data.final_test_index(reason=prereg["opening_reason"])
    log.info("opened final_test: %d rows, %d positives", len(te), int(data.y[te].sum()))

    block_of = blk.block_of_row(data, cfg)

    in_scope = data.in_scope()
    steep = np.nan_to_num(data.panel["slope_mean_deg"].to_numpy(float), nan=0.0) >= \
        float(ic.guardrails["steep_slope_deg"])
    old_v1v2_blocks = {"BLK_004_006", "BLK_004_007", "BLK_005_004", "BLK_006_008",
                       "BLK_009_005"}
    fresh_block = "BLK_006_007"

    populations = {
        "full_in_scope": te[in_scope[te]],
        f"{fresh_block}_only": te[(block_of[te] == fresh_block)],
        "shared_v1v2_blocks_in_scope": te[in_scope[te] & np.isin(block_of[te],
                                                                 list(old_v1v2_blocks))],
    }

    results = {}
    for name, fit in fits.items():
        cand, model = fit["cand"], fit["model"]
        # cand.data carries this candidate's merged features (IMERG, percentiles); the
        # base `data` object does not, so prediction MUST go through cand.data -- row
        # order and length are identical to `data` (add_to() is a length-preserving
        # left merge, verified in tests/test_imerg_subdaily.py), so indices computed
        # from `data` (te, populations, steep) apply unchanged.
        raw = model.predict(cand.data.X(te))
        strata_te = cal_mod.slope_stratum(cand.data, bins)[te]
        p = _apply_calibrator(raw, strata_te, fit["pooled"], fit["per"])

        pop_metrics = {}
        for pop_name, idx_full in populations.items():
            pos = np.searchsorted(te, idx_full)  # idx_full subset of te, both sorted
            y_pop, p_pop = data.y[idx_full], p[pos]
            pop_metrics[pop_name] = _score_population(y_pop, p_pop, fit["dev_threshold"],
                                                       steep[idx_full])
            pop_metrics[pop_name]["n_rows"] = int(len(idx_full))

        imerg_cols = [c for c in cand.data.features if c.startswith("imerg_")]
        n_nan_rainfall = int(cand.data.panel[imerg_cols].iloc[te].isna().any(axis=1).sum()) \
            if imerg_cols else 0
        te_full_idx = populations["full_in_scope"]
        pert = robustness.perturbation_sweep(cand.data, model, te_full_idx, seed=cfg.seed)
        cf = robustness.counterfactual_rainfall(cand.data, model, te_full_idx)
        mono = robustness.monotonicity_check(cand.data, model, te_full_idx, cand.monotone,
                                             seed=cfg.seed, update_exceed_flags=True)
        runtime = rt.profile(model, cand.data.X(), cfg.optimize.runtime)
        w = pop_metrics["full_in_scope"]
        rb = {"worst_test_stratum_ratio": float("nan"),  # filled from cal table below
              "pct_at_sigma_025": float(pert.loc[pert.sigma == 0.25, "pct_of_clean"].iloc[0]),
              "retained_frac": cf["positives_median_retained_frac"], "bit_identical": True}

        cal_bins = list(cfg.remediate.steep.fine_slope_bins)
        slope_full = np.nan_to_num(
            cand.data.panel["slope_mean_deg"].to_numpy(float)[te_full_idx], nan=0.0)
        y_full = data.y[te_full_idx]
        pos_full = np.searchsorted(te, te_full_idx)
        p_full = p[pos_full]
        rows = []
        for lo, hi in zip(cal_bins[:-1], cal_bins[1:]):
            mm = (slope_full >= lo) & (slope_full < hi)
            if mm.sum() < 30 or y_full[mm].sum() < 3:
                continue
            obs = float(y_full[mm].mean())
            rows.append({"stratum": f"slope [{lo:g},{hi:g})", "n": int(mm.sum()),
                        "predicted": float(p_full[mm].mean()), "observed": obs,
                        "pred_over_obs": float(p_full[mm].mean() / obs) if obs > 0 else np.nan})
        cal_tab = pd.DataFrame(rows)
        wv = cal_tab.pred_over_obs.to_numpy(float)
        wv = wv[np.isfinite(wv) & (wv > 0)]
        rb["worst_test_stratum_ratio"] = float(np.max(np.maximum(wv, 1 / wv))) if len(wv) else np.nan
        viol = int(mono[mono.exceed_flags_updated].violations.sum())

        gates = rd.deployment_gates(w, rb, runtime)
        gates = pd.concat([gates, pd.DataFrame([{
            "gate": "rainfall monotonicity enforced end-to-end",
            "threshold": "0 rank violations with derived flags recomputed",
            "measured": f"{viol} violations", "pass": viol == 0,
            "why": "more rain must never lower the score",
        }])], ignore_index=True)

        results[name] = {
            "dev_threshold": fit["dev_threshold"], "dev_mean_AP": fit["dev_mean_AP"],
            "populations": pop_metrics, "n_nan_rainfall_rows": n_nan_rainfall,
            "test_calibration": cal_tab.to_dict("records"), "gates": gates.to_dict("records"),
            "n_gates_pass": int(gates["pass"].sum()), "n_gates_total": int(len(gates)),
        }
        gates.to_csv(OUT_DIR / f"deployment_gates_{name}.csv", index=False)
        cal_tab.to_csv(OUT_DIR / f"calibration_{name}.csv", index=False)
        log.info("  %-10s in-scope AP=%.4f  gates %d/%d  worst terrain cal %.3fx",
                 name, pop_metrics["full_in_scope"]["average_precision"],
                 results[name]["n_gates_pass"], results[name]["n_gates_total"],
                 rb["worst_test_stratum_ratio"])

    champion_name, challenger_name = prereg["success_rule"]["baseline"], \
        prereg["success_rule"]["candidate"]
    delta_ap = (results[challenger_name]["populations"]["full_in_scope"]["average_precision"]
               - results[champion_name]["populations"]["full_in_scope"]["average_precision"])
    promoted = delta_ap > 0
    decision = (f"{challenger_name} beats {champion_name} by {delta_ap:+.4f} in-scope AP "
               f"on the locked split -- PROMOTED" if promoted else
               f"{challenger_name} did not beat {champion_name} on the locked split "
               f"({delta_ap:+.4f} in-scope AP) -- {champion_name} STAYS the release "
               f"champion, per PREREGISTRATION_V3's pre-stated rule")
    log.info("=" * 78)
    log.info(decision)
    log.info("=" * 78)

    out = {
        "opened_utc": pd.Timestamp.now(tz="UTC").isoformat(), "git_sha": git_sha(),
        "prereg": prereg, "results": results,
        "delta_in_scope_AP_candidate_minus_baseline": delta_ap, "decision": decision,
        "promoted": promoted,
    }
    (OUT_DIR / "FINAL_TEST_V3_RESULTS.json").write_text(json.dumps(out, indent=2, default=float))


if __name__ == "__main__":
    import sys
    main(sys.argv[1] if len(sys.argv) > 1 else None)
