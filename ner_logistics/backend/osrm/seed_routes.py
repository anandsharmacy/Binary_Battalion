#!/usr/bin/env python3
"""Generate supabase/migrations/20260927100020_routing_seed_routes.sql.

1. District points: each NE district's OSM admin_centre (its HQ town) from
   Overpass, falling back to the boundary centre. Written to locations.geom
   (only where still null) so the web planner and ML "near place" can use them.
2. Corridors: OSRM car routes between those district points, pinned to the
   highway with via points (district HQs or named towns on the NH). The
   geometry is OSRM's, stored as an encoded polyline6 and decoded in SQL.

Run against the self-hosted graph (same Geofabrik extract as production):
    ./prepare.sh && docker compose up -d
    OSRM_URL=http://localhost:5000 python3 seed_routes.py
Stdlib only. Re-run after the extract changes; the migration is idempotent.

    python3 seed_routes.py --boundaries   # no OSRM needed
writes supabase/migrations/20260928100010_district_boundaries.sql: each district's OSM boundary polygon
(simplified, from polygons.openstreetmap.fr) into locations.boundary, used by district_at() to decide
which district a rider is in.
"""
import json
import os
import re
import sys
import time
import unicodedata
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OSRM = os.environ.get("OSRM_URL", "http://localhost:5000").rstrip("/")
OVERPASS = os.environ.get("OVERPASS_URL", "https://overpass-api.de/api/interpreter")
SEED = ROOT / "supabase/migrations/20260924000007_seed_locations.sql"
OUT = ROOT / "supabase/migrations/20260927100020_routing_seed_routes.sql"
BOUNDARY_OUT = ROOT / "supabase/migrations/20260928100010_district_boundaries.sql"
WKT_URL = "https://polygons.openstreetmap.fr/get_wkt.py?id={}&params=0.004-0.001-0.001"
# Map-scale copy for the website's corridor layer (src/data/geo.ts).
WEB_OUT = ROOT / "web/NER-Website/src/data/corridors.generated.ts"
UA = {"User-Agent": "ner-logistics seed_routes.py"}

# OSM spelling -> seeded locations spelling.
ALIASES = {"Sipahijala": "Sepahijala", "Saiha": "Siaha", "Marigaon": "Morigaon",
           "Karimganj": "Sribhumi", "Ri-Bhoi": "Ri Bhoi"}
# Districts whose OSM boundary has no admin_centre: HQ town coordinates.
HQ_OVERRIDE = {"Kohima": (25.6747, 94.1086), "Itanagar Capital Complex": (27.0844, 93.6053)}

# Towns on the highways that are not district HQs (checked against OSRM /nearest
# in ner_logistics/lib/shared/map/ner_geo.dart).
TOWNS = {
    "Jorabat": (26.1030, 91.8740), "Lumding": (25.7502, 93.1712), "Sonapur": (25.0455, 92.4205),
    "Badarpur": (24.8680, 92.5960), "Mao": (25.5143, 94.1362), "Piphema": (25.7200, 93.9300),
    "Bokakhat": (26.6400, 93.6000), "Bhalukpong": (27.0130, 92.6430), "Dirang": (27.3580, 92.2400),
    "Sela Pass": (27.5050, 92.1050), "Rangpo": (27.1760, 88.5300), "Gangtok": (27.3389, 88.6065),  # Sikkim districts are not seeded
}

# route_number, name, origin, destination, via (district names or TOWNS keys).
CORRIDORS = [
    ("NH-27", "East–West Corridor: Kokrajhar–Guwahati–Silchar", "Kokrajhar", "Cachar",
     ["Bongaigaon", "Nalbari", "Kamrup Metropolitan", "Nagaon", "Lumding", "Dima Hasao"]),
    ("NH-6", "Guwahati–Shillong–Silchar", "Kamrup Metropolitan", "Cachar",
     ["Jorabat", "Ri Bhoi", "East Khasi Hills", "West Jaintia Hills", "East Jaintia Hills", "Sonapur", "Badarpur"]),
    ("NH-306", "Silchar–Kolasib–Aizawl", "Cachar", "Aizawl", ["Kolasib"]),
    ("NH-37", "Silchar–Jiribam–Imphal", "Cachar", "Imphal West", ["Jiribam", "Noney"]),
    ("NH-2", "Kohima–Imphal", "Kohima", "Imphal West", ["Mao", "Senapati"]),
    ("NH-29", "Dimapur–Kohima", "Dimapur", "Kohima", ["Chumoukedima", "Piphema"]),
    ("NH-715", "Nagaon–Kaziranga–Jorhat", "Nagaon", "Jorhat", ["Bokakhat"]),
    ("NH-15", "Guwahati–Mangaldai–Tezpur", "Kamrup Metropolitan", "Sonitpur", ["Darrang"]),
    ("NH-13", "Tezpur–Bomdila–Tawang", "Sonitpur", "Tawang", ["Bhalukpong", "West Kameng", "Dirang", "Sela Pass"]),
    ("NH-8", "Karimganj–Agartala (Tripura lifeline)", "Sribhumi", "West Tripura", ["North Tripura", "Dhalai"]),
    # Siliguri is outside the north-eastern-zone extract; only the Sikkim section is routable.
    ("NH-10", "Rangpo–Gangtok (Sikkim section)", "Rangpo", "Gangtok", []),
]


def get(url, data=None):
    for attempt in range(4):
        try:
            req = urllib.request.Request(url, data=data, headers=UA)
            with urllib.request.urlopen(req, timeout=240) as r:
                return json.load(r)
        except Exception as e:  # Overpass is often busy; back off and retry
            if attempt == 3:
                raise
            print(f"retry {url[:60]}: {e}", file=sys.stderr)
            time.sleep(10 * (attempt + 1))


def ascii_name(s):
    s = re.sub(r"\s+district$", "", s, flags=re.I)
    s = "".join(c for c in unicodedata.normalize("NFKD", s) if not unicodedata.combining(c))
    return ALIASES.get(s, s)


def district_points():
    seeded = dict(re.findall(r"\('([^']+)', '[^']+', '([^']+)', 'district'\)", SEED.read_text()))
    q = """[out:json][timeout:180];
area["ISO3166-2"~"^IN-(AS|AR|MN|ML|MZ|NL|TR|SK)$"]->.ne;
rel(area.ne)[boundary=administrative][admin_level=5]->.d;
.d out body center;
node(r.d:"admin_centre");
out;"""
    els = get(OVERPASS, urllib.parse.urlencode({"data": q}).encode())["elements"]
    nodes = {e["id"]: e for e in els if e["type"] == "node"}
    pts, hq = {}, {}
    for e in els:
        if e["type"] != "relation":
            continue
        name = ascii_name(e["tags"].get("name:en") or e["tags"].get("name", ""))
        if name not in seeded:
            continue
        ac = next((nodes[m["ref"]] for m in e["members"] if m["role"] == "admin_centre" and m["ref"] in nodes), None)
        if ac:
            pts[name] = (ac["lat"], ac["lon"])
            hq[name] = ac.get("tags", {}).get("name:en") or ac.get("tags", {}).get("name")
        elif "center" in e:
            pts[name] = (e["center"]["lat"], e["center"]["lon"])
    pts.update({n: p for n, p in HQ_OVERRIDE.items() if n in seeded})
    missing = sorted(set(seeded) - set(pts))
    if missing:
        print("no OSM point for:", ", ".join(missing), file=sys.stderr)
    return seeded, pts, hq


def _dp(pts, tol):
    """Douglas-Peucker on an open point list (iterative, keeps both ends)."""
    keep = [False] * len(pts)
    keep[0] = keep[-1] = True
    stack = [(0, len(pts) - 1)]
    while stack:
        i, j = stack.pop()
        (x1, y1), (x2, y2) = pts[i], pts[j]
        dx, dy = x2 - x1, y2 - y1
        n = dx * dx + dy * dy
        far, at = 0.0, -1
        for k in range(i + 1, j):
            x, y = pts[k]
            t = 0 if n == 0 else max(0, min(1, ((x - x1) * dx + (y - y1) * dy) / n))
            d = ((x - x1 - t * dx) ** 2 + (y - y1 - t * dy) ** 2) ** 0.5
            if d > far:
                far, at = d, k
        if far > tol:
            keep[at] = True
            stack += [(i, at), (at, j)]
    return [p for p, k in zip(pts, keep) if k]


def compact_wkt(wkt, tol=0.005, nd=3):
    """Round to nd decimals (kills float noise) and simplify rings to ~tol degrees (0.005 ~ 500 m).
    A hole that collapses below 4 points is dropped; an outer ring is never dropped."""
    def ring(m):
        hole = m.group(1) == ","
        pts = [tuple(round(float(v), nd) for v in c.split()) for c in m.group(2).split(",")]
        pts = [pts[0]] + [b for a, b in zip(pts, pts[1:]) if a != b]
        out = _dp(pts[:-1], tol) + [pts[0]]
        if len(out) < 4:
            if hole:
                return ""
            out = pts
        return f"{m.group(1)}(" + ",".join(f"{x:g} {y:g}" for x, y in out) + ")"
    return re.sub(r"(,?)\(([^()]+)\)", ring, wkt)


BACKFILL = """
-- Simplified polygons can self-touch; repair them.
update public.locations
   set boundary = extensions.st_multi(extensions.st_collectionextract(extensions.st_makevalid(boundary::extensions.geometry), 3))::extensions.geography
 where kind = 'district' and boundary is not null and not extensions.st_isvalid(boundary::extensions.geometry);

-- Re-derive districts now that polygons exist (the previous migration used the HQ fallback).
update public.rider_locations set current_district_id = public.district_at(geom);
update public.rider_location_history h
   set district_id = public.district_at(
     extensions.st_setsrid(extensions.st_makepoint(h.longitude, h.latitude), 4326)::extensions.geography);
"""


def boundaries():
    seeded = dict(re.findall(r"\('([^']+)', '[^']+', '([^']+)', 'district'\)", SEED.read_text()))
    qry = '[out:json][timeout:180];\narea["ISO3166-2"~"^IN-(AS|AR|MN|ML|MZ|NL|TR|SK)$"]->.ne;\n' \
          'rel(area.ne)[boundary=administrative][admin_level=5];\nout tags;'
    rels = get(OVERPASS, urllib.parse.urlencode({"data": qry}).encode())["elements"]
    rows, missing = [], set(seeded)
    for e in rels:
        name = ascii_name(e["tags"].get("name:en") or e["tags"].get("name", ""))
        if name not in seeded:
            continue
        for attempt in range(4):
            try:
                req = urllib.request.Request(WKT_URL.format(e["id"]), headers=UA)
                wkt = urllib.request.urlopen(req, timeout=120).read().decode().split(";", 1)[-1].strip()
                break
            except Exception as ex:
                if attempt == 3:
                    print(f"no boundary for {name}: {ex}", file=sys.stderr)
                    wkt = ""
                time.sleep(5 * (attempt + 1))
        if wkt.startswith(("MULTIPOLYGON", "POLYGON")):
            rows.append((name, seeded[name], compact_wkt(wkt)))
            missing.discard(name)
            print(f"{name}: {len(wkt) // 1024} KB", file=sys.stderr)
        time.sleep(1)  # be polite to the public server
    if missing:
        print("no boundary for (HQ fallback applies):", ", ".join(sorted(missing)), file=sys.stderr)
    body = "\n".join(
        f"update public.locations set boundary = extensions.st_multi(extensions.st_geomfromtext({q(w)}, 4326))::extensions.geography\n"
        f"  where kind = 'district' and name = {q(n)} and state = {q(st)};" for n, st, w in sorted(rows))
    BOUNDARY_OUT.write_text("-- Generated by ner_logistics/backend/osrm/seed_routes.py --boundaries. Do not edit by hand.\n"
                            "-- OSM district boundaries (simplified) for district_at().\n" + body + "\n" + BACKFILL)
    print(f"wrote {BOUNDARY_OUT.relative_to(ROOT)}: {len(rows)} boundaries", file=sys.stderr)


def osrm_route(coords, overview="full"):
    path = ";".join(f"{lon:.6f},{lat:.6f}" for lat, lon in coords)
    j = get(f"{OSRM}/route/v1/driving/{path}?overview={overview}&geometries=polyline6&steps=false")
    if j.get("code") != "Ok":
        raise SystemExit(f"OSRM {j.get('code')}: {j.get('message')}")
    far = [(c, round(w["distance"])) for c, w in zip(coords, j["waypoints"]) if w["distance"] > 2000]
    if far:  # point outside the extract or off-road: the geometry would be wrong
        raise SystemExit(f"waypoints snap > 2 km from a road: {far}")
    return j["routes"][0]


def q(s):
    return "'" + s.replace("'", "''") + "'"


def main():
    seeded, pts, hq = district_points()
    at = lambda n: pts.get(n) or TOWNS[n]
    label = lambda n: n if n in TOWNS else f"{hq[n]} ({n})" if hq.get(n) and hq[n] != n else n
    rows, web = [], []
    for num, name, a, b, via in CORRIDORS:
        r = osrm_route([at(a), *map(at, via), at(b)])
        print(f"{num:7} {r['distance'] / 1000:6.0f} km {r['duration'] / 3600:4.1f} h  {name}", file=sys.stderr)
        rows.append(f"  ({q(num)}, {q(name)}, {q(label(a))}, {q(label(b))}, {q(r['geometry'])})")
        simple = osrm_route([at(a), *map(at, via), at(b)], overview="simplified")["geometry"]
        web.append(f"  {json.dumps(num)}: {{ name: {json.dumps(name)}, polyline6: {json.dumps(simple)} }},")

    route_rows = ",\n".join(rows)
    loc_rows = ",\n".join(f"  ({q(n)}, {q(seeded[n])}, {lon:.6f}, {lat:.6f})" for n, (lat, lon) in sorted(pts.items()))
    OUT.write_text(f"""-- Generated by ner_logistics/backend/osrm/seed_routes.py. Do not edit by hand; re-run the script.
-- District points: OSM admin_centre of each district boundary (HQ town), else the boundary centre.
-- Route geometry: OSRM car routes (Geofabrik north-eastern-zone extract) as encoded polyline6.

update public.locations l set geom = extensions.st_setsrid(extensions.st_makepoint(v.lon, v.lat), 4326)::extensions.geography
from (values
{loc_rows}
) as v(name, state, lon, lat)
where l.kind = 'district' and l.name = v.name and l.state = v.state and l.geom is null;

insert into public.routes (route_number, name, origin, destination, geom)
select v.route_number, v.name, v.origin, v.destination,
       extensions.st_linefromencodedpolyline(v.polyline, 6)::extensions.geography
from (values
{route_rows}
) as v(route_number, name, origin, destination, polyline)
on conflict (route_number) do update
  set name = excluded.name, origin = excluded.origin, destination = excluded.destination, geom = excluded.geom;
""")
    WEB_OUT.write_text("// Generated by ner_logistics/backend/osrm/seed_routes.py (OSRM, overview=simplified). Do not edit.\n"
                       "// Same corridors as public.routes (migration 20260927100020), simplified for map display.\n"
                       "export const CORRIDOR_POLYLINES: Record<string, { name: string; polyline6: string }> = {\n"
                       + "\n".join(web) + "\n};\n")
    print(f"wrote {OUT.relative_to(ROOT)}: {len(pts)} districts, {len(rows)} routes", file=sys.stderr)


if __name__ == "__main__":
    boundaries() if "--boundaries" in sys.argv else main()
