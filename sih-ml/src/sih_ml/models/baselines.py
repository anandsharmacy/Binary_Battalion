"""Non-learned reference baselines. The LightGBM baseline must beat these by more
than the spatial-CV fold std to be worth anything.

Each returns a per-row score in [0, 1]-ish (monotone, not calibrated)."""
from __future__ import annotations

import numpy as np
import pandas as pd


def majority_class(X: pd.DataFrame) -> np.ndarray:
    return np.zeros(len(X))                       # predict "never disrupted"


def rainfall_threshold(X: pd.DataFrame) -> np.ndarray:
    """ID-threshold exceedance ratio — the published empirical rule, no ML.
    Uses the max of the 1/3/7-day intensity-duration ratios already in the panel."""
    cols = [c for c in ["id_ratio_1d", "id_ratio_3d", "id_ratio_7d"] if c in X]
    r = X[cols].to_numpy(float)
    r = np.nan_to_num(r, nan=0.0)
    return r.max(axis=1)


def antecedent_rain(X: pd.DataFrame) -> np.ndarray:
    return np.nan_to_num(X["rain_15d_mm"].to_numpy(float), nan=0.0)


def terrain_only(X: pd.DataFrame) -> np.ndarray:
    """Static susceptibility proxy — slope + stream proximity. Tests the terrain
    confound: if this scores nearly as well as the full model on spatial CV, the
    model is mostly learning 'is this the hills'."""
    slope = np.nan_to_num(X["slope_mean_deg"].to_numpy(float))
    smax = np.nan_to_num(X["slope_max_deg"].to_numpy(float))
    driver = np.nan_to_num(X["distance_to_nearest_river_m"].to_numpy(float), nan=3000.0)

    def z(a):
        return (a - a.mean()) / (a.std() + 1e-9)

    return z(slope) + 0.5 * z(smax) - 0.5 * z(np.log1p(driver))


def rain_x_terrain(X: pd.DataFrame) -> np.ndarray:
    return rainfall_threshold(X) * (1.0 + _minmax(terrain_only(X)))


def _minmax(a):
    a = np.asarray(a, float)
    lo, hi = np.nanmin(a), np.nanmax(a)
    return (a - lo) / (hi - lo + 1e-9)


REGISTRY = {
    "majority_class": majority_class,
    "rainfall_id_threshold": rainfall_threshold,
    "antecedent_rain_15d": antecedent_rain,
    "terrain_only": terrain_only,
    "rain_x_terrain": rain_x_terrain,
}
