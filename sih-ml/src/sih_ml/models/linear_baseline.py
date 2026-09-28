"""Logistic-regression baseline — the linear reference the GBDT must beat.

Uses the in-fold ColumnTransformer (median-impute + scale + one-hot) from
preprocess/transformers.py so nothing leaks across folds. Class imbalance is
handled with class_weight='balanced'; label-noise weights are passed through.
"""
from __future__ import annotations

import numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.pipeline import Pipeline

from sih_ml.preprocess.transformers import build_linear_pipeline


class LinearBaseline:
    def __init__(self, spec: dict, C: float = 0.1, seed: int = 42):
        self.spec = spec
        self.features = (spec["numeric"] + spec["cyclic"] + spec["flag"] + spec["categorical"])
        self.pipe = Pipeline([
            ("prep", build_linear_pipeline(spec)),
            ("clf", LogisticRegression(C=C, class_weight="balanced", max_iter=2000,
                                       solver="lbfgs", random_state=seed)),
        ])

    def fit(self, X, y, w=None):
        self.pipe.fit(X[self.features], y, clf__sample_weight=w)
        return self

    def predict(self, X) -> np.ndarray:
        return self.pipe.predict_proba(X[self.features])[:, 1]
