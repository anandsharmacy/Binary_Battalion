#!/usr/bin/env python
"""Phase D — refit local (per-region) calibrators from a real operational log and
write them into a deployed bundle. Dormant: there is no real operational log yet
(see src/sih_ml/serve/local_calibration.py's docstring for the proposed schema).
Run each season once one exists.

    python scripts/run_recalibrate.py <operational_log.csv|.parquet> [bundle_dir]

Default bundle_dir: deploy/bundles/current.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from sih_ml.serve.local_calibration import refit
from sih_ml.utils.common import REPO_ROOT

if __name__ == "__main__":
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    log_path = sys.argv[1]
    bundle_dir = sys.argv[2] if len(sys.argv) > 2 else str(REPO_ROOT / "deploy" / "bundles" / "current")
    manifest = refit(log_path, bundle_dir)
    print(f"refit {len(manifest['regions'])} region(s) into {bundle_dir}: {manifest['regions']}")
