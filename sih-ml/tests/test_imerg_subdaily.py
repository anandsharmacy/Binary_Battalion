"""The IMERG arm must carry the same guarantees the ERA5 arm was held to.

test_subdaily.py pins the burst arithmetic on synthetic hourly data. IMERG differs in
two ways that are easy to get silently wrong, so both are pinned here against the real
consolidated table rather than a mock:

  * units -- IMERG is mm/hr, ERA5 is mm accumulated per hour, so a half-hourly value
    needs x0.5. Getting this wrong doubles every IMERG total and makes X7/X8
    incomparable to X5/X6 without anything failing loudly.
  * window arithmetic -- half-hourly means a k-hour window is 2k steps, not k.

These are integration checks: they skip cleanly if the consolidated table has not been
built, so the suite stays green on a checkout without the 10 GB granule cache.
"""
import numpy as np
import pandas as pd
import pytest

from sih_ml.improve import subdaily as S

pytestmark = pytest.mark.skipif(
    not __import__("pathlib").Path(S.imerg_path()).exists(),
    reason="run data2/other_files/scripts/24_imerg_consolidate.py first")


@pytest.fixture(scope="module")
def tab():
    t, _cells = S._load_imerg(S.imerg_path())
    return t


def test_covers_the_expected_span_and_grid(tab):
    """IMERG Final Run lags ~3.5 months, so it stops short of the CHIRPS record end.
    That is expected, not a fetch failure -- pin it so a future short fetch is not
    mistaken for the same thing."""
    assert tab["cutoff"].min() == pd.Timestamp("2005-01-01")
    assert tab["cutoff"].max() == pd.Timestamp("2025-09-30")
    assert tab["cell_id"].nunique() == 899          # 31 lon x 29 lat at 0.1 deg
    assert tab["cutoff"].nunique() == 7578


def test_bursts_are_non_decreasing_in_duration(tab):
    """A 6 h total contains the worst 3 h, which contains the worst 1 h. If this
    inverts, the half-hourly window arithmetic (2k steps per k hours) is wrong and the
    monotone constraint registered on these columns is a lie."""
    sample = tab.sample(5000, random_state=0)
    for window in (24, 72):
        vals = [sample[S.imerg_burst_col(k, window)].to_numpy() for k in S.BURST_HOURS]
        for shorter, longer in zip(vals, vals[1:]):
            ok = np.isnan(shorter) | np.isnan(longer) | (longer >= shorter - 1e-4)
            assert ok.all(), f"{window}h window: longer burst < shorter"


def test_72h_window_contains_the_24h_window(tab):
    sample = tab.sample(5000, random_state=1)
    for k in S.BURST_HOURS:
        a = sample[S.imerg_burst_col(k, 24)].to_numpy()
        b = sample[S.imerg_burst_col(k, 72)].to_numpy()
        ok = np.isnan(a) | np.isnan(b) | (b >= a - 1e-4)
        assert ok.all(), f"{k}h: 72h max < 24h max"


def test_daily_windows_are_non_decreasing(tab):
    sample = tab.sample(5000, random_state=2)
    vals = [sample[S.imerg_daily_col(w)].to_numpy() for w in S.DAILY_WINDOWS]
    for shorter, longer in zip(vals, vals[1:]):
        ok = np.isnan(shorter) | np.isnan(longer) | (longer >= shorter - 1e-4)
        assert ok.all()


def test_units_are_mm_not_mm_per_hour(tab):
    """The x0.5 conversion has no failure mode that raises -- it just doubles
    everything. Catch it dimensionally instead.

    The bound is (previous day + this day), NOT this day alone: burst windows are
    computed on the continuous series and then reduced per day, so a window ending
    early on day D legitimately includes rain from D-1 and can exceed D's own total.
    Measured: 80,123 rows (1.18%) do exceed the same-day total, and every single one
    has previous-day rain > 0, while zero rows breach the two-day bound. An earlier
    draft of this test asserted the same-day bound and failed on exactly those rows --
    the data was right and the test was wrong.
    """
    t = tab.sort_values(["cell_id", "cutoff"])
    one_h = t[S.imerg_burst_col(1, 24)].to_numpy()
    day = t[S.imerg_daily_col(1)].to_numpy()
    prev = t.groupby("cell_id")[S.imerg_daily_col(1)].shift(1).to_numpy()
    two_day = np.nan_to_num(prev) + day
    ok = np.isnan(one_h) | np.isnan(two_day) | (two_day >= one_h - 1e-4)
    assert ok.all(), "a 1 h burst exceeds its own 2-day window -- units or windows wrong"
    assert np.nanmax(tab[S.imerg_daily_col(1)]) < 2000, "daily totals implausibly large"


def test_columns_match_what_the_feature_groups_declare(tab):
    """The group's `columns` drive both the merge and the monotone registration; a name
    that exists in one place and not the other fails as silent all-NaN features."""
    for group, expected in (("imerg_daily", [S.imerg_daily_col(w) for w in S.DAILY_WINDOWS]),
                            ("imerg_subdaily", [S.imerg_burst_col(k, wh)
                                                for wh in (24, 72) for k in S.BURST_HOURS])):
        for c in expected:
            assert c in tab.columns, f"{group} declares {c}, consolidated table lacks it"
