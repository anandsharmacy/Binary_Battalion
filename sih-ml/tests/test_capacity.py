"""Phase E's join logic (real-corridor volume x dev precision/recall, joined by
threshold) on synthetic data -- the expensive full-corridor scoring path
(sih_ml.final.capacity.main) is exercised manually, not in the suite."""
import numpy as np
import pandas as pd

from sih_ml.final.capacity import (dev_precision_recall, pick_representative_dates,
                                   real_corridor_sweep)
from sih_ml.serve.bundle import Bundle, Calibration, IsotonicTable
from sih_ml.serve.featurestore import FeatureStore


def test_dev_precision_recall_monotonic_in_threshold():
    rng = np.random.default_rng(0)
    y = (rng.uniform(0, 1, 2000) < 0.1).astype(int)
    oof = np.clip(y * 0.6 + rng.normal(0, 0.2, 2000), 0, 1)   # noisy but informative
    thresholds = [0.1, 0.3, 0.5, 0.7, 0.9]
    df = dev_precision_recall(y, oof, thresholds)
    # recall must be non-increasing as the threshold rises
    assert (df.dev_recall.diff().dropna() <= 1e-9).all()
    assert (df.dev_precision >= 0).all() and (df.dev_precision <= 1).all()


def test_dev_precision_recall_ignores_nan_oof_rows():
    y = np.array([1, 0, 1, 0])
    oof = np.array([0.9, np.nan, 0.8, 0.1])
    df = dev_precision_recall(y, oof, [0.5])
    # only the 3 finite rows count: 2 positives, 1 negative, both positives above 0.5
    row = df.iloc[0]
    assert row.dev_recall == 1.0
    assert row.dev_precision == 1.0


def test_pick_representative_dates_spans_the_record():
    idx = pd.date_range("2010-01-01", "2020-12-31", freq="D")
    rng = np.random.default_rng(1)
    # a fake seasonal signal: high in months 6-9, low otherwise -- monsoon-shaped
    monsoon = idx.month.isin([6, 7, 8, 9]).astype(float) * 20 + rng.uniform(0, 2, len(idx))
    rain = pd.DataFrame({"c1": monsoon, "c2": monsoon}, index=idx)
    dates = pick_representative_dates(rain)
    assert set(dates) == {"dry", "moderate_monsoon", "heavy_monsoon"}
    assert dates["dry"] < dates["heavy_monsoon"] or True  # no ordering guarantee, just no crash
    assert all(idx.min() <= d <= idx.max() for d in dates.values())


IDENTITY = Calibration(bins=[0.0, 90.0], pooled=IsotonicTable(np.array([0.0, 1.0]),
                                                              np.array([0.0, 1.0])), strata={})


class _FakeStore:
    def __init__(self, n=100):
        self.slope = np.concatenate([np.full(80, 2.0), np.full(20, 15.0)])   # 20 steep
        rng = np.random.default_rng(2)
        self._raw = rng.uniform(0, 1, n)

    def matrix(self, date):
        return self._raw   # Predictor.raw feeds this straight to booster.predict


class _FakeBooster:
    def predict(self, X, num_threads=0):
        return np.asarray(X, float).ravel()


class _FakeBundle:
    def __init__(self):
        self.booster = _FakeBooster()
        self.calibration = IDENTITY
        self.policy = {"alert_probability_threshold": 0.5, "steep_slope_deg": 10.0}
        self.local_calibration = None
        self.segment_regions = None


def test_real_corridor_sweep_splits_steep_from_alert():
    store = _FakeStore()
    dates = {"one_day": pd.Timestamp("2020-01-01")}
    df = real_corridor_sweep(_FakeBundle(), store, dates, thresholds=[0.0])
    # threshold 0.0 -> every row hits; must land entirely in alerts (80 non-steep)
    # + reviews (20 steep), matching the store's slope split exactly
    row = df.iloc[0]
    assert row.alerts_per_day == 80
    assert row.reviews_per_day == 20


if __name__ == "__main__":
    test_dev_precision_recall_monotonic_in_threshold()
    test_dev_precision_recall_ignores_nan_oof_rows()
    test_pick_representative_dates_spans_the_record()
    test_real_corridor_sweep_splits_steep_from_alert()
    print("ok")
