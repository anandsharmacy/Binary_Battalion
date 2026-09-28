"""Phase E — a real capacity-vs-precision lookup, built from two DIFFERENT,
DELIBERATELY UNJOINED populations, each honestly labeled:

  * alert VOLUME at a threshold: scored on the REAL, full 309,042-segment corridor for
    3 representative real historical dates (dry / moderate-monsoon / heavy-monsoon,
    picked from actual rainfall percentiles, not fabricated). No case-control sampling
    anywhere in this path -- it reuses the same serving code (FeatureStore, Predictor)
    that will score a real day in production.
  * PRECISION/RECALL at that same threshold: read off `final_v2`'s dev out-of-fold
    scores, same as every other gate in this project. This population is case-control
    constructed (dev base rate 8.56%) against a real corridor base rate estimated at
    ~8.27e-8 per segment-day (172 events / 18.4 years / 309,042 segments) -- roughly a
    MILLION-fold mismatch. Neither `case_control_negative` nor `hard_negative_matched`
    is a random sample of the true negative population (both are deliberately
    stratified -- see labels/build_labels.py::build_negatives), so there is no cheap
    reweighting fix. These numbers are the curated-evaluation-population precision,
    NOT a real-world estimate -- do not present them as one.

This does not change gate G2's pass/fail. Its threshold's provenance defect (see
GATE_REMEDIATION_PLAN.md Phase E) stays documented as before; this table is what to
read once a real daily review capacity is agreed, or once a real precision pilot
exists to replace the dev-population column.

    python -m sih_ml.final.capacity [conf/improve_config.yaml]
"""
from __future__ import annotations

import json
import tempfile
from pathlib import Path

import numpy as np
import pandas as pd

from sih_ml.features.rainfall import build_cell_series
from sih_ml.improve import candidate as C
from sih_ml.improve.features import LocalRainPercentiles, coverage_mask
from sih_ml.models import calibration as Cal
from sih_ml.models.dataset import load_data
from sih_ml.serve.bundle import Bundle, build_bundle
from sih_ml.serve.featurestore import FeatureStore, feature_groups
from sih_ml.serve.monitor import rainfall_reference
from sih_ml.serve.predictor import Predictor
from sih_ml.utils.common import REPO_ROOT, get_logger, load_config, resolve, set_seed

log = get_logger("final.capacity")

OUT_DIR = REPO_ROOT / "reports" / "final"
STEEP_SLOPE_DEG = 10.0
FINAL_V2_FROZEN_THRESHOLD = 0.027149321266968326   # PREREGISTRATION_V2.json, FN:FP=20 era


def _fit_final_v2(data, cfg):
    reg = json.loads((REPO_ROOT / "models" / "registry.json").read_text())
    state = next(v["state"] for v in reg["versions"] if v["version"] == "final_v2")
    ic = cfg.improve
    coverage = coverage_mask(data, cfg)
    pctl = LocalRainPercentiles(cfg)
    cand = C.build_candidate(state, "final_v2_capacity", data, cfg,
                             coverage=coverage, pctl=pctl)
    res = C.run(cand, list(ic.folds), list(ic.seeds), keep_models=False)
    # final_v2's registry per_seed_AP predates the P0 rebuild (no data_sha16 recorded,
    # per Phase C) and is not expected to match here -- this IS the current-panel number.
    log.info("final_v2 reconstructed on the current panel: mean AP %.4f", res["mean_AP"])
    dev = np.where(data.dev_mask() & cand.train_mask)[0]
    members = [C._fit_member(cand, dev, 0, int(cfg.seed), j)[0]
              for j in range(int(state["bag"]))]
    model = members[0] if len(members) == 1 else C.BaggedModel(members)
    return cand, res, model


def _build_temp_bundle(cand, res: dict, model, tmp: Path, pcfg) -> Bundle:
    """Reuse the tested build_bundle()/Bundle.load() path instead of hand-rolling
    schema construction -- LGBMBaseline.save() already writes model.meta.json in the
    shape build_bundle() expects."""
    model_dir, bundle_dir = tmp / "model", tmp / "bundle"
    model_dir.mkdir(parents=True)
    model.save(model_dir / "model.txt")

    bins = [0.0, 2.5, 10.0, 20.0, 90.0]
    (model_dir / "model_card.json").write_text(json.dumps(
        {"version": "final_v2_capacity", "config_sha256_16": "capacity-analysis-only",
         "lineage": [], "status": "reconstructed for Phase E capacity analysis only"}))

    # OOF for the pooled/per-slope calibrators build_bundle() reads off disk.
    from sih_ml.optimize import calibrate as cal_mod
    oof = res["oof"][next(iter(res["oof"]))]
    strata = cal_mod.slope_stratum(cand.data, bins)
    m = np.isfinite(oof)
    pooled, per = Cal.fit_stratified(cand.data.y[m], oof[m], strata[m])
    pooled.save(model_dir / "calibrator_pooled.pkl")
    for s, c in per.items():
        c.save(model_dir / f"calibrator_slope_{s}.pkl")

    pcfg_chirps = resolve(pcfg, pcfg.paths.chirps_csv)
    series, _ = build_cell_series(pcfg_chirps)
    reference = rainfall_reference(series)
    policy = {"alert_probability_threshold": FINAL_V2_FROZEN_THRESHOLD,
             "steep_slope_deg": STEEP_SLOPE_DEG,
             "note": "capacity-analysis bundle -- not for serving"}
    build_bundle(model_dir, bundle_dir, policy=policy, reference=reference,
                feature_groups=feature_groups(cand.data.features), calibration_bins=bins)
    return Bundle.load(bundle_dir)


def pick_representative_dates(rain: pd.DataFrame) -> dict[str, pd.Timestamp]:
    """Real dates nearest the 10th/50th/90th percentile of corridor-mean 7-day
    rainfall over the full record -- dry / moderate-monsoon / heavy-monsoon, not
    fabricated."""
    mean7 = rain.rolling(7).sum().mean(axis=1).dropna()
    out = {}
    for name, q in (("dry", 0.10), ("moderate_monsoon", 0.50), ("heavy_monsoon", 0.90)):
        target = mean7.quantile(q)
        out[name] = pd.Timestamp((mean7 - target).abs().idxmin())
    return out


def real_corridor_sweep(bundle: Bundle, store: FeatureStore,
                        dates: dict[str, pd.Timestamp], thresholds: list[float]) -> pd.DataFrame:
    predictor = Predictor(bundle)
    steep = np.nan_to_num(store.slope, nan=0.0) >= STEEP_SLOPE_DEG
    rows = []
    for name, date in dates.items():
        raw = predictor.raw(store.matrix(date))
        for t in thresholds:
            hit = raw >= t
            rows.append({"date_kind": name, "date": str(date.date()), "threshold": t,
                        "alerts_per_day": int((hit & ~steep).sum()),
                        "reviews_per_day": int((hit & steep).sum())})
    return pd.DataFrame(rows)


def dev_precision_recall(y: np.ndarray, oof: np.ndarray, thresholds: list[float]) -> pd.DataFrame:
    m = np.isfinite(oof)
    y, oof = y[m], oof[m]
    rows = []
    for t in thresholds:
        yhat = oof >= t
        tp = int((yhat & (y == 1)).sum())
        fp = int((yhat & (y == 0)).sum())
        fn = int((~yhat & (y == 1)).sum())
        prec = tp / max(1, tp + fp)
        rec = tp / max(1, tp + fn)
        rows.append({"threshold": t, "dev_precision": prec, "dev_recall": rec,
                    "dev_alerts_per_1000_rows": 1000 * (tp + fp) / len(y)})
    return pd.DataFrame(rows)


def main(config_path: str | None = None) -> None:
    cfg_path = Path(config_path) if config_path else REPO_ROOT / "conf" / "improve_config.yaml"
    data, cfg = load_data(cfg_path)
    set_seed(cfg.seed)
    OUT_DIR.mkdir(parents=True, exist_ok=True)

    cand, res, model = _fit_final_v2(data, cfg)

    thresholds = sorted({FINAL_V2_FROZEN_THRESHOLD, 0.01, 0.02, 0.03, 0.05, 0.08, 0.15})

    pcfg = load_config()
    with tempfile.TemporaryDirectory() as tmp:
        bundle = _build_temp_bundle(cand, res, model, Path(tmp), pcfg)
        store = FeatureStore.build(bundle.schema, pcfg)
        dates = pick_representative_dates(store.rain)
        log.info("representative dates: %s",
                 {k: str(v.date()) for k, v in dates.items()})
        volume = real_corridor_sweep(bundle, store, dates, thresholds)

    seed0 = list(cfg.improve.seeds)[0]
    dev = dev_precision_recall(cand.data.y, res["oof"][seed0], thresholds)

    vol_wide = volume.pivot(index="threshold", columns="date_kind",
                            values=["alerts_per_day", "reviews_per_day"])
    vol_wide.columns = [f"{a}_{b}" for a, b in vol_wide.columns]
    table = vol_wide.reset_index().merge(dev, on="threshold", how="outer").sort_values("threshold")
    table.to_csv(OUT_DIR / "PHASE_E_CAPACITY_THRESHOLD.csv", index=False)

    log.info("=" * 78)
    log.info("wrote %s -- %d threshold rows, dates %s",
             OUT_DIR / "PHASE_E_CAPACITY_THRESHOLD.csv", len(table),
             {k: str(v.date()) for k, v in dates.items()})
    log.info("REMINDER: alerts/reviews columns are real-corridor counts; dev_precision/"
             "dev_recall are curated-evaluation-population numbers, NOT real-world -- "
             "see this module's docstring.")
    log.info("=" * 78)


if __name__ == "__main__":
    import sys
    main(sys.argv[1] if len(sys.argv) > 1 else None)
