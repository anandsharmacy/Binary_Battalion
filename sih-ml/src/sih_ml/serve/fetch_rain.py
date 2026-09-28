"""Rainfall feed adapter — writes the long CSV that `sih_ml.serve.feed` ingests.

    python -m sih_ml.serve.fetch_rain --day 2026-09-27 --out incoming/rain_2026-09-27.csv

Scoring DAY needs rainfall up to DAY-1 (HORIZON_DAYS = 1). This fetches every day from
the store's `rain_last`+1 through DAY-1, so a stale store backfills itself in one run
and feed.py's no-gap check passes. Nothing to fetch -> no file, exit 0.

Source: Open-Meteo archive API (free, no key), daily `precipitation_sum` at each feature
store cell centre (cell_id = "<lat>_<lon>"). Open-Meteo is reanalysis/NWP-based, not
satellite like the CHIRPS the model was trained on: that is the distribution shift
feed.py's docstring warns about; batch.py's per-month drift check will show it.

Exit codes: 0 ok | 3 rainfall not available yet (network error or null values; the
systemd timer retries hourly) — same contract as batch.py.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

import pandas as pd

URL = "https://archive-api.open-meteo.com/v1/archive"
CHUNK = 50  # locations per request; keeps the URL short


class NotAvailable(Exception):
    pass


def to_long(payload: list[dict], cells: list[str]) -> pd.DataFrame:
    """Open-Meteo multi-location response (same order as `cells`) -> date,cell_id,precip_mm."""
    rows = []
    for cell, loc in zip(cells, payload, strict=True):
        d = loc["daily"]
        for day, mm in zip(d["time"], d["precipitation_sum"], strict=True):
            if mm is None:
                raise NotAvailable(f"no value yet for {cell} on {day}")
            rows.append((day, cell, float(mm)))
    return pd.DataFrame(rows, columns=["date", "cell_id", "precip_mm"])


def fetch_open_meteo(cells: list[str], start: str, end: str) -> pd.DataFrame:
    parts = []
    for i in range(0, len(cells), CHUNK):
        chunk = cells[i:i + CHUNK]
        lats, lons = zip(*(c.split("_") for c in chunk))
        q = (f"{URL}?latitude={','.join(lats)}&longitude={','.join(lons)}"
             f"&daily=precipitation_sum&timezone=GMT&start_date={start}&end_date={end}")
        try:
            with urllib.request.urlopen(q, timeout=60) as r:
                payload = json.load(r)
        except (urllib.error.URLError, TimeoutError) as e:
            raise NotAvailable(f"Open-Meteo request failed: {e}") from e
        parts.append(to_long(payload if isinstance(payload, list) else [payload], chunk))
    return pd.concat(parts, ignore_index=True)


# ponytail: Open-Meteo only. For GPM IMERG Late (NASA Earthdata login, 0.1 deg -> regrid
# to these cells) or IMD gridded, add a fetch_<source>(cells, start, end) returning the same
# date,cell_id,precip_mm frame and select it via SIH_RAIN_SOURCE. Nothing else changes.
SOURCES = {"open-meteo": fetch_open_meteo}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--day", required=True, help="scoring date; fetches through DAY-1")
    ap.add_argument("--out", required=True)
    ap.add_argument("--store", default=os.environ.get("SIH_STORE", "deploy/featurestore"))
    ap.add_argument("--source", default=os.environ.get("SIH_RAIN_SOURCE", "open-meteo"),
                    choices=sorted(SOURCES))
    a = ap.parse_args(argv)
    man = json.loads((Path(a.store) / "manifest.json").read_text())
    start = pd.Timestamp(man["rain_last"]) + pd.Timedelta(days=1)
    end = pd.Timestamp(a.day) - pd.Timedelta(days=1)
    if start > end:
        print(json.dumps({"fetched_days": 0, "rain_last": man["rain_last"]}))
        return 0
    try:
        df = SOURCES[a.source](man["cell_ids"], str(start.date()), str(end.date()))
    except NotAvailable as e:
        print(f"rainfall not available: {e}", file=sys.stderr)
        return 3
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    tmp = out.with_suffix(".tmp")
    df.to_csv(tmp, index=False)
    os.replace(tmp, out)
    print(json.dumps({"source": a.source, "from": str(start.date()), "to": str(end.date()),
                      "rows": len(df), "out": str(out)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
