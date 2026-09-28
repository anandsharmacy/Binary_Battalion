"""fit_stratified/apply_stratified: the shared calibrator-fit primitive extracted from
four call sites (run_improve.py, run_remediate.py, final_test.py, final_test_v3.py).
The smallest thing that fails if the min_n/min_pos fallback breaks."""
import numpy as np

from sih_ml.models.calibration import apply_stratified, fit_stratified

rng = np.random.default_rng(0)


def _synthetic(n, pos_rate):
    p = rng.uniform(0, 1, n)
    y = (rng.uniform(0, 1, n) < pos_rate).astype(int)
    return p, y


def test_strata_none_fits_pooled_only():
    p, y = _synthetic(500, 0.1)
    pooled, per = fit_stratified(y, p, strata=None)
    assert per == {}
    assert np.array_equal(apply_stratified(p, np.zeros(500), pooled, per), pooled.transform(p))


def test_stratum_below_threshold_falls_back_to_pooled():
    # stratum 0: clears (min_n=200, min_pos=20); stratum 1: too small, must fall back.
    p0, y0 = _synthetic(300, 0.15)          # ~45 positives
    p1, y1 = _synthetic(50, 0.1)            # ~5 positives -- below min_pos=20
    p = np.concatenate([p0, p1])
    y = np.concatenate([y0, y1])
    strata = np.concatenate([np.zeros(300, int), np.ones(50, int)])

    pooled, per = fit_stratified(y, p, strata, min_n=200, min_pos=20)
    assert 0 in per
    assert 1 not in per, "stratum 1 has too few positives and must fall back to pooled"

    out = apply_stratified(p, strata, pooled, per)
    # stratum 1 rows go through the pooled calibrator, not a (nonexistent) per-stratum one
    assert np.array_equal(out[strata == 1], pooled.transform(p[strata == 1]))
    # stratum 0 rows use its own calibrator, not the pooled one
    assert np.array_equal(out[strata == 0], per[0].transform(p[strata == 0]))


def test_every_stratum_above_threshold_gets_its_own_calibrator():
    p0, y0 = _synthetic(250, 0.2)
    p1, y1 = _synthetic(250, 0.2)
    p = np.concatenate([p0, p1])
    y = np.concatenate([y0, y1])
    strata = np.concatenate([np.zeros(250, int), np.ones(250, int)])

    pooled, per = fit_stratified(y, p, strata, min_n=200, min_pos=20)
    assert set(per) == {0, 1}


if __name__ == "__main__":
    test_strata_none_fits_pooled_only()
    test_stratum_below_threshold_falls_back_to_pooled()
    test_every_stratum_above_threshold_gets_its_own_calibrator()
    print("ok")
