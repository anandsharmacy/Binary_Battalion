"""Probability calibration + base-rate (prior) correction.

The model is trained at a ~10:1 negative:positive ratio, so its raw probabilities
are inflated relative to the real world. We (1) fit isotonic/sigmoid calibration on
pooled out-of-fold predictions, then (2) shift the log-odds to a target prior.
"""
from __future__ import annotations

import json
import pickle
from pathlib import Path

import numpy as np
from sklearn.isotonic import IsotonicRegression
from sklearn.linear_model import LogisticRegression


class Calibrator:
    def __init__(self, method: str = "isotonic"):
        self.method = method
        self.model_ = None
        self.train_prior_ = None
        self.target_prior_ = None

    def fit(self, p_oof: np.ndarray, y_oof: np.ndarray,
            train_prior: float, target_prior: float | None = None):
        p_oof = np.clip(np.asarray(p_oof, float), 1e-6, 1 - 1e-6)
        y_oof = np.asarray(y_oof, int)
        if self.method == "isotonic":
            self.model_ = IsotonicRegression(out_of_bounds="clip", y_min=0, y_max=1)
            self.model_.fit(p_oof, y_oof)
        else:
            self.model_ = LogisticRegression(C=1e6, solver="lbfgs")
            self.model_.fit(_logit(p_oof).reshape(-1, 1), y_oof)
        self.train_prior_ = float(train_prior)
        self.target_prior_ = float(target_prior) if target_prior is not None else None
        return self

    def _calibrate(self, p: np.ndarray) -> np.ndarray:
        p = np.clip(np.asarray(p, float), 1e-6, 1 - 1e-6)
        if self.method == "isotonic":
            return np.clip(self.model_.predict(p), 1e-6, 1 - 1e-6)
        return self.model_.predict_proba(_logit(p).reshape(-1, 1))[:, 1]

    def transform(self, p: np.ndarray, apply_prior: bool = True) -> np.ndarray:
        q = self._calibrate(p)
        if apply_prior and self.target_prior_ is not None:
            # shift log-odds by log(pi_target/(1-pi_target)) - log(pi_train/(1-pi_train))
            shift = (_logit(self.target_prior_) - _logit(self.train_prior_))
            q = _sigmoid(_logit(q) + shift)
        return np.clip(q, 1e-9, 1 - 1e-9)

    def save(self, path: str | Path):
        path = Path(path)
        with open(path, "wb") as f:
            pickle.dump(self.model_, f)
        path.with_suffix(".json").write_text(json.dumps({
            "method": self.method,
            "train_prior": self.train_prior_,
            "target_prior": self.target_prior_,
        }, indent=2))

    @classmethod
    def load(cls, path: str | Path) -> "Calibrator":
        path = Path(path)
        meta = json.loads(path.with_suffix(".json").read_text())
        obj = cls(meta["method"])
        with open(path, "rb") as f:
            obj.model_ = pickle.load(f)
        obj.train_prior_ = meta["train_prior"]
        obj.target_prior_ = meta["target_prior"]
        return obj


def fit_stratified(y: np.ndarray, p: np.ndarray, strata: np.ndarray | None = None,
                   min_n: int = 200, min_pos: int = 20) -> tuple[Calibrator, dict]:
    """Pooled isotonic calibrator, plus one per stratum where the stratum clears
    (min_n rows, min_pos positives) -- a stratum too small to trust falls back to the
    pooled fit at apply time. `strata=None` fits pooled only (e.g. one region's own
    history, too small to slice further).

    Extracted from four call sites that each hand-rolled this (run_improve.py,
    run_remediate.py, final_test.py, final_test_v3.py) with the same thresholds --
    one fix here reaches all of them instead of a fifth copy.
    """
    y = np.asarray(y, int)
    p = np.asarray(p, float)
    pooled = Calibrator("isotonic").fit(p, y, float(y.mean()), None)
    per: dict[int, Calibrator] = {}
    if strata is not None:
        strata = np.asarray(strata)
        for s in np.unique(strata):
            sel = strata == s
            if sel.sum() >= min_n and y[sel].sum() >= min_pos:
                per[int(s)] = Calibrator("isotonic").fit(p[sel], y[sel], float(y[sel].mean()), None)
    return pooled, per


def apply_stratified(p: np.ndarray, strata: np.ndarray, pooled: Calibrator,
                     per: dict) -> np.ndarray:
    """Pooled by default; a per-stratum calibrator overrides where one was fitted."""
    out = pooled.transform(np.asarray(p, float))
    for s, c in (per or {}).items():
        sel = strata == s
        if sel.any():
            out[sel] = c.transform(np.asarray(p, float)[sel])
    return out


def _logit(p):
    p = np.clip(p, 1e-9, 1 - 1e-9)
    return np.log(p / (1 - p))


def _sigmoid(z):
    return 1.0 / (1.0 + np.exp(-z))
