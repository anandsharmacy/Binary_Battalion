#!/usr/bin/env bash
# Runnable check for web/NER-Website/src/lib/routing.ts against an OSRM server:
# polyline decoding, route pick rules, and a detour around a hazard on NH-6.
#   OSRM_URL=http://localhost:5000 ./check_web_routing.sh
# Copies the module to a temp dir with Supabase/ML stubbed (Node >= 23 runs TS natively).
set -euo pipefail
WEB="$(cd "$(dirname "$0")/../../../web/NER-Website/src" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
sed -e "s#import.meta.env.VITE_OSRM_URL#process.env.OSRM_URL#" -e "s#'@/lib/supabase'#'./stub.ts'#" \
    -e "s#'@/lib/ml'#'./stub.ts'#" -e "s#'@/data/geo'#'./geo.ts'#" "$WEB/lib/routing.ts" > "$T/routing.ts"
sed -e "s#'./corridors.generated'#'./corridors.generated.ts'#" "$WEB/data/geo.ts" > "$T/geo.ts"
cp "$WEB/data/corridors.generated.ts" "$T/"
cat > "$T/stub.ts" <<'TS'
export const supabase = null;
export class MlSignedOutError extends Error {}
export type MlBand = 'high' | 'review' | 'low' | 'no_coverage';
export type RouteRisk = any;
TS
cat > "$T/check.ts" <<'TS'
import assert from 'node:assert';
import { planRoute, pickBest, decodePolyline, clearanceM, detourGeometry } from './routing.ts';
import { CORRIDORS } from './geo.ts';
assert.ok(CORRIDORS['NH-27'].path.length > 10);
assert.deepEqual(decodePolyline('_izlhA~rlgdF_{geC~ywl@_kwzCn`{nI', 6), [[38.5, -120.2], [40.7, -120.95], [43.252, -126.453]]);
const r = (d: number, band: string, blocked = false) => ({ durationS: d, blocked, risk: { summary: { band, n_alert: 0, n_human_review: 0 } } }) as any;
assert.equal(pickBest([r(100, 'high'), r(120, 'low')]), 1);          // safer within 1.5x wins
assert.equal(pickBest([r(100, 'high'), r(200, 'low')]), 0);          // too slow -> fastest
assert.equal(pickBest([r(100, 'low', true), r(130, 'high')]), 1);    // blocked never picked
assert.equal(pickBest([r(100, 'low', true)]), -1);
const gw: [number, number] = [26.1445, 91.7362], shl: [number, number] = [25.5788, 91.8933];
const free = await planRoute(gw, shl, { hazards: [] });
console.log('free', free.routes.map(x => [x.kind, Math.round(x.distanceM/1000), x.summary]), 'best', free.best);
// Landslide on NH-6 near Nongpoh -> must detour or report none.
const mid = free.routes[0].geometry[Math.floor(free.routes[0].geometry.length / 2)];
const hz = await planRoute(gw, shl, { hazards: [{ at: mid, type: 'landslide', severity: 'high' }] });
console.log('hazard', hz.routes.map(x => [x.kind, Math.round(x.distanceM/1000), x.blocked, Math.round(x.hazardClearanceM)]), 'best', hz.best);
if (hz.best >= 0) assert.ok(clearanceM([mid], hz.routes[hz.best].geometry) >= 800);
const d = await detourGeometry([26.35, 92.68], [26.75, 94.20], [[26.62, 93.72]]);
console.log('detour pts', d?.length);
console.log('OK');
TS
cd "$T" && OSRM_URL="${OSRM_URL:-http://localhost:5000}" node check.ts
