#!/usr/bin/env python3
"""Build a compact on-device routing graph (NERG v1) + places gazetteer from an OSM PBF.

Usage:
  python3 build_nav_graph.py <out_dir> <in.osm.pbf>[@W,S,E,N] [more.osm.pbf@W,S,E,N ...] [--no-tracks]

  Each input may carry its own bbox. NER needs two inputs because Geofabrik's
  north-eastern-zone stops at the West Bengal border, which cuts Sikkim off
  from the rest of the network (the Siliguri corridor is in eastern-zone):
    python3 build_nav_graph.py out north-eastern-zone-latest.osm.pbf \
        eastern-zone-latest.osm.pbf@87.9,26.2,89.9,27.3

Outputs:
  <out_dir>/ner_roads.bin   routing graph (little-endian, see FORMAT below)
  <out_dir>/ner_places.tsv  name \t kind \t lat \t lon  (place=*, plus a few POI kinds)

FORMAT (all little-endian):
  header : b'NERG' u32 version=1, u32 nodeCount N, u32 edgeCount M, u32 geomCount G, u32 nameCount K
  nodes  : i32 lat_e6[N], i32 lon_e6[N]
  csr    : u32 firstEdge[N+1]               edges of node i are firstEdge[i]..firstEdge[i+1]-1
  edges  : u32 target[M], u32 distDm[M], u32 timeDs[M], u32 geomStart[M],
           u16 geomCount[M], u8 flags[M] (bits0-3 roadClass, bit4 roundabout, bit5 geomReversed),
           u8 pad[M], u32 nameIdx[M] (0xFFFFFFFF = unnamed)
  geom   : i32 lat_e6[G], i32 lon_e6[G]     interior shape points only (no junction endpoints)
  names  : u32 offset[K+1], utf8 bytes     "ref|name", e.g. "NH6|Shillong Road"
"""
import math, struct, sys
from array import array
import osmium

# class id, km/h — conservative for NER hill roads; tune after field tests.
CLASSES = {
    'motorway': (0, 60), 'trunk': (1, 45), 'primary': (2, 40), 'secondary': (3, 35),
    'tertiary': (4, 30), 'unclassified': (5, 25), 'residential': (6, 20),
    'living_street': (7, 10), 'service': (8, 12), 'track': (9, 10), 'road': (5, 20),
}
LINK = {'motorway_link': 'motorway', 'trunk_link': 'trunk', 'primary_link': 'primary',
        'secondary_link': 'secondary', 'tertiary_link': 'tertiary'}
NO_ACCESS = {'no', 'private'}
PLACE_KINDS = {'city', 'town', 'village', 'hamlet', 'suburb', 'neighbourhood', 'locality'}
POI_KINDS = {('amenity', 'hospital'), ('amenity', 'fuel'), ('amenity', 'police'),
             ('amenity', 'clinic'), ('amenity', 'pharmacy'), ('landuse', 'depot')}


def haversine_m(la1, lo1, la2, lo2):
    r = 6371008.8
    p1, p2 = math.radians(la1), math.radians(la2)
    dp, dl = p2 - p1, math.radians(lo2 - lo1)
    h = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * r * math.asin(min(1.0, math.sqrt(h)))


class Collector(osmium.SimpleHandler):
    def __init__(self, bbox, tracks):
        super().__init__()
        self.bbox, self.tracks = bbox, tracks
        self.ways = []            # (cls, oneway, roundabout, nameIdx, refs array, lat array, lon array)
        self.use = {}             # osm node id -> number of way occurrences
        self.names, self.name_idx = [], {}
        self.places = []
        self.seen = set()         # way ids already taken (inputs overlap at borders)

    def _inside(self, lat, lon):
        if not self.bbox:
            return True
        w, s, e, n = self.bbox
        return w <= lon <= e and s <= lat <= n

    def _name(self, tags):
        key = f"{tags.get('ref', '')}|{tags.get('name:en') or tags.get('name', '')}"
        if key == '|':
            return 0xFFFFFFFF
        if key not in self.name_idx:
            self.name_idx[key] = len(self.names)
            self.names.append(key)
        return self.name_idx[key]

    def node(self, n):
        t = n.tags
        kind = t.get('place') if t.get('place') in PLACE_KINDS else None
        if kind is None:
            for k, v in POI_KINDS:
                if t.get(k) == v:
                    kind = v
        name = t.get('name:en') or t.get('name')
        if kind and name and n.location.valid() and self._inside(n.location.lat, n.location.lon):
            self.places.append((name.replace('\t', ' '), kind, n.location.lat, n.location.lon))

    def way(self, w):
        t = w.tags
        if w.id in self.seen:
            return
        self.seen.add(w.id)
        if t.get('place') in PLACE_KINDS and (t.get('name:en') or t.get('name')):
            pts = [(nd.location.lat, nd.location.lon) for nd in w.nodes if nd.location.valid()]
            if pts:  # centroid of the outline is good enough for search
                la, lo = sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts)
                if self._inside(la, lo):
                    self.places.append(((t.get('name:en') or t.get('name')).replace('\t', ' '), t['place'], la, lo))
        hw = t.get('highway')
        hw = LINK.get(hw, hw)
        if hw not in CLASSES or (hw == 'track' and not self.tracks):
            return
        if t.get('access') in NO_ACCESS or t.get('motor_vehicle') in NO_ACCESS or t.get('area') == 'yes':
            return
        refs, lats, lons = array('q'), array('i'), array('i')
        for nd in w.nodes:
            if not nd.location.valid():
                continue
            refs.append(nd.ref)
            lats.append(round(nd.location.lat * 1e6))
            lons.append(round(nd.location.lon * 1e6))
        if len(refs) < 2:
            return
        if self.bbox and not any(self._inside(la / 1e6, lo / 1e6) for la, lo in zip(lats, lons)):
            return
        ow = t.get('oneway')
        roundabout = t.get('junction') in ('roundabout', 'circular')
        oneway = 1 if ow in ('yes', '1', 'true') or roundabout or hw == 'motorway' else (-1 if ow == '-1' else 0)
        if ow == 'no':
            oneway = 0
        for i, r in enumerate(refs):
            # endpoints count twice so they always become junctions
            self.use[r] = self.use.get(r, 0) + (2 if i in (0, len(refs) - 1) else 1)
        self.ways.append((CLASSES[hw][0], oneway, roundabout, self._name(t), refs, lats, lons))


def build(inputs, out_dir, tracks=True):
    c = Collector(None, tracks)
    for pbf, bbox in inputs:
        c.bbox = bbox
        c.apply_file(pbf, locations=True, idx='flex_mem')
    c.places = sorted(set(c.places))
    speeds = {cid: kmh for cid, kmh in CLASSES.values()}

    node_id, lat_n, lon_n = {}, array('i'), array('i')
    def nid(ref, la, lo):
        i = node_id.get(ref)
        if i is None:
            i = node_id[ref] = len(lat_n)
            lat_n.append(la); lon_n.append(lo)
        return i

    raw = []  # (from, to, distDm, timeDs, geomStart, geomCount, flags, nameIdx)
    g_lat, g_lon = array('i'), array('i')
    for cls, oneway, rb, name, refs, lats, lons in c.ways:
        start = 0
        for j in range(1, len(refs)):
            if c.use[refs[j]] < 2 and j != len(refs) - 1:
                continue
            a = nid(refs[start], lats[start], lons[start])
            b = nid(refs[j], lats[j], lons[j])
            d = sum(haversine_m(lats[k - 1] / 1e6, lons[k - 1] / 1e6, lats[k] / 1e6, lons[k] / 1e6)
                    for k in range(start + 1, j + 1))
            gs, gc = len(g_lat), j - start - 1
            g_lat.extend(lats[start + 1:j]); g_lon.extend(lons[start + 1:j])
            dist_dm = round(d * 10)
            time_ds = max(1, round(d / (speeds[cls] / 3.6) * 10))
            flags = cls | (16 if rb else 0)
            if oneway >= 0:
                raw.append((a, b, dist_dm, time_ds, gs, gc, flags, name))
            if oneway <= 0:
                raw.append((b, a, dist_dm, time_ds, gs, gc, flags | 32, name))
            start = j

    n, m = len(lat_n), len(raw)
    raw.sort(key=lambda e: e[0])
    first = array('I', [0] * (n + 1))
    for e in raw:
        first[e[0] + 1] += 1
    for i in range(n):
        first[i + 1] += first[i]

    names_b = [s.encode('utf-8') for s in c.names]
    offs = array('I', [0])
    for s in names_b:
        offs.append(offs[-1] + len(s))

    def col(fmt, idx):
        return array(fmt, [e[idx] for e in raw])

    with open(f'{out_dir}/ner_roads.bin', 'wb') as f:
        f.write(b'NERG' + struct.pack('<5I', 1, n, m, len(g_lat), len(names_b)))
        for arr in (lat_n, lon_n, first, col('I', 1), col('I', 2), col('I', 3), col('I', 4),
                    col('H', 5), array('B', [e[6] for e in raw]), array('B', [0] * m), col('I', 7),
                    g_lat, g_lon, offs):
            f.write(arr.tobytes())  # host is little-endian (arm64/x86_64)
        f.write(b''.join(names_b))

    with open(f'{out_dir}/ner_places.tsv', 'w', encoding='utf-8') as f:
        for name, kind, la, lo in c.places:
            f.write(f'{name}\t{kind}\t{la:.6f}\t{lo:.6f}\n')
    print(f'nodes={n} edges={m} geom={len(g_lat)} names={len(names_b)} places={len(c.places)}')


if __name__ == '__main__':
    args = sys.argv[1:]
    tracks = '--no-tracks' not in args
    args = [a for a in args if a != '--no-tracks']
    inputs = []
    for a in args[1:]:
        path, _, box = a.partition('@')
        inputs.append((path, tuple(map(float, box.split(','))) if box else None))
    build(inputs, args[0], tracks)
