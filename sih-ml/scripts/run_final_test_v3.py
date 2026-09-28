#!/usr/bin/env python
"""Phase C — the ONE pre-registered opening of the locked split under
PREREGISTRATION_V3, scoring final_v2 (release champion) and final_v6 (candidate) on
the same current-split population in one run. See
src/sih_ml/train/final_test_v3.py and reports/stage10/PREREGISTRATION_V3.json.

    python scripts/run_final_test_v3.py [conf/improve_config.yaml]
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from sih_ml.train.final_test_v3 import main

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else None)
