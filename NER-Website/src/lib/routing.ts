/* ────────────────────────────────────────────────────────────────
   Road routing on OSRM plus route "optimization": the fastest route
   is not always the one to take. Candidates are OSRM's alternatives
   (plus a forced detour when every one of them passes a blocking
   incident), each scored by active hazards and by the ML risk model
   (get_route_ml_risk); the pick is the lowest-risk acceptable route.

   Port of ner_logistics/lib/services/routing/{osrm_client,route_planner}.dart.
   Keep the two in step.
──────────────────────────────────────────────────────────────── */

import { decodePolyline, type LatLng } from '@/data/geo';

export { decodePolyline };
import { supabase } from '@/lib/supabase';
import { MlSignedOutError, type MlBand, type RouteRisk } from '@/lib/ml';

// ponytail: public demo server allows ~1 req/s and no production use; set
// VITE_OSRM_URL to the self-hosted engine (ner_logistics/backend/osrm/README.md).
export const OSRM_URL = ((import.meta.env.VITE_OSRM_URL as string | undefined) || 'https://router.project-osrm.org').replace(/\/$/, '');
export const usesPublicOsrm = OSRM_URL.includes('router.project-osrm.org');

export interface OsrmRoute {
  geometry: LatLng[];
  distanceM: number;
  durationS: number;
  /** Main roads, e.g. "NH6, NH27" (OSRM leg summary). */
  summary: string;
}

export class OsrmError extends Error {
  code: string;
  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

// ── geometry ────────────────────────────────────────────────────────────────

const R = 6371008.8;
const rad = (d: number) => (d * Math.PI) / 180;

export function distanceM(a: LatLng, b: LatLng): number {
  const h = Math.sin(rad(b[0] - a[0]) / 2) ** 2 + Math.cos(rad(a[0])) * Math.cos(rad(b[0])) * Math.sin(rad(b[1] - a[1]) / 2) ** 2;
  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)));
}

/** Distance from p to segment ab (local equirectangular projection; fine at road scale). */
function toSegmentM(p: LatLng, a: LatLng, b: LatLng): number {
  const k = Math.cos(rad(p[0]));
  const ax = (a[1] - p[1]) * k, ay = a[0] - p[0];
  const bx = (b[1] - p[1]) * k, by = b[0] - p[0];
  const dx = bx - ax, dy = by - ay;
  const len = dx * dx + dy * dy;
  const t = len ? Math.max(0, Math.min(1, -(ax * dx + ay * dy) / len)) : 0;
  return Math.hypot(ax + t * dx, ay + t * dy) * (Math.PI / 180) * R;
}

export function distanceToLineM(p: LatLng, line: LatLng[]): number {
  if (line.length === 1) return distanceM(p, line[0]);
  let best = Infinity;
  for (let i = 1; i < line.length; i++) best = Math.min(best, toSegmentM(p, line[i - 1], line[i]));
  return best;
}

/** Closest approach of any hazard point to the route. */
export const clearanceM = (hazards: LatLng[], line: LatLng[]) =>
  hazards.reduce((m, h) => Math.min(m, distanceToLineM(h, line)), Infinity);

function bearingDeg(a: LatLng, b: LatLng): number {
  const y = Math.sin(rad(b[1] - a[1])) * Math.cos(rad(b[0]));
  const x = Math.cos(rad(a[0])) * Math.sin(rad(b[0])) - Math.sin(rad(a[0])) * Math.cos(rad(b[0])) * Math.cos(rad(b[1] - a[1]));
  return (Math.atan2(y, x) * 180) / Math.PI;
}

function offsetM(p: LatLng, bearing: number, m: number): LatLng {
  const d = m / R, b = rad(bearing), la = rad(p[0]), lo = rad(p[1]);
  const la2 = Math.asin(Math.sin(la) * Math.cos(d) + Math.cos(la) * Math.sin(d) * Math.cos(b));
  const lo2 = lo + Math.atan2(Math.sin(b) * Math.sin(d) * Math.cos(la), Math.cos(d) - Math.sin(la) * Math.sin(la2));
  return [(la2 * 180) / Math.PI, (lo2 * 180) / Math.PI];
}

/** First, last and evenly spaced points between (get_route_ml_risk takes ≤ 5000). */
export function decimate(line: LatLng[], max = 2000): LatLng[] {
  if (line.length <= max) return line;
  const step = (line.length - 1) / (max - 1);
  return Array.from({ length: max }, (_, i) => line[Math.round(i * step)]);
}

// ── OSRM client ─────────────────────────────────────────────────────────────

const cache = new Map<string, OsrmRoute[]>();
let gate: Promise<unknown> = Promise.resolve();
let last = 0;
const minInterval = usesPublicOsrm ? 1100 : 0;

/** Driving route through `waypoints`; with alternatives OSRM may add up to 3 (first is fastest). */
export async function osrmRoute(waypoints: LatLng[], alternatives = false): Promise<OsrmRoute[]> {
  if (waypoints.length < 2) throw new OsrmError('InvalidQuery', 'Need at least 2 waypoints');
  const coords = waypoints.map(([la, lo]) => `${lo.toFixed(6)},${la.toFixed(6)}`).join(';');
  const url = `${OSRM_URL}/route/v1/driving/${coords}?overview=full&geometries=polyline6&steps=true&alternatives=${alternatives ? 3 : 'false'}`;
  const hit = cache.get(url);
  if (hit) return hit;

  // Serialised and spaced: the public server rate-limits.
  const run = gate.then(async () => {
    const wait = minInterval - (Date.now() - last);
    if (wait > 0) await new Promise(r => setTimeout(r, wait));
    last = Date.now();
    let json: { code?: string; message?: string; routes?: { geometry: string; distance: number; duration: number; legs?: { summary?: string }[] }[] };
    try {
      const res = await fetch(url, { signal: AbortSignal.timeout(15000) });
      json = await res.json();
    } catch (e) {
      throw new OsrmError('Network', e instanceof Error ? e.message : String(e));
    }
    if (json.code !== 'Ok') throw new OsrmError(json.code ?? 'BadResponse', json.message ?? 'Routing engine error');
    const routes = (json.routes ?? []).map(r => ({
      geometry: decodePolyline(r.geometry),
      distanceM: r.distance,
      durationS: r.duration,
      summary: (r.legs ?? []).map(l => l.summary).filter(Boolean).join(' · '),
    }));
    if (!routes.length) throw new OsrmError('NoRoute', 'No route found');
    if (cache.size >= 64) cache.delete(cache.keys().next().value!);
    cache.set(url, routes);
    return routes;
  });
  gate = run.catch(() => undefined);
  return run;
}

// ── hazard avoidance (RoutePlanner.avoid) ───────────────────────────────────

/**
 * OSRM has no "avoid area", so: keep alternatives that clear every hazard;
 * failing that, force a via point at growing offsets either side of the first
 * blocking hazard, then a pair of flanking via points (a single one lets the
 * route cut back through the hazard on plains with parallel roads).
 */
async function detourAround(from: LatLng, to: LatLng, hazards: LatLng[], baseline: OsrmRoute, clearM: number, maxStretch = 3): Promise<OsrmRoute | null> {
  const centre = hazards.find(h => distanceToLineM(h, baseline.geometry) < clearM) ?? hazards[0];
  const heading = bearingDeg(from, to);
  const found: OsrmRoute[] = [];
  const tryVia = async (via: LatLng[]) => {
    try {
      const [r] = await osrmRoute([from, ...via, to]);
      if (clearanceM(hazards, r.geometry) >= clearM && r.distanceM <= baseline.distanceM * maxStretch) found.push(r);
    } catch (e) {
      if (e instanceof OsrmError && e.code === 'Network') throw e;
    }
  };
  for (const km of [5, 12, 25]) {
    const m = km * 1000;
    for (const side of [90, -90]) await tryVia([offsetM(centre, heading + side, m)]);
    if (found.length) break;
    for (const side of [90, -90]) {
      await tryVia([
        offsetM(offsetM(centre, heading + 180, m / 2), heading + side, m),
        offsetM(offsetM(centre, heading, m / 2), heading + side, m),
      ]);
    }
    if (found.length) break;
  }
  return found.sort((a, b) => a.durationS - b.durationS)[0] ?? null;
}

// ── hazards and ML risk ─────────────────────────────────────────────────────

export interface Hazard {
  at: LatLng;
  type: string;
  severity: string;
}

/** Incident types that close or block a road. */
const BLOCKING = ['flood', 'landslide', 'road_blockage', 'infrastructure_damage'];

/** Open blocking incidents with coordinates. Empty (not an error) when signed out. */
export async function fetchActiveHazards(): Promise<Hazard[]> {
  if (!supabase) return [];
  const { data, error } = await supabase
    .from('road_incidents')
    .select('lat, lng, incident_type, severity')
    .in('incident_type', BLOCKING)
    .not('status', 'in', '(resolved,rejected)')
    .not('lat', 'is', null)
    .limit(500);
  if (error) throw new Error(error.message);
  return (data ?? []).map(r => ({ at: [r.lat, r.lng] as LatLng, type: r.incident_type, severity: r.severity }));
}

async function routeRisk(line: LatLng[]): Promise<RouteRisk | null> {
  if (!supabase) return null;
  const { data: s } = await supabase.auth.getSession();
  if (!s.session) throw new MlSignedOutError();
  const { data, error } = await supabase.rpc('get_route_ml_risk', {
    p_geojson: { type: 'LineString', coordinates: decimate(line).map(([la, lo]) => [+lo.toFixed(6), +la.toFixed(6)]) },
  });
  if (error) throw new Error(error.message);
  return data as RouteRisk;
}

// ── planner ─────────────────────────────────────────────────────────────────

export interface PlannedRoute extends OsrmRoute {
  /** 'fastest' = OSRM's first route, 'alternative' = another OSRM route, 'detour' = forced around a hazard. */
  kind: 'fastest' | 'alternative' | 'detour';
  /** Closest approach to an active blocking incident, metres (Infinity when none). */
  hazardClearanceM: number;
  blocked: boolean;
  risk: RouteRisk | null;
}

export interface RoutePlan {
  routes: PlannedRoute[];
  /** Index into routes of the recommended one, or -1 when every route is blocked. */
  best: number;
  hazards: Hazard[];
  mlError: string | null;
  mlSignedOut: boolean;
}

const BAND_RANK: Record<MlBand, number> = { high: 3, review: 2, low: 1, no_coverage: 1 };
const bandRank = (r: PlannedRoute) => (r.risk?.summary ? BAND_RANK[r.risk.summary.band] : 1);
const alertCount = (r: PlannedRoute) => (r.risk?.summary ? r.risk.summary.n_alert * 10 + r.risk.summary.n_human_review : 0);

/**
 * Index of the recommended route: not blocked, no more than `maxSlowdown`× the
 * fastest open route's time, then lowest ML band, fewest flagged segments, fastest.
 */
export function pickBest(routes: PlannedRoute[], maxSlowdown = 1.5): number {
  const open = routes.map((r, i) => ({ r, i })).filter(x => !x.r.blocked);
  if (!open.length) return -1;
  const fastest = Math.min(...open.map(x => x.r.durationS));
  return open
    .filter(x => x.r.durationS <= fastest * maxSlowdown)
    .sort((a, b) => bandRank(a.r) - bandRank(b.r) || alertCount(a.r) - alertCount(b.r) || a.r.durationS - b.r.durationS)[0].i;
}

export async function planRoute(from: LatLng, to: LatLng, opts: { hazards?: Hazard[]; clearanceM?: number } = {}): Promise<RoutePlan> {
  const clearM = opts.clearanceM ?? 800;
  const hazards = opts.hazards ?? (await fetchActiveHazards().catch(() => []));
  const pts = hazards.map(h => h.at);
  const base = await osrmRoute([from, to], true);
  const routes: PlannedRoute[] = base.map((r, i) => {
    const c = clearanceM(pts, r.geometry);
    return { ...r, kind: i === 0 ? 'fastest' : 'alternative', hazardClearanceM: c, blocked: c < clearM, risk: null };
  });
  if (pts.length && routes.every(r => r.blocked)) {
    const d = await detourAround(from, to, pts, base[0], clearM);
    if (d) routes.push({ ...d, kind: 'detour', hazardClearanceM: clearanceM(pts, d.geometry), blocked: false, risk: null });
  }

  let mlError: string | null = null;
  let mlSignedOut = false;
  await Promise.all(routes.map(async r => {
    try {
      r.risk = await routeRisk(r.geometry);
    } catch (e) {
      if (e instanceof MlSignedOutError) mlSignedOut = true;
      else mlError = e instanceof Error ? e.message : String(e);
    }
  }));
  return { routes, best: pickBest(routes), hazards, mlError, mlSignedOut };
}

/**
 * Road geometry from `from` to `to` avoiding `hazards` (fastest clear route), or
 * null when the network has no way round. For callers that only need a line,
 * e.g. a rider's detour.
 */
export async function detourGeometry(from: LatLng, to: LatLng, hazards: LatLng[], clearM = 800): Promise<LatLng[] | null> {
  const base = await osrmRoute([from, to], true);
  const clear = base.find(r => clearanceM(hazards, r.geometry) >= clearM);
  if (clear) return clear.geometry;
  return (await detourAround(from, to, hazards, base[0], clearM))?.geometry ?? null;
}
