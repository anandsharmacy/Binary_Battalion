"""Phase B — sub-daily rainfall intensity from the corridor ERA5 hourly record.

The question
-----------
`features/rainfall.py` bakes in the NE-Himalaya intensity-duration curve
`I = 5.8294 * D^-0.4141` (I mm/hr, D hr), but daily CHIRPS floors D at 24 h, so
`i_obs = total / 24`. A 100 mm cloudburst over 4 hours (25 mm/h, far over threshold) and
100 mm spread evenly over 24 hours (4.2 mm/h, under it) produce the IDENTICAL feature
value. The curve is TRMM-derived where cloudbursts live, D ~ 3-6 h, so it is being
evaluated two orders of magnitude outside its calibration domain. Phase A also measured
the symptom: on the 0.05 deg panel the share of missed positives on an apparently dry day
rose to 0.635, i.e. the model misses events it reads as dry at DAILY granularity.

The design
----------
Two feature groups, both derived from the SAME hourly file, so the arms differ only in
temporal granularity:

    era5_daily     ERA5 hourly summed to daily antecedent totals (1/3/7 d)
    era5_subdaily  the same record's short-duration burst maxima

Run as two separate one-change experiments, the difference isolates sub-daily
information. Adding only `era5_subdaily` would confound "sub-daily helps" with "a second
independent rainfall product helps", since the panel's existing rainfall is CHIRPS.
That confound is exactly what cost Phase A an extra campaign; `era5_daily` is the control
that removes it.

Honest caveat, recorded before any result: ERA5 is reanalysis at ~0.25 deg and is
documented to under-represent extreme orographic Himalayan rain. A NULL here is therefore
ambiguous -- sub-daily may add nothing, or ERA5 may not resolve the bursts. A POSITIVE is
strong and would justify acquiring IMERG, whose data endpoint needs an Earthdata login.

Leakage
-------
Every window ends at `date - FORECAST_HORIZON_DAYS`, the same firewall the CHIRPS
features use: the model predicts a disruption from rainfall known the day before. The
temptation to read same-day sub-daily rain is a decisive leak and is not taken.

Monotonicity
------------
All columns are non-decreasing in the underlying rainfall (a max of sums, or a positive
rescaling of one), so they carry the same monotone-increasing constraint as their daily
parents and are registered in `monotone_rainfall_features`. `recompute` is a no-op by
design: these columns are functions of the ERA5 file, not of any panel column, so there
is nothing to re-derive when the gate scales the panel's CHIRPS rainfall -- and leaving
them fixed while constrained rain rises cannot lower a score.

`id_ratio` columns are deliberately NOT emitted. For a fixed duration D,
`ratio = max_D / (D * 5.8294 * D^-0.4141)` is a constant rescaling of `max_D`, and a tree
is invariant to monotone transforms of a single feature -- it would be interpretability,
not information. The published threshold is recoverable from the maxima when reporting.
"""
from __future__ import annotations

from functools import lru_cache

import numpy as np
import pandas as pd

from sih_ml.models.dataset import Data
from sih_ml.utils.common import Config, REPO_ROOT, resolve
from sih_ml.utils.geo import nearest_cell_map

FORECAST_HORIZON_DAYS = 1
BURST_HOURS = (1, 3, 6, 12)      # where the published ID curve is actually calibrated
DAILY_WINDOWS = (1, 3, 7)        # control arm: same record, daily granularity
HOURLY_FILE = "rainfall_chirps/corridor_era5_hourly.csv.gz"
IMERG_FILE = "rainfall_chirps/corridor_imerg_cellday.parquet"


def burst_col(k: int, window_h: int) -> str:
    return f"era5_max_{k}h_in_{window_h}h"


def daily_col(w: int) -> str:
    return f"era5_rain_{w}d_mm"


def hourly_path(cfg: Config | None = None) -> str:
    """The ERA5 file is a Stage 2 input, so it lives in the pipeline config
    (conf/config.yaml), not in the model-config chain -- same as chirps_path()."""
    from sih_ml.utils.common import load_config
    pc = load_config()
    return str(resolve(pc, f"{pc.paths.data_root}/{HOURLY_FILE}"))


@lru_cache(maxsize=1)
def _load(path: str) -> tuple[pd.DataFrame, pd.DataFrame]:
    """(per-cell-day feature table, cell coordinate table).

    Reduced to one row per (cell, day) here -- there are ~129 cells and ~7.7k days, so
    the broadcast to 100k panel rows is a cheap merge rather than a per-row scan.
    """
    h = pd.read_csv(path)
    h["datetime"] = pd.to_datetime(h["datetime"])
    h["precip_mm"] = pd.to_numeric(h["precip_mm"], errors="coerce").fillna(0.0).clip(lower=0)
    cells = h[["cell_id", "latitude", "longitude"]].drop_duplicates().reset_index(drop=True)

    wide = h.pivot_table(index="datetime", columns="cell_id", values="precip_mm",
                         aggfunc="mean").sort_index().asfreq("h").fillna(0.0)
    day = wide.index.normalize()

    out = {}
    for k in BURST_HOURS:
        rk = wide.rolling(k, min_periods=1).sum()          # k-hour total ending each hour
        per_day = rk.groupby(day).max()                    # worst k-hour burst that day
        out[(k, 24)] = per_day
        # A 72 h window's worst burst is the worst of its three days'; rolling windows
        # that straddle midnight are already counted, since rk is computed hourly first.
        out[(k, 72)] = per_day.rolling(3, min_periods=1).max()
    daily_tot = wide.groupby(day).sum()
    for w in DAILY_WINDOWS:
        out[("d", w)] = daily_tot.rolling(w, min_periods=1).sum()

    frames = []
    for key, df in out.items():
        name = daily_col(key[1]) if key[0] == "d" else burst_col(key[0], key[1])
        frames.append(df.stack().rename(name))
    tab = pd.concat(frames, axis=1).reset_index()
    tab.columns = ["cutoff", "cell_id", *tab.columns[2:]]
    return tab, cells


class _SubDailyBase:
    """Merge a per-(cell, day) feature table onto the panel by (segment, cutoff date).

    Shared by the ERA5 and IMERG arms: they differ only in where the table comes from
    and what the columns are called. The merge, the leakage cutoff and the no-op
    recompute are identical, and duplicating them would be how the two arms silently
    drift apart.
    """

    tab: pd.DataFrame
    seg_cell: pd.Series
    cell_col: str = "_subdaily_cell"

    @property
    def columns(self) -> list[str]:
        raise NotImplementedError

    def add_to(self, data: Data) -> Data:
        panel = data.panel.copy()
        panel[self.cell_col] = self.seg_cell.reindex(panel["segment_id"].to_numpy()).to_numpy()
        panel["_cutoff"] = (pd.to_datetime(panel["date"]).dt.normalize()
                            - pd.Timedelta(days=FORECAST_HORIZON_DAYS))
        merged = panel.merge(self.tab[["cutoff", "cell_id", *self.columns]],
                             left_on=["_cutoff", self.cell_col],
                             right_on=["cutoff", "cell_id"], how="left")
        for c in self.columns:
            panel[c] = merged[c].to_numpy()
        new = Data(panel=panel, features=[*data.features, *self.columns],
                   categorical=data.categorical, spec=data.spec)
        if getattr(data, "scope_mask_", None) is not None:
            new.apply_scope(data.scope_mask_)
        return new

    def recompute(self, X: pd.DataFrame, panel: pd.DataFrame) -> pd.DataFrame:
        """No-op: see the module docstring. These columns are functions of a separate
        rainfall record, not of any panel column, so scaling the panel's CHIRPS
        rainfall leaves them correctly unchanged."""
        return X


class ERA5SubDaily(_SubDailyBase):
    """Adds one of the two ERA5 feature groups to a Data, keyed on (segment, date)."""

    cell_col = "_era5_cell"

    def __init__(self, cfg: Config, group: str):
        assert group in ("era5_daily", "era5_subdaily"), group
        self.group = group
        tab, cells = _load(hourly_path(cfg))
        self.tab = tab
        cent = pd.read_parquet(REPO_ROOT / "data" / "interim" / "segment_centroids.parquet")
        self.seg_cell = nearest_cell_map(cent, cells).set_index("segment_id")["cell_id"]

    @property
    def columns(self) -> list[str]:
        if self.group == "era5_daily":
            return [daily_col(w) for w in DAILY_WINDOWS]
        return [burst_col(k, wh) for wh in (24, 72) for k in BURST_HOURS]


def imerg_burst_col(k: int, window_h: int) -> str:
    return f"imerg_max_{k}h_in_{window_h}h"


def imerg_daily_col(w: int) -> str:
    return f"imerg_rain_{w}d_mm"


def imerg_path(cfg: Config | None = None) -> str:
    from sih_ml.utils.common import load_config
    pc = load_config()
    return str(resolve(pc, f"{pc.paths.data_root}/{IMERG_FILE}"))


@lru_cache(maxsize=1)
def _load_imerg(path: str) -> tuple[pd.DataFrame, pd.DataFrame]:
    """(per-cell-day feature table, cell coordinate table), already reduced.

    Unlike ERA5 -- one consolidated hourly CSV reduced here at import time -- IMERG
    arrives as 363,744 separate half-hourly granules. Reducing those on every campaign
    run would repeat ~5 minutes of I/O per candidate, and the long form would be 327M
    rows, so `data2/other_files/scripts/24_imerg_consolidate.py` does it once and this
    just reads the result. That script is also where the mm/hr -> mm conversion and the
    half-hourly window arithmetic live, verified there against the raw granules.
    """
    tab = pd.read_parquet(path)
    tab["cutoff"] = pd.to_datetime(tab["cutoff"])
    cells = tab[["cell_id", "latitude", "longitude"]].drop_duplicates().reset_index(drop=True)
    return tab, cells


class IMERGSubDaily(_SubDailyBase):
    """Adds one of the two IMERG feature groups to a Data, keyed on (segment, date).

    IMERG Final Run lags ~3.5 months, so the record ends 2025-09-30 while the panel runs
    to 2025-12-28. The 510 panel rows past that (0.497%, none of them positive) get NaN,
    which LightGBM handles natively -- and identically in both the daily and sub-daily
    arms, so it cannot bias the X8 - X7 contrast that isolates sub-daily information.
    """

    cell_col = "_imerg_cell"

    def __init__(self, cfg: Config, group: str):
        assert group in ("imerg_daily", "imerg_subdaily"), group
        self.group = group
        tab, cells = _load_imerg(imerg_path(cfg))
        self.tab = tab
        cent = pd.read_parquet(REPO_ROOT / "data" / "interim" / "segment_centroids.parquet")
        self.seg_cell = nearest_cell_map(cent, cells).set_index("segment_id")["cell_id"]

    @property
    def columns(self) -> list[str]:
        if self.group == "imerg_daily":
            return [imerg_daily_col(w) for w in DAILY_WINDOWS]
        return [imerg_burst_col(k, wh) for wh in (24, 72) for k in BURST_HOURS]
