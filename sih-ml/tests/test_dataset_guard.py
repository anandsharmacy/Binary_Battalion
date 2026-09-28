"""The locked split may only be revealed through a guarded, recorded chokepoint.

final_test.py did refuse-without-prereg and append-to-ledger, but only inside itself, so
Stage 9's revalidation, the Stage 8 audits and run_final read the locked rows with no
check and no record. TEST_SET_LEDGER.json showed six openings, all under final_v1's
config hash, while every final_v2 test number came from an opening it never saw. These
tests pin the gate at the chokepoint so it cannot drift back into one caller.
"""
import ast
import json
from pathlib import Path

import numpy as np
import pandas as pd
import pytest

from sih_ml.models.dataset import Data
from sih_ml.utils.common import REPO_ROOT

SRC = REPO_ROOT / "src"


@pytest.fixture
def data(tmp_path):
    """A tiny synthetic Data -- these tests must never read real locked rows."""
    panel = pd.DataFrame({
        "segment_id": [f"S{i}" for i in range(6)],
        "date": pd.to_datetime(["2020-01-01"] * 6),
        "target": [0, 1, 0, 1, 0, 0],
        "final_test": [False, False, True, True, False, True],
    })
    d = Data(panel=panel, features=[], categorical=[], spec={})
    d.prereg_path_ = tmp_path / "PREREGISTRATION.json"
    d.ledger_path_ = tmp_path / "TEST_SET_LEDGER.json"
    d.prereg_path_.write_text(json.dumps({"config_sha256_16": "deadbeefdeadbeef"}))
    return d


def _ledger(d):
    return json.loads(Path(d.ledger_path_).read_text())["openings"]


def test_reason_is_required_and_keyword_only(data):
    """An unnamed positional call must not even typecheck -- the split cannot be
    opened absent-mindedly."""
    with pytest.raises(TypeError):
        data.final_test_index()
    with pytest.raises(TypeError):
        data.final_test_index("stage8")


def test_opening_is_recorded_with_its_reason(data):
    idx = data.final_test_index(reason="unit test opening")
    assert sorted(idx) == [2, 3, 5]
    entries = _ledger(data)
    assert len(entries) == 1
    e = entries[0]
    assert e["reason"] == "unit test opening"
    assert e["n_rows"] == 3 and e["n_positives"] == 1
    assert e["config_sha256_16"] == "deadbeefdeadbeef"
    # the caller must be identifiable, or the trail says nothing about who looked
    assert "test_dataset_guard.py" in e["caller"]


def test_every_opening_appends_another_entry(data):
    data.final_test_index(reason="first")
    data.final_test_index(reason="second")
    assert [e["reason"] for e in _ledger(data)] == ["first", "second"]


def test_refuses_without_preregistration(data):
    Path(data.prereg_path_).unlink()
    with pytest.raises(RuntimeError, match="REFUSING to open the locked test set"):
        data.final_test_index(reason="should not be allowed")
    assert not Path(data.ledger_path_).exists(), "a refused opening must not be recorded"


def test_dev_mask_is_not_guarded(data):
    """dev_mask EXCLUDES the locked rows and is on every training path. Guarding it
    would be wrong and would flood the ledger."""
    assert data.dev_mask().tolist() == [True, True, False, False, True, False]
    assert not Path(data.ledger_path_).exists()


def test_no_source_file_opens_the_split_without_a_reason():
    """The meta-test that stops the gap reopening: a new caller cannot read the locked
    rows without declaring why, because the AST check fails the build."""
    offenders = []
    for path in SRC.rglob("*.py"):
        tree = ast.parse(path.read_text())
        for node in ast.walk(tree):
            if (isinstance(node, ast.Call)
                    and isinstance(node.func, ast.Attribute)
                    and node.func.attr == "final_test_index"):
                if not any(kw.arg == "reason" for kw in node.keywords):
                    offenders.append(f"{path.relative_to(REPO_ROOT)}:{node.lineno}")
    assert not offenders, f"final_test_index called without reason=: {offenders}"
