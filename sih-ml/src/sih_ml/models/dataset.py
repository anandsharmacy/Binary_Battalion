"""Load the Stage 2 panel + folds and expose train/val index accessors.

The panel is never mutated here beyond dtype coercion. All fitting-time transforms
(imputation, encoding, scaling) live in preprocess/transformers.py and are applied
inside the CV loop only.
"""
from __future__ import annotations

import inspect
import json
import logging
from dataclasses import dataclass
from pathlib import Path

import numpy as np
import pandas as pd

from sih_ml.preprocess.transformers import load_feature_spec, model_feature_columns
from sih_ml.utils.common import REPO_ROOT, Config, load_config_with_base, resolve

log = logging.getLogger("dataset")

# Where the locked split's pre-registration and opening ledger live. conf/
# optimize_config.yaml:148 is the source of truth; load_data() stashes the resolved
# paths on the Data instance and these are the fallback for a Data built without a
# config (a derived copy from improve/, say).
DEFAULT_PREREG = REPO_ROOT / "reports" / "stage7" / "PREREGISTRATION.json"
DEFAULT_LEDGER = REPO_ROOT / "reports" / "stage7" / "TEST_SET_LEDGER.json"


@dataclass
class Data:
    panel: pd.DataFrame          # full panel joined with fold columns
    features: list[str]
    categorical: list[str]
    spec: dict

    @property
    def y(self) -> np.ndarray:
        return self.panel["target"].to_numpy(int)

    @property
    def w(self) -> np.ndarray:
        return self.panel["sample_weight"].to_numpy(float)

    def X(self, idx=None) -> pd.DataFrame:
        df = self.panel if idx is None else self.panel.iloc[idx]
        return df[self.features]

    # ---- split masks -----------------------------------------------------
    def dev_mask(self) -> np.ndarray:
        """Everything NOT in the locked final test."""
        return ~self.panel["final_test"].to_numpy(bool)

    def spatial_fold_indices(self, k: int, drop_buffer: bool = True):
        role = self.panel[f"spatial_role_f{k}"].to_numpy()
        dev = self.dev_mask()
        tr = np.where(dev & (role == "train"))[0]
        va = np.where(dev & (role == "val"))[0]
        if not drop_buffer:
            tr = np.where(dev & np.isin(role, ["train", "buffer"]))[0]
        return tr, va

    def temporal_indices(self):
        s = self.panel["temporal_split"].to_numpy()
        dev = self.dev_mask()
        return (np.where(dev & (s == "train"))[0],
                np.where(dev & (s == "val"))[0],
                np.where(dev & (s == "test"))[0])

    def loeco_groups(self) -> np.ndarray:
        return self.panel["event_cluster_id"].to_numpy()

    def final_test_mask(self) -> np.ndarray:
        """Locked-split MEMBERSHIP, for composition checks only -- unguarded.

        Asking "which rows are in the locked split" is not the same as looking at their
        answers. A leakage audit comparing segment/event/block membership across the
        boundary, or a test asserting no gold label landed there, learns nothing about
        the target and must not clutter the ledger -- if every such check logged an
        opening, the trail would stop meaning "a model saw the answers".

        Do NOT use this to read `y`, predictions, or any metric on locked rows. That is
        `final_test_index(reason=...)`, which records the access.
        """
        return self.panel["final_test"].to_numpy(bool)

    def final_test_index(self, *, reason: str) -> np.ndarray:
        """Reveal the locked test rows. THE chokepoint -- every reader routes here.

        `final_test.py` performed this ritual (refuse without pre-registration, record
        the opening) but only inside itself, so three other modules read the locked rows
        with no check and no record: Stage 9's revalidation, the Stage 8 audits and
        run_final. The consequence was measurable -- TEST_SET_LEDGER.json showed six
        openings, all under final_v1's config hash, while every final_v2 test number in
        REMEDIATION.md came from an opening the ledger never saw. A gate enforced in one
        caller is not a gate; this is the same failure mode as the Stage 9 leak, which
        survived three stages because its check was a one-off analysis.

        `reason` is required and keyword-only so the split cannot be opened absent-
        mindedly and so the ledger records intent. Note `dev_mask()` is deliberately
        NOT guarded: it EXCLUDES these rows and is on every training path.

        Openings are recorded, not prevented -- re-opening is sometimes legitimate and
        the honest response is an auditable trail, not a block that invites a bypass.
        """
        prereg_path = Path(getattr(self, "prereg_path_", None) or DEFAULT_PREREG)
        if not prereg_path.exists():
            raise RuntimeError(
                f"REFUSING to open the locked test set: {prereg_path} does not exist.\n"
                "Run `make stage7` first -- it freezes the configuration and the metric "
                "list BEFORE any test row is read. Opening the test without that file "
                "would make the number unfalsifiable."
            )
        idx = np.where(self.panel["final_test"].to_numpy(bool))[0]
        self._record_opening(reason, idx, prereg_path)
        return idx

    def _record_opening(self, reason: str, idx: np.ndarray, prereg_path: Path) -> None:
        ledger_path = Path(getattr(self, "ledger_path_", None) or DEFAULT_LEDGER)
        try:
            ledger = json.loads(ledger_path.read_text()) if ledger_path.exists() else {}
        except json.JSONDecodeError:
            ledger = {}
        openings = ledger.setdefault("openings", [])
        if openings:
            log.warning("the locked test set has already been opened %d time(s); "
                        "this read is NOT an unbiased estimate", len(openings))
        try:
            cfg_sha = json.loads(prereg_path.read_text()).get("config_sha256_16")
        except Exception:  # noqa: BLE001 - a malformed prereg must not block the record
            cfg_sha = None
        caller = inspect.stack()[2]
        openings.append({
            "utc": pd.Timestamp.now(tz="UTC").isoformat(),
            "kind": "access",
            "reason": reason,
            "caller": f"{Path(caller.filename).name}::{caller.function}",
            "config_sha256_16": cfg_sha,
            "n_rows": int(len(idx)),
            "n_positives": int(self.panel["target"].to_numpy()[idx].sum())
            if "target" in self.panel else None,
        })
        ledger_path.parent.mkdir(parents=True, exist_ok=True)
        ledger_path.write_text(json.dumps(ledger, indent=2))

    # ---- model scope (Stage 9) -------------------------------------------
    def in_scope(self) -> np.ndarray:
        """Rows the model is scoped to.

        Defaults to everything. When `scope_to_rain_attributable` is set, positives
        whose date cannot be attributed to a rainfall trigger are excluded from
        BOTH training and evaluation — they stay in `panel` so they can be reported
        as their own slice. Keeping one mask on `Data` is what stops training and
        evaluation from silently disagreeing about what the target is.
        """
        m = getattr(self, "scope_mask_", None)
        return np.ones(len(self.panel), bool) if m is None else m

    def apply_scope(self, mask: np.ndarray) -> "Data":
        self.scope_mask_ = np.asarray(mask, bool)
        return self

    def scoped(self, idx: np.ndarray) -> np.ndarray:
        """Filter an index array down to in-scope rows."""
        return idx[self.in_scope()[idx]]


def load_data(model_cfg_path: str | None = None, base_cfg_path: str | None = None) -> tuple[Data, Config]:
    mcfg = load_config_with_base(model_cfg_path or _default_model_cfg())
    panel = pd.read_parquet(resolve(mcfg, mcfg.paths.panel))
    folds = pd.read_parquet(resolve(mcfg, mcfg.paths.folds))
    fold_cols = [c for c in folds.columns if c not in ("segment_id", "date")]
    panel = panel.merge(folds[["segment_id", "date", *fold_cols]], on=["segment_id", "date"], how="left")

    spec = load_feature_spec()
    feats = model_feature_columns(spec)
    cats = spec["categorical"]
    # dtype hygiene
    for c in feats:
        if c in cats:
            panel[c] = panel[c].astype("string").fillna("__missing__").astype("category")
        else:
            panel[c] = pd.to_numeric(panel[c], errors="coerce")
    assert panel[f"spatial_role_f0"].notna().all(), "panel rows missing fold assignment"
    data = Data(panel=panel, features=feats, categorical=cats, spec=spec)
    # conf/optimize_config.yaml:148 owns these paths; keep one source of truth rather
    # than threading cfg through every final_test_index() call site. Chains that do not
    # declare `final_test` (improve_config.yaml) fall back to the module defaults.
    ft = mcfg.get("final_test", {}) or {}
    if ft.get("ledger"):
        data.ledger_path_ = REPO_ROOT / ft["ledger"]
    if ft.get("preregistration"):
        data.prereg_path_ = REPO_ROOT / ft["preregistration"]

    if bool(mcfg.get("remediate", {}).get("scope_to_rain_attributable", False)):
        from sih_ml.final.rainfall_probe import scope_mask
        m = scope_mask(data)
        data.apply_scope(m)
        n_out = int((~m).sum())
        if n_out:
            from sih_ml.utils.common import get_logger
            get_logger("dataset").info(
                "model scope: excluding %d not-rain-attributable positive rows "
                "(retained in panel for separate reporting)", n_out)
    return data, mcfg


def _default_model_cfg():
    from sih_ml.utils.common import REPO_ROOT
    return REPO_ROOT / "conf" / "model_baseline.yaml"
