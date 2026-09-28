"""Phase D serving hook: refit per-region calibrators from real operational history,
optionally consulted by Predictor ahead of the global (Bundle.calibration) one.

PROPOSED schema, not yet backed by real logging: `serve/monitor.py` today covers input
drift and Prometheus metrics only -- there is no per-row prediction/outcome log yet.
Whoever wires that logging should target this schema:

    segment_id, date, region_id, raw_score, target

`target` is the eventually-confirmed outcome (the same confirmation lag every label
source in this project already has -- see labels/build_labels.py). Until that log
exists, this module has nothing to read and stays dormant: Bundle.load() looks for
local_calibrators/ and simply does not find it, so every existing caller sees exactly
today's behavior. This turns serve/predictor.py's existing caveat -- "must not
[use p_calibrated] on unseen ground without local recalibration" -- into a working,
testable mechanism instead of a comment.

Same JSON-only, no-pickle discipline as bundle.py's Calibration/IsotonicTable (a
pickle executes code on load; this ships in the same image). The fit itself reuses
the exact tiered fallback validated in the Phase D backtest
(final/local_recalibration.py: isotonic when there's enough local history, a plain
sigmoid shift when there's a little, else fall back to the global calibrator).
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd

from sih_ml.serve.bundle import Calibration, IsotonicTable

MIN_N_ISOTONIC, MIN_POS_ISOTONIC = 30, 5
MIN_N_SIMPLE, MIN_POS_SIMPLE = 10, 2
REQUIRED_LOG_COLUMNS = ("region_id", "raw_score", "target")


@dataclass
class SigmoidShift:
    """y = sigmoid(a*logit(clip(raw)) + b): a plain logistic fit in logit space, exact
    and 2 floats to store, for a region with too little history for an isotonic curve."""
    a: float
    b: float

    def __call__(self, p: np.ndarray) -> np.ndarray:
        p = np.clip(np.asarray(p, float), 1e-6, 1 - 1e-6)
        z = self.a * np.log(p / (1 - p)) + self.b
        return np.clip(1.0 / (1.0 + np.exp(-z)), 1e-9, 1 - 1e-9)

    def to_json(self) -> dict:
        return {"a": self.a, "b": self.b}

    @classmethod
    def from_json(cls, d: dict) -> "SigmoidShift":
        return cls(float(d["a"]), float(d["b"]))


def _fit_region(y: np.ndarray, raw: np.ndarray):
    """Isotonic when there's enough local history, a sigmoid shift when there's a
    little, else (None, None) -- too little to say anything, the region stays on the
    global calibrator. Both classes must be present or sklearn cannot fit either."""
    n, pos = len(y), int(y.sum())
    if pos == 0 or pos == n:
        return None, None
    if n >= MIN_N_ISOTONIC and pos >= MIN_POS_ISOTONIC:
        from sklearn.isotonic import IsotonicRegression
        m = IsotonicRegression(out_of_bounds="clip", y_min=0, y_max=1)
        m.fit(np.clip(raw, 1e-6, 1 - 1e-6), y)
        return "isotonic", IsotonicTable(np.asarray(m.X_thresholds_, float),
                                         np.asarray(m.y_thresholds_, float))
    if n >= MIN_N_SIMPLE and pos >= MIN_POS_SIMPLE:
        from sklearn.linear_model import LogisticRegression
        p = np.clip(raw, 1e-6, 1 - 1e-6)
        z = np.log(p / (1 - p))
        m = LogisticRegression(C=1e6, solver="lbfgs").fit(z.reshape(-1, 1), y)
        return "sigmoid_shift", SigmoidShift(float(m.coef_[0, 0]), float(m.intercept_[0]))
    return None, None


def refit(log_path: str | Path, bundle_dir: str | Path) -> dict:
    """Read the operational log, fit one local calibrator per region with enough
    history, write bundle_dir/local_calibrators/<region>.json + a manifest. A region
    without enough history is simply absent -- Predictor falls back to the global
    calibrator for it, not an error."""
    log = pd.read_parquet(log_path) if str(log_path).endswith(".parquet") else pd.read_csv(log_path)
    missing = [c for c in REQUIRED_LOG_COLUMNS if c not in log.columns]
    if missing:
        raise ValueError(f"operational log missing {missing} -- see this module's "
                         "docstring for the proposed schema")
    bundle_dir = Path(bundle_dir)
    region_dir = bundle_dir / "local_calibrators"
    region_dir.mkdir(parents=True, exist_ok=True)
    manifest = {"fitted_utc": pd.Timestamp.now(tz="UTC").isoformat(), "regions": {}}
    for region, g in log.groupby("region_id"):
        method, cal = _fit_region(g["target"].to_numpy(int), g["raw_score"].to_numpy(float))
        if cal is None:
            continue
        (region_dir / f"{region}.json").write_text(json.dumps(
            {"method": method, "n": int(len(g)), "n_pos": int(g["target"].sum()),
             "params": cal.to_json()}))
        manifest["regions"][str(region)] = method
    (bundle_dir / "local_calibration.json").write_text(json.dumps(manifest, indent=1))
    return manifest


class LocalCalibration:
    """Optional per-region override of Bundle.calibration. Applied to the RAW score
    (the same quantity it was fit on, in refit() above) -- every row defaults to the
    global calibration, and only rows in a region with its own fitted calibrator are
    overridden."""

    def __init__(self, regions: dict):
        self.regions = regions   # region_id (str) -> callable(raw) -> p

    @classmethod
    def load(cls, bundle_dir: str | Path) -> "LocalCalibration | None":
        bundle_dir = Path(bundle_dir)
        mf_path = bundle_dir / "local_calibration.json"
        region_dir = bundle_dir / "local_calibrators"
        if not mf_path.exists() or not region_dir.exists():
            return None
        manifest = json.loads(mf_path.read_text())
        regions = {}
        for region, method in manifest["regions"].items():
            d = json.loads((region_dir / f"{region}.json").read_text())
            if method == "isotonic":
                regions[region] = IsotonicTable.from_json(d["params"])
            elif method == "sigmoid_shift":
                regions[region] = SigmoidShift.from_json(d["params"])
        return cls(regions) if regions else None

    def __call__(self, raw: np.ndarray, slope: np.ndarray, region_id: np.ndarray,
                global_calibration: Calibration) -> np.ndarray:
        out = global_calibration(raw, slope)
        region_id = np.asarray(region_id).astype(str)
        for region, cal in self.regions.items():
            m = region_id == region
            if m.any():
                out[m] = cal(raw[m])
        return out
