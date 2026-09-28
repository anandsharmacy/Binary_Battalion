"""Phase D serving hook: refit/load round-trip, and Predictor.score's backward
compatibility. Does NOT depend on a real built bundle (deploy/bundles/current) --
tests the new logic in isolation instead of rebuilding the whole deploy pipeline."""
import json

import numpy as np
import pandas as pd
import pytest

from sih_ml.serve.bundle import Calibration, IsotonicTable
from sih_ml.serve.local_calibration import LocalCalibration, refit
from sih_ml.serve.predictor import Predictor

IDENTITY_GLOBAL = Calibration(bins=[0.0, 90.0], pooled=IsotonicTable(np.array([0.0, 1.0]),
                                                                     np.array([0.0, 1.0])),
                              strata={})


def _synthetic_log(tmp_path, region_rows: dict) -> str:
    """region_rows: {region_id: (n, pos_rate)}."""
    rng = np.random.default_rng(0)
    frames = []
    for region, (n, pos_rate) in region_rows.items():
        raw = rng.uniform(0.05, 0.95, n)
        y = (rng.uniform(0, 1, n) < pos_rate).astype(int)
        frames.append(pd.DataFrame({"segment_id": [f"S{i}" for i in range(n)],
                                    "date": "2025-01-01", "region_id": region,
                                    "raw_score": raw, "target": y}))
    path = tmp_path / "log.csv"
    pd.concat(frames).to_csv(path, index=False)
    return str(path)


def test_load_returns_none_when_absent(tmp_path):
    assert LocalCalibration.load(tmp_path) is None


def test_refit_load_round_trip_and_missing_column_refused(tmp_path):
    log = _synthetic_log(tmp_path, {"R1": (200, 0.3), "R2": (5, 0.2)})
    manifest = refit(log, tmp_path)
    # R1 has enough history for isotonic; R2 (n=5) is too sparse for even the
    # sigmoid-shift fallback (min_n=10) and must be absent, not crash.
    assert manifest["regions"].get("R1") == "isotonic"
    assert "R2" not in manifest["regions"]

    lc = LocalCalibration.load(tmp_path)
    assert lc is not None
    assert set(lc.regions) == {"R1"}

    bad = tmp_path / "bad.csv"
    pd.DataFrame({"segment_id": ["a"], "region_id": ["R1"]}).to_csv(bad, index=False)
    with pytest.raises(ValueError):
        refit(bad, tmp_path)


def test_local_override_applies_only_to_its_region():
    log_regions = {"R1": (200, 0.4)}   # observed rate far from raw score's own mean
    import tempfile
    from pathlib import Path
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        log = _synthetic_log(d, log_regions)
        refit(log, d)
        lc = LocalCalibration.load(d)

    raw = np.array([0.1, 0.5, 0.9])
    region_id = np.array(["R1", "R1", "UNSEEN_REGION"])
    out = lc(raw, slope=np.zeros(3), region_id=region_id, global_calibration=IDENTITY_GLOBAL)
    # R1 rows go through R1's own fitted calibrator, not the identity global one
    assert not np.allclose(out[:2], raw[:2])
    # the unseen region has no local calibrator and must fall back to the global one
    assert np.isclose(out[2], IDENTITY_GLOBAL(raw[2:3], np.zeros(1))[0])


class _FakeBooster:
    def predict(self, X, num_threads=0):
        return np.asarray(X, float).ravel()


class _FakeBundle:
    def __init__(self, local_calibration=None, segment_regions=None):
        self.booster = _FakeBooster()
        self.calibration = IDENTITY_GLOBAL
        self.policy = {"alert_probability_threshold": 0.5, "steep_slope_deg": 10.0}
        self.local_calibration = local_calibration
        self.segment_regions = segment_regions


def test_score_unchanged_when_no_segment_id_or_no_local_calibration():
    p = Predictor(_FakeBundle())
    X = np.array([0.1, 0.5, 0.9])
    slope = np.zeros(3)
    a = p.score(X, slope)
    b = p.score(X, slope, segment_id=["s0", "s1", "s2"])   # bundle has no local_calibration
    assert np.array_equal(a["p_calibrated"], b["p_calibrated"])


def test_score_uses_local_calibration_when_region_resolves(tmp_path):
    log = _synthetic_log(tmp_path, {"R1": (200, 0.4)})
    refit(log, tmp_path)
    lc = LocalCalibration.load(tmp_path)
    bundle = _FakeBundle(local_calibration=lc, segment_regions={"s0": "R1", "s1": "OTHER"})
    p = Predictor(bundle)
    X = np.array([0.3, 0.3])
    slope = np.zeros(2)
    without = IDENTITY_GLOBAL(X, slope)
    out = p.score(X, slope, segment_id=["s0", "s1"])["p_calibrated"]
    assert not np.isclose(out[0], without[0]), "s0 resolves to R1 and should use its local fit"
    assert np.isclose(out[1], without[1]), "s1 resolves to a region with no local fit"


if __name__ == "__main__":
    import tempfile
    from pathlib import Path
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            with tempfile.TemporaryDirectory() as d:
                try:
                    fn(Path(d))
                except TypeError:
                    fn()
    print("ok")
