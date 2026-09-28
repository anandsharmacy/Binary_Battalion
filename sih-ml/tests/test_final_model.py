"""Stage 8 contract tests — the frozen artifact, its audit trail, and the honesty
of the probes used to validate it."""
from __future__ import annotations

import ast
import hashlib
import importlib
import inspect
import json

import numpy as np
import pandas as pd
import pytest

from sih_ml.final import audit, robustness
from sih_ml.models.dataset import load_data
from sih_ml.utils.common import REPO_ROOT

CFG = REPO_ROOT / "conf" / "optimize_config.yaml"
S7 = REPO_ROOT / "reports" / "stage7"
S8 = REPO_ROOT / "reports" / "stage8"


@pytest.fixture(scope="module")
def dc():
    return load_data(CFG)


# --------------------------------------------------------------------------- #
# The audit trail
# --------------------------------------------------------------------------- #
def test_every_decision_grade_opening_is_disclosed():
    """Openings that could have influenced a choice must be DISCLOSED, not merely few.

    This replaces a test asserting there is exactly one decision opening. That was
    false: Stage 9 opened the split again to produce every final_v2 number (AP 0.2146,
    precision@100 0.290, steep ROC 0.630) and the deployment recommendation that
    followed. It passed only because Stage 9 bypassed the ledger entirely, so the
    second opening was invisible -- the same shape as the Stage 9 leak, where a test
    asserted the buggy behaviour. Counting openings is worthless if an opening can go
    unrecorded; what matters is that the bias is admitted where the numbers are read.
    """
    p = S7 / "TEST_SET_LEDGER.json"
    if not p.exists():
        pytest.skip("locked test never opened")
    openings = json.loads(p.read_text())["openings"]
    for o in openings:
        assert o.get("kind", "decision") in (
            "decision", "report", "access", "retrospective"), o.get("kind")
    # "report" re-renders prose from saved JSON and cannot influence a choice.
    decisions = [o for o in openings if o.get("kind", "decision") != "report"]
    assert decisions, "the ledger records no opening at all"
    if len(decisions) > 1:
        doc = (REPO_ROOT / "REMEDIATION.md").read_text().lower()
        assert "not an unbiased" in doc or "strong check, not a virgin" in doc, (
            f"{len(decisions)} decision-grade openings but REMEDIATION.md does not "
            "disclose that the estimate is no longer a virgin read")


def test_frozen_config_hash_still_matches():
    """Stage 8 must be analysing the artifact that was pre-registered."""
    p = S7 / "PREREGISTRATION.json"
    if not p.exists():
        pytest.skip("Stage 7 has not been run")
    pre = json.loads(p.read_text())
    h = hashlib.sha256(
        json.dumps(pre["final_config"], sort_keys=True, default=str).encode()
    ).hexdigest()[:16]
    assert h == pre["config_sha256_16"]


def test_stage8_changes_no_configuration():
    """Stage 8 is descriptive. It must not write a config, re-freeze, or re-run the
    search — any of which would turn a report into a second selection."""
    src = inspect.getsource(importlib.import_module("sih_ml.train.run_final"))
    tree = ast.parse(src)
    banned = {"_freeze", "run_study", "_build_composites", "_composite_from",
              "_best_candidate", "_select"}
    called = {n.func.id for n in ast.walk(tree)
              if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)}
    called |= {n.func.attr for n in ast.walk(tree)
               if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)}
    assert not (called & banned), f"Stage 8 performs selection: {called & banned}"
    assert "PREREGISTRATION.json" in src
    assert "SystemExit" in src, "a config-hash mismatch must abort, not warn"


def test_stage8_report_matches_recorded_metrics():
    """Guards against the JSON and the prose drifting apart."""
    p = S8 / "final_validation.json"
    if not p.exists():
        pytest.skip("Stage 8 has not been run")
    R = json.loads(p.read_text())
    rec = json.loads((S7 / "FINAL_TEST_RESULTS.json").read_text())
    assert R["test_metrics"]["average_precision"] == pytest.approx(
        rec["metrics"]["average_precision"], abs=1e-12)
    assert R["reproducibility"]["bit_identical"] is True
    assert R["decision_openings"] == 1


# --------------------------------------------------------------------------- #
# The probes themselves
# --------------------------------------------------------------------------- #
def test_counterfactual_actually_removes_every_rainfall_input(dc):
    """If the counterfactual left any rainfall column live, a "rain doesn't matter"
    conclusion would be an artifact of an incomplete ablation."""
    data, _ = dc
    src = inspect.getsource(robustness.counterfactual_rainfall)
    for name in ("RAIN_COLS", "ID_RATIO_COLS", "ID_EXCEED_COLS", "days_since_rain"):
        assert name in src, f"counterfactual does not touch {name}"

    from sih_ml.optimize.augment import ID_EXCEED_COLS, ID_RATIO_COLS, RAIN_COLS
    rain_like = [c for c in data.features
                 if c.startswith(("rain_", "id_ratio", "id_exceed", "api_"))
                 or c == "days_since_rain"]
    covered = set(RAIN_COLS) | set(ID_RATIO_COLS) | set(ID_EXCEED_COLS) | {"days_since_rain"}
    missed = [c for c in rain_like if c not in covered]
    assert not missed, f"rainfall columns not covered by the counterfactual: {missed}"


def test_feature_group_ablation_covers_every_model_feature(dc):
    """A feature missing from every group would never be ablated, so its importance
    would silently read as zero."""
    data, _ = dc
    grouped = {c for cols in robustness.FEATURE_GROUPS.values() for c in cols}
    missing = [c for c in data.features if c not in grouped]
    assert not missing, f"features in no ablation group: {missing}"


def test_monotonicity_holds_when_derived_flags_are_held_fixed():
    """The 10 declared monotone rainfall constraints must be genuinely enforced.

    Violations appear ONLY when the unconstrained derived `id_exceed_*` flags are
    recomputed, which is a feature-spec issue rather than a LightGBM failure — this
    test pins that distinction so a future change cannot blur it.
    """
    p = S8 / "monotonicity.csv"
    if not p.exists():
        pytest.skip("Stage 8 has not been run")
    m = pd.read_csv(p)
    fixed = m[~m.exceed_flags_updated]
    assert len(fixed) and fixed.violations.sum() == 0, (
        "monotone rainfall constraints are NOT being enforced by LightGBM")
    assert m[m.exceed_flags_updated].violations.sum() > 0, (
        "expected the unconstrained id_exceed_* flags to produce apparent violations; "
        "if this no longer holds the report's explanation is stale")


def test_leakage_audit_flags_shared_segments(dc):
    """The audit must surface segment-level overlap, not just row and event overlap —
    static terrain is a per-segment fingerprint, so a shared segment is a real path."""
    data, _ = dc
    lk = audit.leakage_audit(data)
    assert lk["exact_row_overlap"] == 0
    assert lk["shared_positive_event_ids"] == []
    assert "shared_segment_detail" in lk
    for a in lk["shared_segment_detail"]:
        for k in ("train_positive_rows", "test_positive_rows", "test_tiers",
                  "train_distinct_events"):
            assert k in a


def test_no_segment_leakage_into_the_locked_split(dc):
    """Replaces the Stage 8 canary, which pinned the *presence* of the leak.

    That canary asserted "the gold labels sit on a segment the model trained on" so
    that a future fix would fail loudly and force the reports to be revisited. The
    fix has now happened (the `| label_tier == "gold"` clause is gone from
    `_final_test`), so the canary has served its purpose and is replaced by the
    permanent invariant it was guarding.
    """
    data, _ = dc
    lk = audit.leakage_audit(data)
    assert lk["exact_row_overlap"] == 0
    assert lk["shared_positive_event_ids"] == []
    assert lk["n_shared_segments"] == 0, (
        f"segments span dev and the locked test: {lk['shared_segment_detail']}")
    assert lk["n_shared_blocks"] == 0


def test_locked_split_contains_no_gold_and_that_is_documented(dc):
    """The leak fix moved all 3 verified labels into dev, so the locked split has
    none. That is a real cost of the fix and must not be quietly forgotten: the
    "3 verified closures in the top 1.2%" result is retired, not relocated."""
    data, _ = dc
    te = np.where(data.final_test_mask())[0]   # membership only, not an opening
    n_gold = int((data.panel["label_tier"].to_numpy()[te] == "gold").sum())
    if n_gold:
        pytest.skip("gold labels are back in the locked split (hold_gold_blocks=true)")
    doc = (REPO_ROOT / "FINAL_MODEL.md").read_text()
    assert "retired" in doc.lower() or "no verified labels" in doc.lower(), (
        "locked split has no verified labels and FINAL_MODEL.md does not say so")


def test_rainfall_signal_check_is_base_rate_independent():
    """Dev and test have very different base rates, so the dev-vs-test rainfall
    comparison must use ROC, not AP."""
    src = inspect.getsource(audit.rainfall_signal_check)
    assert "roc_auc_score" in src
    assert "average_precision" not in src


def test_deployment_gates_are_not_silently_all_passing():
    """A gate set that everything passes is decoration. At least one gate must be
    capable of failing, and failures must be recorded rather than smoothed over."""
    p = S8 / "deployment_gates.csv"
    if not p.exists():
        pytest.skip("Stage 8 has not been run")
    g = pd.read_csv(p)
    assert len(g) >= 8
    assert g["pass"].dtype == bool or set(g["pass"].unique()) <= {True, False}
    assert not g["pass"].all(), (
        "every gate passes — either the model is flawless or the thresholds are "
        "set below the measured values, which would make them meaningless")


def test_optimization_advice_is_justified_against_measurements():
    """Recommending ONNX/quantization for a 0.7 MB model that scores the corridor in
    ~1 s would be cargo-culting; each 'no' must carry the condition that would
    change it."""
    p = S8 / "final_validation.json"
    if not p.exists():
        pytest.skip("Stage 8 has not been run")
    adv = json.loads(p.read_text())["optimization_advice"]
    assert adv
    for a in adv:
        assert a["reason"] and a["revisit_if"]
    heavy = [a for a in adv if any(k in a["technique"].lower()
                                   for k in ("quantiz", "onnx", "gpu", "prun"))]
    assert heavy and not any(a["recommended"] for a in heavy), (
        "inference-optimization techniques recommended without a latency or memory "
        "problem to solve")
