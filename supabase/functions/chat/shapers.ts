/**
 * Pure shaping of RPC results into model context. No imports, so it runs under
 * Deno (the function) and Node (the test) unchanged.
 *
 * Two jobs:
 *   - Bound the size. get_route_ml_risk returns hundreds of near-identical
 *     segments (SRS §8.3's own example has n_matched: 640). Dumped raw they cost
 *     thousands of tokens and the model hallucinates patterns in them.
 *   - Strip raw_score and p_calibrated everywhere. The model will call them a
 *     probability the moment it sees them (prompt rule 2, ML-006).
 */

export interface RawSegment {
  segment_id: string;
  along_m?: number;
  lat: number;
  lon: number;
  risk_percentile: number;
  tier: 'none' | 'alert' | 'human_review';
  steep: boolean;
}

const km = (m: number | null | undefined) => (m == null ? null : Math.round(m / 1000));
const pct = (f: number | null | undefined) => (f == null ? null : Math.round(f * 100));
const round = (n: number | null | undefined, places = 2) => (n == null ? null : Number(n.toFixed(places)));

/** Drops null/undefined so they don't eat context as `"field": null`. */
export function compact<T extends Record<string, unknown>>(o: T): Partial<T> {
  return Object.fromEntries(Object.entries(o).filter(([, v]) => v != null)) as Partial<T>;
}

/**
 * Groups segments into contiguous stretches along the route, so the model can
 * say "km 78-84" instead of listing 12 segment ids. A gap larger than gapM
 * starts a new stretch.
 *
 * ponytail: sort + single pass, O(n log n). Fine at the n<5000 a route returns.
 */
export function clusterByAlong(segments: RawSegment[], gapM = 2000): RawSegment[][] {
  const withAlong = segments
    .filter((s) => s.along_m != null)
    .sort((a, b) => a.along_m! - b.along_m!);
  const runs: RawSegment[][] = [];
  for (const s of withAlong) {
    const last = runs.at(-1);
    if (last && s.along_m! - last.at(-1)!.along_m! <= gapM) last.push(s);
    else runs.push([s]);
  }
  return runs;
}

/**
 * Bounded at roughly 400 tokens regardless of route length: the top 6 risky
 * stretches plus the route-level summary. "km 78-84, 12 segments, top 0.01%,
 * steep" is the sentence an officer actually wants.
 */
export function shapeRouteRisk(d: Record<string, any> | null): Record<string, any> {
  if (!d) return { error: 'No risk data returned for that route.' };

  const risky = (d.segments ?? []).filter((s: RawSegment) => s.tier !== 'none');
  const stretches = clusterByAlong(risky)
    .map((run) => ({
      from_km: km(run[0].along_m),
      to_km: km(run.at(-1)!.along_m),
      n_segments: run.length,
      worst_percentile: round(Math.max(...run.map((s) => s.risk_percentile)), 3),
      tier: run.some((s) => s.tier === 'alert') ? 'alert' : 'human_review',
      steep: run.some((s) => s.steep),
    }))
    .sort((a, b) => (b.worst_percentile ?? 0) - (a.worst_percentile ?? 0))
    .slice(0, 6);

  const w = d.summary?.worst;
  return compact({
    state: d.state,
    score_date: d.score_date,
    model_version: d.model_version,
    route_id: d.route_id,
    length_km: km(d.route_length_m),
    coverage_pct: pct(d.coverage_fraction),
    band: d.summary?.band,
    n_segments_matched: d.summary?.n_matched,
    n_alert: d.summary?.n_alert,
    n_human_review: d.summary?.n_human_review,
    max_percentile: round(d.summary?.max_percentile, 3),
    worst: w
      ? compact({
          segment_id: w.segment_id,
          at_km: km(w.along_m),
          risk_percentile: round(w.risk_percentile, 3),
          tier: w.tier,
          steep: w.steep,
        })
      : null,
    risky_stretches: stretches.length ? stretches : null,
  });
}

export function shapeRouteRow(r: Record<string, any>) {
  return compact({
    route_id: r.route_id,
    route_number: r.route_number,
    name: r.name,
    length_km: km(r.route_length_m),
    coverage_pct: pct(r.coverage_fraction),
    band: r.summary?.band,
    n_alert: r.summary?.n_alert,
    n_human_review: r.summary?.n_human_review,
    max_percentile: round(r.summary?.max_percentile, 3),
  });
}

export function shapeRoutesSummary(d: Record<string, any> | null) {
  if (!d) return { error: 'No route data returned.' };
  return compact({
    state: d.state,
    score_date: d.score_date,
    model_version: d.model_version,
    routes: (d.routes ?? []).map(shapeRouteRow),
  });
}

export function shapeTopAlerts(d: Record<string, any> | null) {
  if (!d) return { error: 'No alert data returned.' };
  return compact({
    state: d.state,
    score_date: d.score_date,
    scope: d.scope,
    tier: d.tier,
    n_in_tier: d.n_in_tier,
    rows: (d.rows ?? []).slice(0, 10).map((r: Record<string, any>) =>
      compact({
        segment_id: r.segment_id,
        risk_percentile: round(r.risk_percentile, 3),
        tier: r.tier,
        steep: r.steep,
        near: r.near_place
          ? `${r.near_km != null ? `${round(r.near_km, 1)} km from ` : ''}${r.near_place}${r.near_district ? `, ${r.near_district}` : ''}`
          : `${round(r.lat, 3)}, ${round(r.lon, 3)}`,
        already_raised: r.promoted_alert_id != null,
      }),
    ),
  });
}
