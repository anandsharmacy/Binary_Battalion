"""nearest_cell_map is chunked over segments so a fine rainfall grid cannot OOM:
309k segments x ~9.6k cells at CHIRPS 0.05 deg is a 24 GB distance matrix unchunked.
Chunking must not change which cell a segment is assigned to.
"""
import numpy as np
import pandas as pd

from sih_ml.utils.geo import haversine_m, nearest_cell_map


def test_chunking_does_not_change_the_assignment():
    rng = np.random.default_rng(0)
    n_cells = 5_000   # forces rows = 4_000_000 // 5_000 = 800, so 2,000 segments span 3 chunks
    cells = pd.DataFrame({"cell_id": [f"c{i}" for i in range(n_cells)],
                          "longitude": rng.uniform(87.0, 90.0, n_cells),
                          "latitude": rng.uniform(25.5, 28.2, n_cells)})
    seg = pd.DataFrame({"segment_id": [f"S{i}" for i in range(2_000)],
                        "lon": rng.uniform(87.0, 90.0, 2_000),
                        "lat": rng.uniform(25.5, 28.2, 2_000)})

    got = nearest_cell_map(seg, cells)

    d = haversine_m(seg.lon.to_numpy()[:, None], seg.lat.to_numpy()[:, None],
                    cells.longitude.to_numpy()[None, :], cells.latitude.to_numpy()[None, :])
    j = np.argmin(d, axis=1)
    assert (got.cell_id.to_numpy() == cells.cell_id.to_numpy()[j]).all()
    assert np.allclose(got.cell_dist_m.to_numpy(), d[np.arange(len(j)), j])
