"""Phase B burst features: the rolling/groupby reduction must mean what it claims.

The whole point of these columns is that a short intense burst and the same total spread
flat across a day look IDENTICAL to the daily features but different here. That is
checked directly, against hand-computed values.
"""
import gzip

import pandas as pd
import pytest

from sih_ml.improve import subdaily as S


def _write(tmp_path, rows):
    p = tmp_path / "hourly.csv.gz"
    with gzip.open(p, "wt", newline="") as f:
        f.write("cell_id,latitude,longitude,datetime,precip_mm\n")
        for t, v in rows:
            f.write(f"C1,26.0,88.0,{t},{v}\n")
    return str(p)


@pytest.fixture
def table(tmp_path):
    """Day 1 flat, day 2 one sharp burst, day 3 dry -- same 2-day total, different shape."""
    rows = []
    for h in range(24):                       # day 1: 48 mm spread evenly, 2 mm/h
        rows.append((f"2020-06-01T{h:02d}:00", 2.0))
    for h in range(24):                       # day 2: 48 mm, all inside hours 10-11
        v = {10: 20.0, 11: 28.0}.get(h, 0.0)
        rows.append((f"2020-06-02T{h:02d}:00", v))
    for h in range(24):
        rows.append((f"2020-06-03T{h:02d}:00", 0.0))
    S._load.cache_clear()
    tab, cells = S._load(_write(tmp_path, rows))
    S._load.cache_clear()
    return tab.set_index("cutoff")


def test_daily_totals_cannot_tell_the_two_days_apart(table):
    """The premise: on the daily view these days are identical."""
    d1 = table.loc[pd.Timestamp("2020-06-01"), S.daily_col(1)]
    d2 = table.loc[pd.Timestamp("2020-06-02"), S.daily_col(1)]
    assert d1 == pytest.approx(48.0) and d2 == pytest.approx(48.0)


def test_burst_columns_do_tell_them_apart(table):
    """...and the sub-daily view separates them, which is the whole hypothesis."""
    flat = table.loc[pd.Timestamp("2020-06-01")]
    burst = table.loc[pd.Timestamp("2020-06-02")]
    assert flat[S.burst_col(1, 24)] == pytest.approx(2.0)     # 2 mm in the worst hour
    assert burst[S.burst_col(1, 24)] == pytest.approx(28.0)   # the 28 mm hour
    assert flat[S.burst_col(3, 24)] == pytest.approx(6.0)     # 3 x 2 mm
    assert burst[S.burst_col(3, 24)] == pytest.approx(48.0)   # 20 + 28 inside 3 h
    assert burst[S.burst_col(1, 24)] > 10 * flat[S.burst_col(1, 24)]


def test_72h_window_is_the_worst_of_the_three_days(table):
    """Day 3 is dry, so its 72 h burst must still see day 2's spike."""
    dry = table.loc[pd.Timestamp("2020-06-03")]
    assert dry[S.burst_col(1, 24)] == pytest.approx(0.0)
    assert dry[S.burst_col(1, 72)] == pytest.approx(28.0)
    assert dry[S.daily_col(1)] == pytest.approx(0.0)
    assert dry[S.daily_col(3)] == pytest.approx(96.0)


def test_burst_is_never_below_the_shorter_burst_it_contains(table):
    """A 6 h total includes the worst 3 h, which includes the worst 1 h -- so the
    columns must be non-decreasing in duration. If this inverts, the rolling windows
    are misaligned and the monotone constraint registered on them is a lie."""
    for day in ("2020-06-01", "2020-06-02"):
        r = table.loc[pd.Timestamp(day)]
        vals = [r[S.burst_col(k, 24)] for k in S.BURST_HOURS]
        assert vals == sorted(vals), (day, vals)
