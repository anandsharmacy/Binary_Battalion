"""The Open-Meteo adapter's CSV must pass feed.py's own validation unchanged."""
import pandas as pd
import pytest

from sih_ml.serve.feed import validate_new_days
from sih_ml.serve.fetch_rain import NotAvailable, to_long

CELLS = ["25.625_91.125", "26.125_92.375"]


def _payload(values):
    return [{"daily": {"time": ["2026-01-01", "2026-01-02"], "precipitation_sum": v}}
            for v in values]


def test_open_meteo_payload_passes_feed_validation():
    df = to_long(_payload([[0.0, 1.7], [7.6, 28.0]]), CELLS)
    wide = validate_new_days(df, CELLS, pd.Timestamp("2025-12-31"))
    assert list(wide.columns) == CELLS
    assert wide.loc["2026-01-02", "26.125_92.375"] == 28.0


def test_null_value_means_not_available():
    with pytest.raises(NotAvailable):
        to_long(_payload([[0.0, None], [7.6, 28.0]]), CELLS)
