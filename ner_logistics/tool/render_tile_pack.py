#!/usr/bin/env python3
"""Render a raster MBTiles pack from a LOCAL tileserver-gl (never a public tile server).

  python3 render_tile_pack.py <out.mbtiles> <W,S,E,N> <minzoom> <maxzoom> "<pack name>" \
      [--server http://localhost:8080] [--style <id>] [--format webp|png] [--workers 8]

Stdlib only. Resumable: tiles already in the file are skipped.
"""
import argparse, json, math, sqlite3, urllib.request
from concurrent.futures import ThreadPoolExecutor

ATTRIBUTION = '© OpenMapTiles © OpenStreetMap contributors'


def tile_range(w, s, e, n, z):
    def xy(lon, lat):
        k = 2 ** z
        x = int((lon + 180) / 360 * k)
        y = int((1 - math.asinh(math.tan(math.radians(lat))) / math.pi) / 2 * k)
        return min(max(x, 0), k - 1), min(max(y, 0), k - 1)
    x0, y0 = xy(w, n)
    x1, y1 = xy(e, s)
    return [(z, x, y) for x in range(x0, x1 + 1) for y in range(y0, y1 + 1)]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('out'); ap.add_argument('bbox'); ap.add_argument('minz', type=int)
    ap.add_argument('maxz', type=int); ap.add_argument('name')
    ap.add_argument('--server', default='http://localhost:8080')
    ap.add_argument('--style'); ap.add_argument('--format', default='webp')
    ap.add_argument('--workers', type=int, default=8)
    a = ap.parse_args()
    w, s, e, n = map(float, a.bbox.split(','))
    style = a.style or json.load(urllib.request.urlopen(f'{a.server}/styles.json'))[0]['id']

    db = sqlite3.connect(a.out)
    db.executescript('''
      CREATE TABLE IF NOT EXISTS metadata (name TEXT PRIMARY KEY, value TEXT);
      CREATE TABLE IF NOT EXISTS tiles (zoom_level INTEGER, tile_column INTEGER,
        tile_row INTEGER, tile_data BLOB, PRIMARY KEY (zoom_level, tile_column, tile_row));''')
    old = dict(db.execute('SELECT name, value FROM metadata'))
    # Re-running with other zooms adds to the pack: keep the widest range.
    minz = min(a.minz, int(old.get('minzoom', a.minz)))
    maxz = max(a.maxz, int(old.get('maxzoom', a.maxz)))
    meta = {'name': a.name, 'format': a.format, 'type': 'baselayer', 'version': '1',
            'bounds': f'{w},{s},{e},{n}', 'minzoom': str(minz), 'maxzoom': str(maxz),
            'attribution': ATTRIBUTION}
    db.executemany('INSERT OR REPLACE INTO metadata VALUES (?, ?)', meta.items())
    have = set(db.execute('SELECT zoom_level, tile_column, tile_row FROM tiles'))

    def fetch(t):
        z, x, y = t
        url = f'{a.server}/styles/{style}/256/{z}/{x}/{y}.{a.format}'
        return z, x, (2 ** z - 1 - y), urllib.request.urlopen(url, timeout=60).read()  # MBTiles = TMS rows

    todo = [t for z in range(a.minz, a.maxz + 1) for t in tile_range(w, s, e, n, z)
            if (t[0], t[1], 2 ** t[0] - 1 - t[2]) not in have]
    print(f'{len(todo)} tiles to render with style {style}')
    with ThreadPoolExecutor(a.workers) as pool:
        for i, row in enumerate(pool.map(fetch, todo), 1):
            db.execute('INSERT OR REPLACE INTO tiles VALUES (?, ?, ?, ?)', row)
            if i % 500 == 0:
                db.commit(); print(f'{i}/{len(todo)}')
    db.commit()
    db.execute('VACUUM')
    db.close()


if __name__ == '__main__':
    main()
