#!/usr/bin/env python
"""Stage 10 — one campaign of the continuous improvement loop.

    python scripts/run_stage10.py [conf/improve_config.yaml] [--rebaseline]

Reconstructs and verifies the champion, re-diagnoses its error patterns, calibrates
the A/A noise floor, runs the experiment backlog (correctness -> backlog -> greedy
composition), materialises the champion, measures its efficiency frontier, and
appends every decision to reports/stage10/EXPERIMENT_LEDGER.jsonl. Dev data only.

--rebaseline re-measures the champion when its recorded numbers were taken under a
different data or code fingerprint (a rebuilt panel, say). It is never implied: under
an unchanged fingerprint a mismatch is still fatal, because that means the champion is
not the one the registry describes.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from sih_ml.train.run_improve import main

if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if a != "--rebaseline"]
    main(args[0] if args else None, rebaseline="--rebaseline" in sys.argv[1:])
