"""spatial_block_id lookup — not a model feature, so it is not carried into the
model panel; read it straight from folds_v1 and join by segment_id+date.

Shared by final_test_v3.py (Phase C: which locked-test block is which) and
local_recalibration.py (Phase D: per-block chronological backtest) since both need
the same join.
"""
from __future__ import annotations

import numpy as np
import pandas as pd

from sih_ml.utils.common import Config, resolve


def block_ids(cfg: Config) -> pd.DataFrame:
    """segment_id, date, spatial_block_id -- one row per panel row's fold assignment."""
    return pd.read_parquet(resolve(cfg, cfg.paths.folds),
                           columns=["segment_id", "date", "spatial_block_id"])


def block_of_row(data, cfg: Config) -> np.ndarray:
    """spatial_block_id aligned 1:1 to `data.panel`'s row order."""
    blocks = block_ids(cfg)
    key_panel = pd.MultiIndex.from_frame(data.panel[["segment_id", "date"]])
    key_blocks = pd.MultiIndex.from_frame(blocks[["segment_id", "date"]])
    return (pd.Series(blocks["spatial_block_id"].to_numpy(), index=key_blocks)
           .reindex(key_panel).to_numpy())
