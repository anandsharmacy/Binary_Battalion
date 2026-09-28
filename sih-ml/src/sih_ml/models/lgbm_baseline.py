"""LightGBM baseline: a thin wrapper that fixes the fit contract (categoricals,
sample weights, per-fold scale_pos_weight, monotone rainfall constraints, early
stopping, PR-AUC as the watched metric)."""
from __future__ import annotations

import json
from pathlib import Path

import lightgbm as lgb
import numpy as np
import pandas as pd
from sklearn.metrics import average_precision_score


def _pr_auc_eval(y_pred, dataset):
    # LightGBM custom metric signature: (preds, Dataset) -> (name, value, is_higher_better)
    y_true = dataset.get_label()
    if y_true.sum() == 0:
        return "pr_auc", 0.0, True
    return "pr_auc", average_precision_score(y_true, y_pred), True


def monotone_vector(features: list[str], increasing: list[str]) -> list[int]:
    inc = set(increasing)
    return [1 if f in inc else 0 for f in features]


def periodic_checkpoint_callback(path_template: str, every: int = 50, progress_json: str | Path | None = None):
    """LightGBM callback: save the booster every `every` rounds so a crashed run
    can resume from the last checkpoint instead of from scratch. `path_template`
    takes `{iteration}`. If `progress_json` is given, also write {"iteration": n}
    there so a resume script knows the latest checkpoint without globbing."""
    def _callback(env):
        it = env.iteration + 1
        if it % every == 0:
            p = path_template.format(iteration=it)
            env.model.save_model(p)
            if progress_json:
                Path(progress_json).write_text(json.dumps({"iteration": it, "path": p}))
    _callback.order = 20
    return _callback


class LGBMBaseline:
    def __init__(self, params: dict, features: list[str], categorical: list[str],
                 monotone_increasing: list[str] | None = None):
        self.params = dict(params)
        self.features = features
        self.categorical = [c for c in categorical if c in features]
        self.monotone_increasing = monotone_increasing or []
        self.booster_: lgb.Booster | None = None
        self.best_iteration_: int | None = None
        self.raw_score_: bool = False      # True when fitted with a custom objective

    def _lgb_params(self, scale_pos_weight: float | None) -> dict:
        p = {
            "objective": self.params.get("objective", "binary"),
            "boosting_type": self.params.get("boosting_type", "gbdt"),
            "learning_rate": self.params["learning_rate"],
            "num_leaves": self.params["num_leaves"],
            "max_depth": self.params["max_depth"],
            "min_child_samples": self.params["min_child_samples"],
            "min_split_gain": self.params.get("min_split_gain", 0.0),
            "bagging_fraction": self.params["subsample"],
            "bagging_freq": self.params["subsample_freq"],
            "feature_fraction": self.params["colsample_bytree"],
            "lambda_l1": self.params["reg_alpha"],
            "lambda_l2": self.params["reg_lambda"],
            "max_bin": self.params.get("max_bin", 255),
            "verbosity": self.params.get("verbosity", -1),
            "seed": self.params.get("seed", 42),
            "deterministic": True,
            "force_row_wise": True,
        }
        if scale_pos_weight is not None:
            p["scale_pos_weight"] = float(scale_pos_weight)
        if self.monotone_increasing:
            p["monotone_constraints"] = monotone_vector(self.features, self.monotone_increasing)
        # Stage 10: per-feature bin budget (coarsening the static columns). Absent from
        # every earlier config, so models from Stages 3-9 are unchanged.
        if self.params.get("max_bin_by_feature") is not None:
            p["max_bin_by_feature"] = list(self.params["max_bin_by_feature"])
        # Which metric drives early stopping. LightGBM tracks the objective's built-in
        # metric (binary_logloss) IN ADDITION to our custom pr_auc feval, and stops on
        # whichever goes stale FIRST — so by default logloss can end training while
        # PR-AUC (the declared primary metric) is still improving. Setting metric="None"
        # disables the built-in one, leaving PR-AUC as the sole early-stopping signal.
        if self.params.get("early_stopping_metric", "both") == "pr_auc":
            p["metric"] = "None"
        return p

    def fit(self, X_tr, y_tr, w_tr, X_es, y_es, w_es, scale_pos_weight=None,
            track_train_curve=False, init_model=None, extra_callbacks=None,
            num_boost_round=None, early_stopping=True, fobj=None):
        """Fit (or resume-fit, via `init_model`) the booster.

        track_train_curve=True adds the training set itself as a second "valid"
        set purely for curve-logging (train-vs-val gap -> over/underfitting read).
        It does not affect early stopping, which always watches `es` only.
        `init_model` (a Booster or checkpoint path) resumes training — LightGBM
        appends `num_boost_round` more trees to the existing ensemble; see
        BASELINE_ANALYSIS / TRAINING_STRATEGY for the empirical resume-fidelity
        check (bagging/feature-sampling RNG restarts at the resume boundary, so
        resumed != one continuous run bit-for-bit, but is close in practice).

        `fobj` (Stage 7) swaps the built-in binary objective for a custom one, e.g.
        focal loss. With a custom objective LightGBM emits RAW MARGINS rather than
        probabilities, so `self.raw_score_` is set and `predict()` applies the
        sigmoid itself — otherwise every downstream probability, calibrator and
        threshold would silently be on the wrong scale.
        """
        dtr = lgb.Dataset(X_tr[self.features], label=y_tr, weight=w_tr,
                          categorical_feature=self.categorical, free_raw_data=False)
        des = lgb.Dataset(X_es[self.features], label=y_es, weight=w_es,
                          categorical_feature=self.categorical, reference=dtr, free_raw_data=False)
        valid_sets, valid_names = [des], ["es"]
        if track_train_curve:
            dtr_eval = lgb.Dataset(X_tr[self.features], label=y_tr, weight=w_tr,
                                   categorical_feature=self.categorical, reference=dtr,
                                   free_raw_data=False)
            valid_sets.append(dtr_eval)
            # MUST be exactly "training" — LightGBM's early-stopping callback only
            # skips a valid set whose name matches Booster._train_data_name (default
            # "training"). Naming it anything else lets the training curve influence
            # early stopping, which silently changes best_iteration.
            valid_names.append("training")

        self.eval_history_: dict = {}
        callbacks = [lgb.record_evaluation(self.eval_history_), lgb.log_evaluation(0)]
        if early_stopping:
            callbacks.insert(0, lgb.early_stopping(self.params["early_stopping_rounds"], verbose=False))
        if extra_callbacks:
            callbacks.extend(extra_callbacks)

        params = self._lgb_params(scale_pos_weight)
        if fobj is not None:
            # A custom objective replaces the built-in one entirely: LightGBM then
            # has no internal metric to track, so pr_auc (our feval) is the sole
            # early-stopping signal — which is what we want anyway.
            params["objective"] = fobj
            params["metric"] = "None"
        self.raw_score_ = fobj is not None

        self.booster_ = lgb.train(
            params,
            dtr,
            num_boost_round=num_boost_round or self.params["n_estimators"],
            valid_sets=valid_sets,
            valid_names=valid_names,
            feval=_pr_auc_eval,
            init_model=init_model,
            callbacks=callbacks,
        )
        self.best_iteration_ = (self.booster_.best_iteration if early_stopping else None) \
            or self.booster_.current_iteration()
        return self

    def predict(self, X) -> np.ndarray:
        p = self.booster_.predict(X[self.features], num_iteration=self.best_iteration_)
        if getattr(self, "raw_score_", False):
            p = 1.0 / (1.0 + np.exp(-np.clip(p, -50, 50)))
        return p

    # ---- persistence ----
    def save(self, path: str | Path):
        path = Path(path)
        self.booster_.save_model(str(path), num_iteration=self.best_iteration_)
        path.with_suffix(".meta.json").write_text(json.dumps({
            "best_iteration": self.best_iteration_,
            "features": self.features,
            "categorical": self.categorical,
            "params": self.params,
            "raw_score": bool(getattr(self, "raw_score_", False)),
            "monotone_increasing": self.monotone_increasing,
        }, indent=2))

    @classmethod
    def load(cls, path: str | Path) -> "LGBMBaseline":
        path = Path(path)
        meta = json.loads(path.with_suffix(".meta.json").read_text())
        obj = cls(meta["params"], meta["features"], meta["categorical"],
                  meta.get("monotone_increasing"))
        obj.booster_ = lgb.Booster(model_file=str(path))
        obj.best_iteration_ = meta["best_iteration"]
        obj.raw_score_ = bool(meta.get("raw_score", False))
        return obj

    def feature_importance(self) -> pd.DataFrame:
        return pd.DataFrame({
            "feature": self.features,
            "gain": self.booster_.feature_importance("gain"),
            "split": self.booster_.feature_importance("split"),
        }).sort_values("gain", ascending=False)
